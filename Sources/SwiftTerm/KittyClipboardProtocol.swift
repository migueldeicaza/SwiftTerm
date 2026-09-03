import Foundation
#if canImport(Security)
import Security
#endif

/// The clipboard selected by an OSC 5522 request.
public enum KittyClipboardLocation: Sendable, Equatable {
    case standard
    case primary
}

/// OSC 5522 services that a host explicitly makes available.
public struct KittyClipboardCapabilities: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let read = KittyClipboardCapabilities(rawValue: 1 << 0)
    public static let write = KittyClipboardCapabilities(rawValue: 1 << 1)
}

/// Terminal policy applied in addition to the host's explicit capability result.
public struct KittyClipboardPolicy: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let read = KittyClipboardPolicy(rawValue: 1 << 0)
    public static let write = KittyClipboardPolicy(rawValue: 1 << 1)
    public static let all: KittyClipboardPolicy = [.read, .write]
}

public enum KittyClipboardPermissionDirection: Sendable, Equatable {
    case read
    case write
}

public struct KittyClipboardPermissionRequest: Sendable {
    public let direction: KittyClipboardPermissionDirection
    public let location: KittyClipboardLocation
    public let name: String
    public let mimeTypes: [String]
    public let canRememberPassword: Bool

    public init(
        direction: KittyClipboardPermissionDirection,
        location: KittyClipboardLocation,
        name: String,
        mimeTypes: [String],
        canRememberPassword: Bool
    ) {
        self.direction = direction
        self.location = location
        self.name = name
        self.mimeTypes = mimeTypes
        self.canRememberPassword = canRememberPassword
    }
}

public enum KittyClipboardPermissionResult: Sendable {
    case allow(rememberPassword: Bool)
    case deny
}

public struct KittyClipboardRepresentation: Sendable, Equatable {
    public let mimeType: String
    public let data: Data

    public init(mimeType: String, data: Data) {
        self.mimeType = mimeType
        self.data = data
    }
}

public enum KittyClipboardWriteResult: Sendable {
    case success
    case denied
    case unsupported
    case busy
    case invalidData
    case ioError
}

public enum TerminalPasteSource: Sendable, Equatable {
    case clipboard(KittyClipboardLocation)
    case text
}

public struct TerminalPasteRequest: Sendable {
    public typealias MimeReader = @Sendable (
        _ mimeType: String,
        _ completion: @escaping @Sendable (Data?) -> Void
    ) -> Bool

    public let source: TerminalPasteSource
    public let mimeTypes: [String]
    public let text: String?
    public let readMimeType: MimeReader?

    public init(
        source: TerminalPasteSource,
        mimeTypes: [String] = [],
        text: String? = nil,
        readMimeType: MimeReader? = nil
    ) {
        self.source = source
        self.mimeTypes = mimeTypes
        self.text = text
        self.readMimeType = readMimeType
    }
}

public enum TerminalPasteResult: Sendable, Equatable {
    case kittyEvent(password: String)
    case text
    case requiresText
    case unsafePayload
    case entropyUnavailable
    case deliveryFailed

    var needsTextFallback: Bool {
        switch self {
        case .requiresText, .entropyUnavailable, .deliveryFailed:
            return true
        case .kittyEvent, .text, .unsafePayload:
            return false
        }
    }
}

enum KittyClipboardOSCTerminator: Sendable {
    case bell
    case stringTerminator
    case c1StringTerminator

    var bytes: [UInt8] {
        switch self {
        case .bell:
            return [ControlCodes.BEL]
        case .stringTerminator:
            return [ControlCodes.ESC, UInt8(ascii: "\\")]
        case .c1StringTerminator:
            return [0x9c]
        }
    }
}

private enum KittyClipboardOperation: String, Sendable {
    case read
    case write
    case wdata
    case walias
}

private enum KittyClipboardStatus: String, Sendable {
    case ok = "OK"
    case data = "DATA"
    case done = "DONE"
    case permission = "EPERM"
    case unsupported = "ENOSYS"
    case busy = "EBUSY"
    case invalid = "EINVAL"
    case io = "EIO"
    case tooLarge = "EFBIG"
}

