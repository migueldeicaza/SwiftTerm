/// The state reported by a program through OSC 7501.
public enum TerminalProgramStatusState: String, Equatable, Sendable {
    case idle, working, done, blocked, error
}

/// The action that a blocked program requires from the user.
public enum TerminalProgramStatusKind: String, Equatable, Sendable {
    case permission, question, auth
}

/// A value snapshot of one OSC 7501 record.
///
/// Text is plain UTF-8 without control characters. Hosts must treat it as
/// untrusted text. Remove text direction overrides and invisible formatting
/// characters before you show this text outside the terminal grid.
public struct TerminalProgramStatus: Equatable, Sendable {
    /// The record path. An empty string identifies the root record.
    public let id: String
    public let state: TerminalProgramStatusState
    public let kind: TerminalProgramStatusKind?
    public let progress: Int?
    /// The program name in this record's last report.
    public let app: String?
    /// The program name from this record or its nearest ancestor with a name.
    public internal(set) var effectiveApp: String?
    public let title: String?
    public let message: String?
}

struct TerminalProgramStatusStore {
    static let maximumRecords = 256
    private var records: [String: TerminalProgramStatus] = [:]
    // Oldest update first. Reads do not change this order.
    private var updateOrder: [String] = []

    var snapshots: [TerminalProgramStatus] {
        updateOrder.compactMap { snapshot(id: $0) }
    }

    func snapshot(id: String) -> TerminalProgramStatus? {
        guard var record = records[id] else { return nil }
        var ancestor = id
        while true {
            if let app = records[ancestor]?.app {
                record.effectiveApp = app
                break
            }
            guard !ancestor.isEmpty else { break }
            if let slash = ancestor.lastIndex(of: "/") {
                ancestor = String(ancestor[..<slash])
            } else {
                ancestor = ""
            }
        }
        return record
    }

    mutating func replace(_ record: TerminalProgramStatus) {
        updateOrder.removeAll { $0 == record.id }
        if records[record.id] == nil, records.count == Self.maximumRecords {
            records.removeValue(forKey: updateOrder.removeFirst())
        }
        records[record.id] = record
        updateOrder.append(record.id)
    }

    @discardableResult
    mutating func clear(id: String) -> Bool {
        remove { id.isEmpty || $0.id == id || $0.id.hasPrefix(id + "/") }
    }

    @discardableResult
    mutating func removeActiveRecords() -> Bool {
        remove { $0.state == .working || $0.state == .blocked }
    }

    private mutating func remove(where predicate: (TerminalProgramStatus) -> Bool) -> Bool {
        let ids = updateOrder.filter { records[$0].map(predicate) ?? false }
        guard !ids.isEmpty else { return false }
        for id in ids { records.removeValue(forKey: id) }
        updateOrder.removeAll { records[$0] == nil }
        return true
    }
}

extension Terminal {
    /// Current records, in order from the oldest update to the newest update.
    /// Hold `terminalLock` when you read or change terminal state.
    public var programStatusRecords: [TerminalProgramStatus] {
        programStatusStore.snapshots
    }

    /// Returns one current record. An empty id selects the root record.
    public func programStatus(id: String = "") -> TerminalProgramStatus? {
        programStatusStore.snapshot(id: id)
    }

    /// Removes a record and its descendants. An empty id removes all records.
    public func clearProgramStatus(id: String = "") {
        if programStatusStore.clear(id: id) { programStatusDidChange() }
    }

    /// Call this after the attached process exits and its output is parsed.
    /// Working and blocked records are removed. Other records remain.
    /// Hold `terminalLock`, as for other direct terminal operations.
    public func programStatusProcessExited() {
        if programStatusStore.removeActiveRecords() { programStatusDidChange() }
    }

    private func programStatusDidChange() {
        tdel?.programStatusChanged(source: self, records: programStatusRecords)
    }

    func oscProgramStatus(_ data: ArraySlice<UInt8>, terminator: UInt8) {
        // The parser also bounds the OSC code and framing bytes.
        guard data.count <= 4087 else { return }
        if data.elementsEqual([UInt8(ascii: "?")]) {
            // Keep BEL or ST so the program can recognize the reply. C1 ST
            // uses the standard two-byte ST reply, as in libghostty-vt.
            let ending = terminator == ControlCodes.BEL ? "\u{7}" : "\u{1b}\\"
            sendResponse("\u{1b}]7501;?" + ending)
            return
        }
        guard let report = ProgramStatusReport.parse(data) else { return }
        if report.clear {
            clearProgramStatus(id: report.id)
        } else if let record = report.record {
            programStatusStore.replace(record)
            programStatusDidChange()
        }
    }
}

private struct ProgramStatusReport {
    let id: String
    let clear: Bool
    let record: TerminalProgramStatus?