private struct KittyClipboardMetadata: Sendable {
    let operation: KittyClipboardOperation
    let location: KittyClipboardLocation
    let id: String
    let mime: String
    let name: String
    let password: String

    enum ParseResult {
        case valid(KittyClipboardMetadata)
        case invalidSyntax
        case invalidValue(KittyClipboardOperation?)
    }

    static func parse(_ bytes: ArraySlice<UInt8>) -> ParseResult {
        var recognized: [String: ArraySlice<UInt8>] = [:]
        var start = bytes.startIndex
        while true {
            let end = bytes[start...].firstIndex(of: UInt8(ascii: ":")) ?? bytes.endIndex
            let record = bytes[start..<end]
            guard let equals = record.firstIndex(of: UInt8(ascii: "=")) else {
                return .invalidSyntax
            }
            let key = String(decoding: record[..<equals], as: UTF8.self)
            switch key {
            case "type", "loc", "id", "mime", "name", "pw", "status":
                recognized[key] = record[record.index(after: equals)...]
            default:
                break
            }
            guard end != bytes.endIndex else { break }
            start = bytes.index(after: end)
        }

        let operation = recognized["type"].flatMap {
            KittyClipboardOperation(rawValue: String(decoding: $0, as: UTF8.self))
        }
        guard let operation else {
            return .invalidSyntax
        }

        let location: KittyClipboardLocation
        if recognized["loc"].map({ String(decoding: $0, as: UTF8.self) }) == "primary" {
            location = .primary
        } else {
            location = .standard
        }

        let rawID = recognized["id"] ?? []
        var idBytes: [UInt8] = []
        idBytes.reserveCapacity(min(512, rawID.count))
        for byte in rawID where idBytes.count < 512 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "+"), UInt8(ascii: "."):
                idBytes.append(byte)
            default:
                break
            }
        }

        guard let mime = decodeText(recognized["mime"] ?? [], limit: 256),
              let name = decodeText(recognized["name"] ?? [], limit: 256)
        else {
            return .invalidValue(operation)
        }

        let password: String
        if let rawPassword = recognized["pw"] {
            switch StrictBase64.decode(rawPassword, maximumDecodedBytes: 128) {
            case .success(let data):
                guard let value = String(data: data, encoding: .utf8) else {
                    return .invalidValue(operation)
                }
                password = value
            case .tooLarge:
                password = ""
            case .invalid:
                return .invalidValue(operation)
            }
        } else {
            password = ""
        }

        return .valid(KittyClipboardMetadata(
            operation: operation,
            location: location,
            id: String(decoding: idBytes, as: UTF8.self),
            mime: mime,
            name: name,
            password: password))
    }

    private static func decodeText(_ bytes: ArraySlice<UInt8>, limit: Int) -> String? {
        guard !bytes.isEmpty else { return "" }
        guard case .success(let data) = StrictBase64.decode(bytes, maximumDecodedBytes: limit) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

}

private enum StrictBase64 {
    enum Result {
        case success(Data)
        case invalid
        case tooLarge
    }

    static func decode(_ bytes: ArraySlice<UInt8>, maximumDecodedBytes: Int? = nil) -> Result {
        if let maximumDecodedBytes,
           bytes.count > ((maximumDecodedBytes + 2) / 3) * 4
        {
            return .tooLarge
        }
        guard bytes.count % 4 == 0 else { return .invalid }
        var padding = 0
        for (offset, byte) in bytes.enumerated() {
            let isAlphabet = byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")
                || byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")
                || byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
                || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "/")
            if isAlphabet {
                if padding != 0 { return .invalid }
                continue
            }
            guard byte == UInt8(ascii: "="), offset >= bytes.count - 2 else {
                return .invalid
            }
            padding += 1
            if padding > 2 { return .invalid }
        }
        if bytes.isEmpty {
            return .success(Data())
        }
        let encoded = Data(bytes)
        guard let decoded = Data(base64Encoded: encoded),
              decoded.base64EncodedData() == encoded
        else {
            return .invalid
        }
        if let maximumDecodedBytes, decoded.count > maximumDecodedBytes {
            return .tooLarge
        }
        return .success(decoded)
    }
}

private struct KittyClipboardBase64Stream: Sendable {
    private(set) var decoded = Data()
    private var tail: [UInt8] = []

    mutating func append(_ bytes: ArraySlice<UInt8>, remainingLimit: Int) -> KittyClipboardStatus? {
        var input = tail
        input.append(contentsOf: bytes)
        tail.removeAll(keepingCapacity: true)

        if let paddingIndex = input.firstIndex(of: UInt8(ascii: "=")) {
            let quartetStart = paddingIndex - paddingIndex % 4
            if quartetStart > 0 {
                guard case .success(let part) = StrictBase64.decode(input[..<quartetStart]) else {
                    return .invalid
                }
                if part.count > remainingLimit - decoded.count {
                    return .tooLarge
                }
                decoded.append(part)
            }

            let quartetEnd = quartetStart + 4
            guard quartetEnd <= input.count,
                  case .success(let part) = StrictBase64.decode(input[quartetStart..<quartetEnd])
            else {
                return .invalid
            }
            if part.count > remainingLimit - decoded.count {
                return .tooLarge
            }
            decoded.append(part)
            guard quartetEnd == input.count else {
                return .invalid
            }
            return nil
        }

        let decodedEnd = input.count - input.count % 4
        if decodedEnd > 0 {
            guard case .success(let part) = StrictBase64.decode(input[..<decodedEnd]) else {
                return .invalid
            }
            if part.count > remainingLimit - decoded.count {
                return .tooLarge
            }
            decoded.append(part)
        }
        if decodedEnd < input.count {
            tail.append(contentsOf: input[decodedEnd...])
            for byte in tail {
                let valid = byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")
                    || byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")
                    || byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
                    || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "/")
                if !valid { return .invalid }
            }
        }
        return nil
    }

    func isComplete() -> Bool {
        tail.isEmpty
    }
}

private struct KittyClipboardWriteTransaction: Sendable {
    let serial: UInt64
    let location: KittyClipboardLocation
    let id: String
    let password: String
    let name: String
    let byteLimit: Int
    var order: [String] = []
    var streams: [String: KittyClipboardBase64Stream] = [:]
    var aliases: [(name: String, target: String)] = []
    var decodedBytes = 0
    var activeMime: String?

    mutating func append(mime: String, payload: ArraySlice<UInt8>) -> KittyClipboardStatus? {
        if activeMime != mime {
            if let activeMime, streams[activeMime]?.isComplete() == false {
                return .invalid
            }
            activeMime = mime
        }
        if streams[mime] == nil {
            guard streams.count < 64 else { return .tooLarge }
            streams[mime] = KittyClipboardBase64Stream()
            order.append(mime)
        }
        let before = streams[mime]?.decoded.count ?? 0
        let remaining = max(0, byteLimit - (decodedBytes - before))
        let status = streams[mime]!.append(payload, remainingLimit: remaining)
        let after = streams[mime]?.decoded.count ?? before
        decodedBytes += after - before
        return status
    }

    mutating func addAliases(target: String, payload: ArraySlice<UInt8>) -> KittyClipboardStatus? {
        guard case .success(let data) = StrictBase64.decode(payload),
              let text = String(data: data, encoding: .utf8)
        else {
            return .invalid
        }
        var result: KittyClipboardStatus?
        scanASCIIWords(text) { word in
            let name = String(word)
            guard name.utf8.count <= 256 else {
                result = .invalid
                return false
            }
            if let index = aliases.firstIndex(where: { $0.name == name }) {
                aliases[index].target = target
            } else {
                guard aliases.count < 64 else {
                    result = .tooLarge
                    return false
                }
                aliases.append((name: name, target: target))
            }
            return true
        }
        return result
    }

    mutating func commit() -> [KittyClipboardRepresentation]? {
        if let activeMime, streams[activeMime]?.isComplete() == false {
            return nil
        }
        var contents = order.compactMap { mime -> KittyClipboardRepresentation? in
            guard let data = streams[mime]?.decoded else { return nil }
            return KittyClipboardRepresentation(mimeType: mime, data: data)
        }
        for alias in aliases {
            guard let target = contents.first(where: { $0.mimeType == alias.target }) else {
                continue
            }
            let value = KittyClipboardRepresentation(mimeType: alias.name, data: target.data)
            if let index = contents.firstIndex(where: { $0.mimeType == alias.name }) {
                contents[index] = value
            } else {
                contents.append(value)
            }
        }
        return contents
    }
}