    static func parse(_ data: ArraySlice<UInt8>) -> ProgramStatusReport? {
        var fields: [String: String] = [:]
        for pair in data.split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false) {
            guard let equal = pair.firstIndex(of: UInt8(ascii: "=")) else { continue }
            let key = trim(pair[..<equal])
            let value = trim(pair[pair.index(after: equal)...])
            guard key.count <= 16 else { return nil }
            guard !key.isEmpty, key.allSatisfy({ (97...122).contains($0) }) else { continue }
            let name = String(decoding: key, as: UTF8.self)
            switch name {
            case "msg": guard value.count <= 2732 else { return nil }
            case "title": guard value.count <= 256 else { return nil }
            case "app": guard value.count <= 32 else { return nil }
            case "id": guard value.count <= 128 else { return nil }
            default: break
            }
            // A malformed id must never select the root record.
            if name == "id", !validId(value) { return nil }
            guard value.allSatisfy(isValueByte) else { continue }
            // Validate every pair before replacement, including repeated keys.
            switch name {
            case "msg", "title":
                let encodedLimit = name == "msg" ? 2732 : 256
                let decodedLimit = name == "msg" ? 2048 : 192
                guard value.count <= encodedLimit,
                      let text = decodeText(value, limit: decodedLimit) else { return nil }
                fields[name] = text
            case "app":
                guard value.count <= 32 else { return nil }
                fields[name] = String(decoding: value, as: UTF8.self)
            case "id":
                guard validId(value) else { return nil }
                fields[name] = String(decoding: value, as: UTF8.self)
            case "state", "kind", "progress":
                fields[name] = String(decoding: value, as: UTF8.self)
            default:
                continue
            }
        }
        let id = fields["id"] ?? ""
        if fields["state"] == "clear" { return Self(id: id, clear: true, record: nil) }
        guard let value = fields["state"],
              let state = TerminalProgramStatusState(rawValue: value) else { return nil }
        let kind = state == .blocked ? fields["kind"].flatMap(TerminalProgramStatusKind.init(rawValue:)) : nil
        var progress: Int?
        if state == .working || state == .blocked,
           let text = fields["progress"], !text.isEmpty,
           text.utf8.allSatisfy({ (48...57).contains($0) }),
           let number = Int(text), (0...100).contains(number) {
            progress = number
        }
        let app = fields["app"].flatMap { validSegment($0.utf8) ? $0 : nil }
        let record = TerminalProgramStatus(id: id, state: state, kind: kind,
                                           progress: progress, app: app, effectiveApp: app,
                                           title: fields["title"], message: fields["msg"])
        return Self(id: id, clear: false, record: record)
    }

    private static func trim(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var result = bytes
        while let first = result.first, isWhitespace(first) { result = result.dropFirst() }
        while let last = result.last, isWhitespace(last) { result = result.dropLast() }
        return result
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 32 || (9...13).contains(byte)
    }

    private static func isValueByte(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
            || [95, 46, 44, 43, 47, 61, 45].contains(byte)
    }

    private static func validSegment<C: Collection>(_ bytes: C) -> Bool where C.Element == UInt8 {
        (1...32).contains(bytes.count) && bytes.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 95 || $0 == 46 || $0 == 43 || $0 == 45
        }
    }

    private static func validId(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard !bytes.isEmpty, bytes.count <= 128 else { return false }
        let segments = bytes.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        return segments.count <= 8 && segments.allSatisfy { validSegment($0) }
    }

    // Standard base64 with optional padding. This decoder is also available
    // in Embedded builds, where the clipboard decoder permits invalid input.
    private static func decodeText(_ bytes: ArraySlice<UInt8>, limit: Int) -> String? {
        let content = bytes.prefix { $0 != 61 }
        let padding = bytes.count - content.count
        let remainder = content.count % 4
        guard remainder != 1, padding <= 2,
              bytes.dropFirst(content.count).allSatisfy({ $0 == 61 }),
              padding == 0 || (bytes.count % 4 == 0 && padding == 4 - remainder) else { return nil }
        var decoded: [UInt8] = []
        var bits: UInt32 = 0
        var count = 0
        for byte in content {
            let value: UInt32
            switch byte {
            case 65...90: value = UInt32(byte - 65)
            case 97...122: value = UInt32(byte - 97 + 26)
            case 48...57: value = UInt32(byte - 48 + 52)
            case 43: value = 62
            case 47: value = 63
            default: return nil
            }
            bits = (bits << 6) | value
            count += 6
            if count >= 8 {
                count -= 8
                decoded.append(UInt8((bits >> UInt32(count)) & 255))
                guard decoded.count <= limit else { return nil }
                bits &= (1 << UInt32(count)) - 1
            }
        }
        guard bits == 0, let text = terminalStringUTF8(decoded[...]),
              !text.unicodeScalars.contains(where: {
                  $0.value <= 31 || (127...159).contains($0.value)
              }) else { return nil }
        return text
    }
}