private func scanASCIIWords(
    _ string: String,
    _ body: (Substring) -> Bool
) {
    func isSeparator(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n"
            || character == "\r" || character == "\u{0b}" || character == "\u{0c}"
    }
    var start: String.Index?
    var index = string.startIndex
    while index < string.endIndex {
        if isSeparator(string[index]) {
            if let start, !body(string[start..<index]) { return }
            start = nil
        } else if start == nil {
            start = index
        }
        index = string.index(after: index)
    }
    if let start {
        _ = body(string[start..<string.endIndex])
    }
}

private struct KittyClipboardDelegateHandle: @unchecked Sendable {
    let value: TerminalDelegate
}

final class KittyClipboardProtocol: @unchecked Sendable {
    private weak var terminal: Terminal?
    private let completionQueue = DispatchQueue(label: "org.tirania.SwiftTerm.kitty-clipboard")
    private var grants = KittyClipboardGrants()
    private var pasteSources: [String: KittyClipboardPasteSource] = [:]
    private var pasteSourceOrder: [String] = []
    private var transaction: KittyClipboardWriteTransaction?
    private var serial: UInt64 = 0
    private var sessionGeneration: UInt64 = 0

    init(terminal: Terminal) {
        self.terminal = terminal
    }

    func clear() {
        grants.clear()
        pasteSources.removeAll()
        pasteSourceOrder.removeAll()
        transaction = nil
        serial &+= 1
        sessionGeneration &+= 1
    }

    func terminalDestroyed() {
        completionQueue.async { [self] in
            clear()
        }
    }

    func hasReadCapability() -> Bool {
        guard let terminal else { return false }
        return terminal.options.kittyClipboardPolicy.contains(.read)
            && (terminal.tdel?.kittyClipboardCapabilities(source: terminal).contains(.read) ?? false)
    }

    func paste(_ request: TerminalPasteRequest, allowUnsafe: Bool) -> TerminalPasteResult {
        guard let terminal else { return .deliveryFailed }
        if case .clipboard(let location) = request.source,
           terminal.kittyPasteEventsEnabled,
           hasReadCapability()
        {
            guard let password = terminal.kittyClipboardPasswordGenerator() else {
                return .entropyUnavailable
            }
            grants.add(password: password, direction: .read, lifetime: .oneTime)
            storePasteSource(KittyClipboardPasteSource(
                available: Array(request.mimeTypes.prefix(16)),
                reader: request.readMimeType), password: password)
            let event = encodeReadSuccess(
                location: location,
                id: "",
                password: password,
                includeTargets: true,
                available: Array(request.mimeTypes.prefix(16)),
                representations: [],
                terminator: .stringTerminator)
            terminal.registerUserInput(event[...])
            guard terminal.tdel?.kittyClipboardSendPasteEvent(
                source: terminal,
                data: event[...]) == true
            else {
                grants.revoke(password: password)
                removePasteSource(password: password)
                return .deliveryFailed
            }
            return .kittyEvent(password: password)
        }

        guard let text = request.text else {
            return .requiresText
        }
        let encoded = TerminalPaste.encode(
            text,
            bracketed: terminal.bracketedPasteMode,
            terminalControlBytes: terminal.tdel?.terminalControlBytesForPaste(source: terminal)
                ?? TerminalPasteControls.approximateTerminalControlBytes,
            allowUnsafe: allowUnsafe)
        guard case .encoded(let bytes) = encoded else {
            return .unsafePayload
        }
        terminal.registerUserInput(bytes[...])
        terminal.tdel?.send(source: terminal, data: bytes[...])
        return .text
    }

    func handle(_ data: ArraySlice<UInt8>, terminator: KittyClipboardOSCTerminator) {
        let metadataBytes: ArraySlice<UInt8>
        let payload: ArraySlice<UInt8>
        if let separator = data.firstIndex(of: UInt8(ascii: ";")) {
            metadataBytes = data[..<separator]
            payload = data[data.index(after: separator)...]
        } else {
            metadataBytes = data
            payload = []
        }

        switch KittyClipboardMetadata.parse(metadataBytes) {
        case .invalidSyntax:
            return
        case .invalidValue(let operation):
            if operation == .wdata || operation == .walias {
                abortWrite(status: .invalid, terminator: terminator)
            }
        case .valid(let metadata):
            switch metadata.operation {
            case .read:
                handleRead(metadata, payload: Array(payload), terminator: terminator)
            case .write:
                beginWrite(metadata, terminator: terminator)
            case .wdata:
                handleWriteData(metadata, payload: payload, terminator: terminator)
            case .walias:
                handleWriteAlias(metadata, payload: payload, terminator: terminator)
            }
        }
    }

    private func handleRead(
        _ metadata: KittyClipboardMetadata,
        payload: [UInt8],
        terminator: KittyClipboardOSCTerminator
    ) {
        guard case .success(let decoded) = StrictBase64.decode(payload[...]),
              let text = String(data: decoded, encoding: .utf8)
        else {
            return
        }
        var includeTargets = false
        var requested: [String] = []
        var invalidMime = false
        scanASCIIWords(text) { word in
            let mime = String(word)
            guard mime.utf8.count <= 256 else {
                invalidMime = true
                return false
            }
            if mime == "." {
                includeTargets = true
            } else if requested.count < 4 {
                requested.append(mime)
            }
            return true
        }
        guard !invalidMime else { return }

        let granted = grants.check(password: metadata.password, direction: .read)
        let pasteSource = takePasteSource(password: metadata.password)
        guard let terminal, hasReadCapability(), let delegate = terminal.tdel else {
            sendStatus(operation: .read, status: .permission, id: metadata.id, terminator: terminator)
            return
        }

        let work = KittyClipboardReadWork(
            location: metadata.location,
            id: metadata.id,
            password: metadata.password,
            name: metadata.name,
            requested: requested,
            includeTargets: includeTargets,
            terminator: terminator,
            granted: granted,
            generation: sessionGeneration,
            pasteSource: pasteSource)
        let delegateHandle = KittyClipboardDelegateHandle(value: delegate)
        completionQueue.async { [self] in
            guard let terminal = self.terminal else { return }
            if granted || work.requested.isEmpty {
                self.beginHostRead(work, delegate: delegateHandle)
                return
            }
            let permission = KittyClipboardPermissionRequest(
                direction: .read,
                location: work.location,
                name: work.name,
                mimeTypes: work.requested,
                canRememberPassword: !work.password.isEmpty && !work.name.isEmpty)
            let accepted = delegateHandle.value.kittyClipboardRequestPermission(
                source: terminal,
                request: permission
            ) { [self] result in
                self.completionQueue.async { [self] in
                    switch result {
                    case .deny:
                        self.finishReadFailure(work)
                    case .allow(let remember):
                        guard let terminal = self.terminal else { return }
                        let isCurrent = terminal.terminalLock.withLock {
                            guard work.generation == self.sessionGeneration else { return false }
                            if remember, !work.password.isEmpty, !work.name.isEmpty {
                                self.grants.add(password: work.password, direction: .read, lifetime: .persistent)
                            }
                            return true
                        }
                        guard isCurrent else { return }
                        self.beginHostRead(work, delegate: delegateHandle)
                    }
                }
            }
            if !accepted {
                self.finishReadFailure(work)
            }
        }
    }

    private func beginHostRead(
        _ work: KittyClipboardReadWork,
        delegate: KittyClipboardDelegateHandle
    ) {
        guard isCurrent(work) else { return }
        if let pasteSource = work.pasteSource {
            readRepresentation(
                at: 0,
                work: work,
                delegate: delegate,
                available: pasteSource.available,
                results: [])
            return
        }
        guard let terminal else { return }
        if work.includeTargets {
            let accepted = delegate.value.kittyClipboardAvailableMimeTypes(
                source: terminal,
                location: work.location
            ) { [self] mimeTypes in
                self.completionQueue.async { [self] in
                    guard let mimeTypes else {
                        self.finishReadFailure(work)
                        return
                    }
                    self.readRepresentation(
                        at: 0,
                        work: work,
                        delegate: delegate,
                        available: mimeTypes,
                        results: [])
                }
            }
            if !accepted {
                finishReadFailure(work)
            }
        } else {
            readRepresentation(at: 0, work: work, delegate: delegate, available: [], results: [])
        }
    }

    private func readRepresentation(
        at index: Int,
        work: KittyClipboardReadWork,
        delegate: KittyClipboardDelegateHandle,
        available: [String],
        results: [KittyClipboardRepresentation]
    ) {
        guard isCurrent(work), let terminal else { return }
        if index == work.requested.count {
            terminal.terminalLock.withLock {
                guard work.generation == sessionGeneration else { return }
                let response = encodeReadSuccess(
                    location: work.location,
                    id: work.id,
                    password: nil,
                    includeTargets: work.includeTargets,
                    available: available,
                    representations: results,
                    terminator: work.terminator)
                terminal.sendResponse(response)
            }
            return
        }
        let mime = work.requested[index]
        let completion: @Sendable (Data?) -> Void = { [self] data in
            self.completionQueue.async { [self] in
                var nextResults = results
                if let data, !data.isEmpty {
                    nextResults.append(KittyClipboardRepresentation(mimeType: mime, data: data))
                }
                self.readRepresentation(
                    at: index + 1,
                    work: work,
                    delegate: delegate,
                    available: available,
                    results: nextResults)
            }
        }
        let accepted: Bool
        if let reader = work.pasteSource?.reader {
            accepted = reader(mime, completion)
        } else {
            accepted = delegate.value.kittyClipboardRead(
                source: terminal,
                location: work.location,
                mimeType: mime,
                completion: completion)
        }
        if !accepted {
            finishReadFailure(work)
        }
    }

    private func finishReadFailure(_ work: KittyClipboardReadWork) {
        guard let terminal else { return }
        terminal.terminalLock.withLock {
            guard work.generation == sessionGeneration else { return }
            sendStatus(operation: .read, status: .permission, id: work.id, terminator: work.terminator)
        }
    }

    private func isCurrent(_ work: KittyClipboardReadWork) -> Bool {
        guard let terminal else { return false }
        return terminal.terminalLock.withLock { work.generation == sessionGeneration }
    }

    private func beginWrite(
        _ metadata: KittyClipboardMetadata,
        terminator: KittyClipboardOSCTerminator
    ) {
        serial &+= 1
        transaction = nil
        guard let terminal else { return }
        guard terminal.options.kittyClipboardPolicy.contains(.write),
              terminal.tdel?.kittyClipboardCapabilities(source: terminal).contains(.write) == true
        else {
            sendStatus(operation: .write, status: .unsupported, id: metadata.id, terminator: terminator)
            return
        }
        transaction = KittyClipboardWriteTransaction(
            serial: serial,
            location: metadata.location,
            id: metadata.id,
            password: metadata.password,
            name: metadata.name,
            byteLimit: max(0, terminal.options.kittyClipboardWriteLimitBytes))
    }

    private func handleWriteData(
        _ metadata: KittyClipboardMetadata,
        payload: ArraySlice<UInt8>,
        terminator: KittyClipboardOSCTerminator
    ) {
        guard var current = transaction else { return }
        transaction = nil
        if metadata.mime.isEmpty {
            guard let representations = current.commit() else {
                abortWrite(current, status: .invalid, terminator: terminator)
                return
            }
            commitWrite(current, representations: representations, terminator: terminator)
            return
        }
        if let status = current.append(mime: metadata.mime, payload: payload) {
            abortWrite(current, status: status, terminator: terminator)
            return
        }
        transaction = current
    }

    private func handleWriteAlias(
        _ metadata: KittyClipboardMetadata,
        payload: ArraySlice<UInt8>,
        terminator: KittyClipboardOSCTerminator
    ) {
        guard var current = transaction else { return }
        transaction = nil
        guard !metadata.mime.isEmpty else {
            abortWrite(current, status: .invalid, terminator: terminator)
            return
        }
        if let status = current.addAliases(target: metadata.mime, payload: payload) {
            abortWrite(current, status: status, terminator: terminator)
            return
        }
        transaction = current
    }

    private func commitWrite(
        _ current: KittyClipboardWriteTransaction,
        representations: [KittyClipboardRepresentation],
        terminator: KittyClipboardOSCTerminator
    ) {
        let granted = grants.check(password: current.password, direction: .write)
        removePasteSource(password: current.password)
        guard let terminal, let delegate = terminal.tdel else {
            sendStatus(operation: .write, status: .permission, id: current.id, terminator: terminator)
            return
        }
        let delegateHandle = KittyClipboardDelegateHandle(value: delegate)
        completionQueue.async { [self] in
            guard let terminal = self.terminal else { return }
            if granted {
                self.performHostWrite(
                    current,
                    representations: representations,
                    terminator: terminator,
                    delegate: delegateHandle)
                return
            }
            let request = KittyClipboardPermissionRequest(
                direction: .write,
                location: current.location,
                name: current.name,
                mimeTypes: representations.map(\.mimeType),
                canRememberPassword: !current.password.isEmpty && !current.name.isEmpty)
            let accepted = delegateHandle.value.kittyClipboardRequestPermission(
                source: terminal,
                request: request
            ) { [self] result in
                self.completionQueue.async { [self] in
                    switch result {
                    case .deny:
                        self.finishWrite(current, result: .denied, terminator: terminator)
                    case .allow(let remember):
                        guard let terminal = self.terminal else { return }
                        let isCurrent = terminal.terminalLock.withLock {
                            guard current.serial == self.serial else { return false }
                            if remember, !current.password.isEmpty, !current.name.isEmpty {
                                self.grants.add(password: current.password, direction: .write, lifetime: .persistent)
                            }
                            return true
                        }
                        guard isCurrent else { return }
                        self.performHostWrite(
                            current,
                            representations: representations,
                            terminator: terminator,
                            delegate: delegateHandle)
                    }
                }
            }
            if !accepted {
                self.finishWrite(current, result: .denied, terminator: terminator)
            }
        }
    }

    private func performHostWrite(
        _ current: KittyClipboardWriteTransaction,
        representations: [KittyClipboardRepresentation],
        terminator: KittyClipboardOSCTerminator,
        delegate: KittyClipboardDelegateHandle
    ) {
        guard isCurrent(current), let terminal else { return }
        let accepted = delegate.value.kittyClipboardWrite(
            source: terminal,
            location: current.location,
            representations: representations
        ) { [self] result in
            self.completionQueue.async { [self] in
                self.finishWrite(current, result: result, terminator: terminator)
            }
        }
        if !accepted {
            finishWrite(current, result: .denied, terminator: terminator)
        }
    }

    private func finishWrite(
        _ current: KittyClipboardWriteTransaction,
        result: KittyClipboardWriteResult,
        terminator: KittyClipboardOSCTerminator
    ) {
        guard let terminal else { return }
        terminal.terminalLock.withLock {
            guard current.serial == serial else { return }
            serial &+= 1
            let status: KittyClipboardStatus
            switch result {
            case .success: status = .done
            case .denied: status = .permission
            case .unsupported: status = .unsupported
            case .busy: status = .busy
            case .invalidData: status = .invalid
            case .ioError: status = .io
            }
            sendStatus(operation: .write, status: status, id: current.id, terminator: terminator)
        }
    }

    private func abortWrite(status: KittyClipboardStatus, terminator: KittyClipboardOSCTerminator) {
        guard let current = transaction else { return }
        transaction = nil
        abortWrite(current, status: status, terminator: terminator)
    }

    private func abortWrite(
        _ current: KittyClipboardWriteTransaction,
        status: KittyClipboardStatus,
        terminator: KittyClipboardOSCTerminator
    ) {
        serial &+= 1
        sendStatus(operation: .write, status: status, id: current.id, terminator: terminator)
    }

    private func sendStatus(
        operation: KittyClipboardOperation,
        status: KittyClipboardStatus,
        id: String,
        terminator: KittyClipboardOSCTerminator
    ) {
        guard let terminal else { return }
        terminal.sendResponse(encodePacket(
            operation: operation,
            status: status,
            id: id,
            terminator: terminator))
    }

    private func isCurrent(_ transaction: KittyClipboardWriteTransaction) -> Bool {
        guard let terminal else { return false }
        return terminal.terminalLock.withLock { transaction.serial == serial }
    }

    private func storePasteSource(_ source: KittyClipboardPasteSource, password: String) {
        if pasteSources.count >= KittyClipboardGrants.maximumCount,
           let oldest = pasteSourceOrder.first
        {
            pasteSources.removeValue(forKey: oldest)
            pasteSourceOrder.removeFirst()
        }
        pasteSources[password] = source
        pasteSourceOrder.append(password)
    }

    private func takePasteSource(password: String) -> KittyClipboardPasteSource? {
        let source = pasteSources.removeValue(forKey: password)
        if source != nil {
            pasteSourceOrder.removeAll { $0 == password }
        }
        return source
    }

    private func removePasteSource(password: String) {
        _ = takePasteSource(password: password)
    }

    private func encodeReadSuccess(
        location: KittyClipboardLocation,
        id: String,
        password: String?,
        includeTargets: Bool,
        available: [String],
        representations: [KittyClipboardRepresentation],
        terminator: KittyClipboardOSCTerminator
    ) -> [UInt8] {
        var result = encodePacket(
            operation: .read,
            status: .ok,
            location: location,
            id: id,
            password: password,
            terminator: terminator)
        if includeTargets {
            let listed = available.prefix(password == nil ? available.count : 16)
            let raw = listed.isEmpty ? Data() : Data((listed.joined(separator: " ") + "\n").utf8)
            result.append(contentsOf: encodePacket(
                operation: .read,
                status: .data,
                id: id,
                mime: ".",
                password: password,
                payload: raw,
                terminator: terminator))
        }
        for representation in representations {
            var offset = 0
            while offset < representation.data.count {
                let end = min(offset + 4096, representation.data.count)
                result.append(contentsOf: encodePacket(
                    operation: .read,
                    status: .data,
                    id: id,
                    mime: representation.mimeType,
                    password: password,
                    payload: representation.data[offset..<end],
                    terminator: terminator))
                offset = end
            }
        }
        result.append(contentsOf: encodePacket(
            operation: .read,
            status: .done,
            id: id,
            password: password,
            terminator: terminator))
        return result
    }

    private func encodePacket(
        operation: KittyClipboardOperation,
        status: KittyClipboardStatus,
        location: KittyClipboardLocation? = nil,
        id: String = "",
        mime: String? = nil,
        password: String? = nil,
        payload: Data? = nil,
        terminator: KittyClipboardOSCTerminator
    ) -> [UInt8] {
        guard let terminal else { return [] }
        var metadata = "5522;type=\(operation.rawValue):status=\(status.rawValue)"
        if location == .primary {
            metadata += ":loc=primary"
        }
        if !id.isEmpty {
            metadata += ":id=\(id)"
        }
        if let mime, !mime.isEmpty {
            metadata += ":mime=\(Data(mime.utf8).base64EncodedString())"
        }
        if let password, !password.isEmpty {
            metadata += ":pw=\(Data(password.utf8).base64EncodedString())"
        }
        if let payload, !payload.isEmpty {
            metadata += ";\(payload.base64EncodedString())"
        }
        return terminal.cc.OSC + Array(metadata.utf8) + terminator.bytes
    }
}

private struct KittyClipboardReadWork: Sendable {
    let location: KittyClipboardLocation
    let id: String
    let password: String
    let name: String
    let requested: [String]
    let includeTargets: Bool
    let terminator: KittyClipboardOSCTerminator
    let granted: Bool
    let generation: UInt64
    let pasteSource: KittyClipboardPasteSource?
}

private struct KittyClipboardPasteSource: Sendable {
    let available: [String]
    let reader: TerminalPasteRequest.MimeReader?
}

enum KittyClipboardOTP {
    static let alphabet = Array("23456789abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ".utf8)

    static func generate() -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(22)
#if canImport(Security)
        let acceptedRange = UInt8.max - (UInt8.max % UInt8(alphabet.count))
        while bytes.count < 22 {
            var random: UInt8 = 0
            guard SecRandomCopyBytes(kSecRandomDefault, 1, &random) == errSecSuccess else {
                return nil
            }
            guard random < acceptedRange else { continue }
            bytes.append(alphabet[Int(random) % alphabet.count])
        }
#else
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<22 {
            bytes.append(alphabet[Int.random(in: 0..<alphabet.count, using: &generator)])
        }
#endif
        return String(decoding: bytes, as: UTF8.self)
    }
}
