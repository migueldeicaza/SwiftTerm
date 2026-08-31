import Foundation
#if canImport(Security)
import Security
#endif

private enum KittyClipboardOperation: String, Sendable {
    case read
    case write
    case wdata
    case walias
}

private enum KittyClipboardStatus: String, Sendable, Error {
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
    let mime: String?
    let name: String?
    let password: Data?

    enum ParseResult {
        case valid(KittyClipboardMetadata)
        case invalid(K44RawOperation?)
    }

    enum K44RawOperation: Sendable, Equatable {
        case read
        case write
        case wdata
        case walias
        case unknown

        init(_ bytes: ArraySlice<UInt8>) {
            switch String(decoding: bytes, as: UTF8.self) {
            case "read": self = .read
            case "write": self = .write
            case "wdata": self = .wdata
            case "walias": self = .walias
            default: self = .unknown
            }
        }
    }

    static func parse(_ bytes: ArraySlice<UInt8>) -> ParseResult {
        guard !bytes.isEmpty else { return .invalid(nil) }
        var values: [String: ArraySlice<UInt8>] = [:]
        var rawOperation: K44RawOperation?
        for field in bytes.split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false) {
            guard let equals = field.firstIndex(of: UInt8(ascii: "=")),
                  field[..<equals].elementsEqual("type".utf8)
            else {
                continue
            }
            rawOperation = K44RawOperation(field[field.index(after: equals)...])
        }
        var start = bytes.startIndex
        while true {
            let end = bytes[start...].firstIndex(of: UInt8(ascii: ":")) ?? bytes.endIndex
            let field = bytes[start..<end]
            guard let equals = field.firstIndex(of: UInt8(ascii: "=")) else {
                return .invalid(rawOperation)
            }
            let key = String(decoding: field[..<equals], as: UTF8.self)
            let value = field[field.index(after: equals)...]
            switch key {
            case "type", "loc", "id", "mime", "pw", "name", "status":
                values[key] = value
            default:
                break
            }
            guard end != bytes.endIndex else { break }
            start = bytes.index(after: end)
        }

        guard let typeBytes = values["type"],
              let operation = KittyClipboardOperation(
                rawValue: String(decoding: typeBytes, as: UTF8.self))
        else {
            return .invalid(rawOperation)
        }

        let location: KittyClipboardLocation = values["loc"].map {
            String(decoding: $0, as: UTF8.self)
        } == "primary" ? .primary : .clipboard

        var sanitizedID: [UInt8] = []
        sanitizedID.reserveCapacity(512)
        for byte in values["id"] ?? [] where sanitizedID.count < 512 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"),
                 UInt8(ascii: "+"), UInt8(ascii: "."):
                sanitizedID.append(byte)
            default:
                break
            }
        }

        let mime: String?
        if let encoded = values["mime"] {
            guard case .success(let data) = StrictBase64.decode(encoded, maximumDecodedBytes: 256),
                  let value = String(data: data, encoding: .utf8)
            else {
                return .invalid(rawOperation)
            }
            mime = value
        } else {
            mime = nil
        }

        let name: String?
        if let encoded = values["name"] {
            guard case .success(let data) = StrictBase64.decode(encoded, maximumDecodedBytes: 256),
                  let value = String(data: data, encoding: .utf8)
            else {
                return .invalid(rawOperation)
            }
            name = value.isEmpty ? nil : value
        } else {
            name = nil
        }

        var password: Data?
        if let encoded = values["pw"] {
            switch StrictBase64.decode(encoded, maximumDecodedBytes: 128) {
            case .success(let data):
                guard String(data: data, encoding: .utf8) != nil else {
                    return .invalid(rawOperation)
                }
                password = data.isEmpty ? nil : data
            case .tooLarge:
                password = nil
            case .invalid:
                return .invalid(rawOperation)
            }
        }
        if name == nil {
            password = nil
        }

        return .valid(KittyClipboardMetadata(
            operation: operation,
            location: location,
            id: String(decoding: sanitizedID, as: UTF8.self),
            mime: mime,
            name: name,
            password: password))
    }
}

private enum StrictBase64 {
    enum Result {
        case success(Data)
        case invalid
        case tooLarge
    }

    static func decode(
        _ bytes: ArraySlice<UInt8>,
        maximumDecodedBytes: Int? = nil
    ) -> Result {
        guard bytes.count % 4 == 0 else { return .invalid }
        if let maximumDecodedBytes,
           bytes.count > (maximumDecodedBytes + 2) / 3 * 4
        {
            return .tooLarge
        }
        var output = Data()
        if maximumDecodedBytes == nil {
            output.reserveCapacity(bytes.count / 4 * 3)
        }
        var exceeded = false
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let quartetEnd = bytes.index(index, offsetBy: 4)
            let isLast = quartetEnd == bytes.endIndex
            switch decodeQuartet(bytes[index..<quartetEnd], isLast: isLast) {
            case .invalid:
                return .invalid
            case .success(let decoded):
                if let maximumDecodedBytes,
                   output.count > maximumDecodedBytes - decoded.count
                {
                    exceeded = true
                } else if !exceeded {
                    output.append(contentsOf: decoded)
                }
            }
            index = quartetEnd
        }
        return exceeded ? .tooLarge : .success(output)
    }

    private enum QuartetResult {
        case success([UInt8])
        case invalid
    }

    private static func decodeQuartet(
        _ bytes: ArraySlice<UInt8>,
        isLast: Bool
    ) -> QuartetResult {
        guard bytes.count == 4 else { return .invalid }
        let input = Array(bytes)
        guard let a = StrictBase64Value.value(input[0]),
              let b = StrictBase64Value.value(input[1])
        else {
            return .invalid
        }
        let first = (a << 2) | (b >> 4)
        if input[2] == UInt8(ascii: "=") {
            guard isLast, input[3] == UInt8(ascii: "="), b & 0x0f == 0 else {
                return .invalid
            }
            return .success([first])
        }
        guard let c = StrictBase64Value.value(input[2]) else { return .invalid }
        let second = (b << 4) | (c >> 2)
        if input[3] == UInt8(ascii: "=") {
            guard isLast, c & 0x03 == 0 else { return .invalid }
            return .success([first, second])
        }
        guard let d = StrictBase64Value.value(input[3]) else { return .invalid }
        return .success([first, second, (c << 6) | d])
    }
}

private struct KittyClipboardBase64Stream: Sendable {
    private(set) var data = Data()
    private var carry: [UInt8] = []
    private var endedAtPacketBoundary = false

    mutating func append(
        _ bytes: ArraySlice<UInt8>,
        remainingLimit: Int
    ) -> KittyClipboardStatus? {
        if endedAtPacketBoundary {
            endedAtPacketBoundary = false
        }
        var available = remainingLimit
        var offset = bytes.startIndex

        // Complete a quartet carried over from the previous packet.
        while !carry.isEmpty, offset < bytes.endIndex {
            if let status = pushCarryByte(bytes[offset]) { return status }
            offset += 1
            if carry.count == 4 {
                if let status = decodeCarryQuartet(
                    available: &available,
                    atPacketEnd: offset == bytes.endIndex)
                {
                    return status
                }
            }
        }

        // Bulk-decode aligned quartets without per-quartet allocation.
        let wholeQuartetBytes = (bytes.endIndex - offset) / 4 * 4
        if wholeQuartetBytes > 0 {
            let bulkEnd = offset + wholeQuartetBytes
            if let status = decodeBulk(
                bytes[offset..<bulkEnd],
                atPacketEnd: bulkEnd == bytes.endIndex,
                available: &available)
            {
                return status
            }
            offset = bulkEnd
        }

        // Carry the zero-to-three-byte tail for the next packet.
        while offset < bytes.endIndex {
            if let status = pushCarryByte(bytes[offset]) { return status }
            offset += 1
        }
        return nil
    }

    private mutating func pushCarryByte(_ byte: UInt8) -> KittyClipboardStatus? {
        carry.append(byte)
        guard carry.count < 4 else { return nil }
        if byte == UInt8(ascii: "=") {
            guard carry.count == 3 else { return .invalid }
        } else {
            guard StrictBase64Value.isAlphabet(byte) else { return .invalid }
        }
        return nil
    }

    private mutating func decodeCarryQuartet(
        available: inout Int,
        atPacketEnd: Bool
    ) -> KittyClipboardStatus? {
        let padded = carry.contains(UInt8(ascii: "="))
        switch StrictBase64.decode(carry[...]) {
        case .success(let decoded):
            guard decoded.count <= available else { return .tooLarge }
            data.append(decoded)
            available -= decoded.count
        case .invalid, .tooLarge:
            return .invalid
        }
        carry.removeAll(keepingCapacity: true)
        if padded {
            guard atPacketEnd else { return .invalid }
            endedAtPacketBoundary = true
        }
        return nil
    }

    private mutating func decodeBulk(
        _ bytes: ArraySlice<UInt8>,
        atPacketEnd: Bool,
        available: inout Int
    ) -> KittyClipboardStatus? {
        let pad = UInt8(ascii: "=")
        // Bound the transient buffer so one huge packet does not duplicate
        // its decoded form in a second large allocation.
        let flushLimit = 48 * 1024
        var chunk = [UInt8]()
        chunk.reserveCapacity(min(bytes.count / 4 * 3, flushLimit))
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            if bytes[offset] == pad || bytes[offset + 1] == pad
                || bytes[offset + 2] == pad || bytes[offset + 3] == pad
            {
                // Terminal padding is valid only in the packet's last quartet.
                guard offset + 4 == bytes.endIndex, atPacketEnd else {
                    return .invalid
                }
                switch StrictBase64.decode(bytes[offset..<(offset + 4)]) {
                case .success(let tail):
                    chunk.append(contentsOf: tail)
                    endedAtPacketBoundary = true
                case .invalid, .tooLarge:
                    return .invalid
                }
            } else {
                guard let a = StrictBase64Value.value(bytes[offset]),
                      let b = StrictBase64Value.value(bytes[offset + 1]),
                      let c = StrictBase64Value.value(bytes[offset + 2]),
                      let d = StrictBase64Value.value(bytes[offset + 3])
                else {
                    return .invalid
                }
                chunk.append((a << 2) | (b >> 4))
                chunk.append((b << 4) | (c >> 2))
                chunk.append((c << 6) | d)
            }
            offset += 4
            if chunk.count >= flushLimit {
                guard chunk.count <= available else { return .tooLarge }
                data.append(contentsOf: chunk)
                available -= chunk.count
                chunk.removeAll(keepingCapacity: true)
            }
        }
        guard chunk.count <= available else { return .tooLarge }
        data.append(contentsOf: chunk)
        available -= chunk.count
        return nil
    }

    func isComplete() -> Bool { carry.isEmpty }
}

private enum StrictBase64Value {
    static func isAlphabet(_ byte: UInt8) -> Bool {
        value(byte) != nil
    }

    static func value(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"):
            return byte - UInt8(ascii: "A")
        case UInt8(ascii: "a")...UInt8(ascii: "z"):
            return byte - UInt8(ascii: "a") + 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return byte - UInt8(ascii: "0") + 52
        case UInt8(ascii: "+"):
            return 62
        case UInt8(ascii: "/"):
            return 63
        default:
            return nil
        }
    }
}

private struct KittyClipboardWriteTransaction: Sendable {
    let location: KittyClipboardLocation
    let id: String
    let password: Data?
    let name: String?
    let byteLimit: Int

    private struct Region: Sendable {
        let type: String
        var stream: KittyClipboardBase64Stream
    }

    private(set) var decodedBytes = 0
    private var regions: [Region] = []
    private var activeRegion: Region?
    private var ignoredRegion = false
    private var aliases: [(name: String, target: String)] = []

    mutating func append(type: String, payload: ArraySlice<UInt8>) -> KittyClipboardStatus? {
        if activeRegion?.type != type || ignoredRegion {
            if let status = finishActiveRegion() { return status }
            guard regions.count < 64 else {
                ignoredRegion = true
                return nil
            }
            activeRegion = Region(type: type, stream: KittyClipboardBase64Stream())
            ignoredRegion = false
        }
        guard var region = activeRegion else { return nil }
        // Keep the spool uniquely referenced while it grows, or every packet
        // recopies the accumulated bytes through copy-on-write.
        activeRegion = nil
        let before = region.stream.data.count
        if let status = region.stream.append(
            payload,
            remainingLimit: max(0, byteLimit - decodedBytes))
        {
            return status
        }
        decodedBytes += region.stream.data.count - before
        activeRegion = region
        return nil
    }

    mutating func addAliases(target: String, payload: ArraySlice<UInt8>) -> KittyClipboardStatus? {
        guard case .success(let decoded) = StrictBase64.decode(payload),
              let text = String(data: decoded, encoding: .utf8)
        else {
            return .invalid
        }
        var invalid = false
        scanASCIIWords(text) { word in
            let alias = String(word)
            guard alias.utf8.count <= 256 else {
                invalid = true
                return false
            }
            if let index = aliases.firstIndex(where: { $0.name == alias }) {
                aliases[index].target = target
            } else if aliases.count < 64 {
                aliases.append((name: alias, target: target))
            }
            return true
        }
        return invalid ? .invalid : nil
    }

    mutating func commit() -> Result<[KittyClipboardRepresentation], KittyClipboardStatus> {
        if let status = finishActiveRegion() { return .failure(status) }
        var contents: [KittyClipboardRepresentation] = []
        for region in regions {
            let value = KittyClipboardRepresentation(type: region.type, data: region.stream.data)
            if let index = contents.firstIndex(where: { $0.type == region.type }) {
                contents[index] = value
            } else {
                contents.append(value)
            }
        }
        for alias in aliases {
            guard let target = contents.first(where: { $0.type == alias.target }) else { continue }
            let value = KittyClipboardRepresentation(type: alias.name, data: target.data)
            if let index = contents.firstIndex(where: { $0.type == alias.name }) {
                contents[index] = value
            } else {
                contents.append(value)
            }
        }
        return .success(contents)
    }

    private mutating func finishActiveRegion() -> KittyClipboardStatus? {
        guard let region = activeRegion else {
            ignoredRegion = false
            return nil
        }
        guard region.stream.isComplete() else { return .invalid }
        regions.append(region)
        activeRegion = nil
        ignoredRegion = false
        return nil
    }
}

private func scanASCIIWords(_ string: String, _ body: (Substring) -> Bool) {
    func separator(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n"
            || character == "\r" || character == "\u{0b}" || character == "\u{0c}"
    }
    var start: String.Index?
    var index = string.startIndex
    while index < string.endIndex {
        if separator(string[index]) {
            if let start, !body(string[start..<index]) { return }
            start = nil
        } else if start == nil {
            start = index
        }
        index = string.index(after: index)
    }
    if let start { _ = body(string[start...]) }
}

private struct KittyClipboardPending: Sendable, Equatable {
    let token: UInt64
    let direction: KittyClipboardGrantDirection
}

private struct KittyClipboardReadWork: Sendable {
    let token: UInt64
    let location: KittyClipboardLocation
    let id: String
    let password: Data?
    let name: String?
    let requested: [String]
    let requestsTypeList: Bool
    let canRemember: Bool
}

private struct KittyClipboardWriteWork: Sendable {
    let token: UInt64
    let location: KittyClipboardLocation
    let id: String
    let password: Data?
    let canRemember: Bool
}

private struct KittyClipboardPasteGrant: Sendable {
    let password: Data
    let location: KittyClipboardLocation
    let deadline: Date
    let availableTypes: [String]
    let reader: TerminalPasteRequest.Reader
    let order: UInt64
}

private final class KittyClipboardCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}

final class KittyClipboardProtocol: @unchecked Sendable {
    private enum WriteInputState: Sendable {
        case idle
        case receiving(KittyClipboardWriteTransaction)
        case discarding
    }

    private weak var terminal: Terminal?
    private var writeInput: WriteInputState = .idle
    private var pending: KittyClipboardPending?
    private var generation: UInt64 = 0
    private var grants = KittyClipboardGrants()
    private var pasteGrants: [KittyClipboardPasteGrant] = []
    private var grantOrder: UInt64 = 0

    init(terminal: Terminal) {
        self.terminal = terminal
    }

    func hardReset() {
        terminal?.terminalLock.preconditionLocked()
        generation &+= 1
        pending = nil
        writeInput = .idle
        grants.clear()
        pasteGrants.removeAll(keepingCapacity: true)
    }

    func softReset() {
        terminal?.terminalLock.preconditionLocked()
        writeInput = .idle
        revokePasteGrants()
    }

    func terminalDestroyed() {
        generation &+= 1
        pending = nil
        writeInput = .idle
        grants.clear()
        pasteGrants.removeAll()
        terminal = nil
    }

    func revokePasteGrants() {
        pasteGrants.removeAll(keepingCapacity: true)
    }

    func pasteEventsSupported() -> Bool {
        guard let terminal, terminal.options.kittyClipboard.enabled else { return false }
        return terminal.tdel?.kittyClipboardPasteEventsSupported(source: terminal) ?? false
    }

    func paste(_ request: TerminalPasteRequest, allowUnsafe: Bool) -> TerminalPasteResult {
        guard let terminal else { return .unsupported }
        if case .clipboard(let location) = request.source,
           terminal.kittyClipboardPasteMode,
           pasteEventsSupported(),
           let reader = request.read
        {
            guard let passwordString = terminal.kittyClipboardPasswordGenerator() else {
                return .entropyUnavailable
            }
            let password = Data(passwordString.utf8)
            guard password.count >= 16 else { return .entropyUnavailable }
            removeExpiredPasteGrants(now: terminal.kittyClipboardNow())
            makeGrantSpace()
            grantOrder &+= 1
            pasteGrants.append(KittyClipboardPasteGrant(
                password: password,
                location: location,
                deadline: terminal.kittyClipboardNow().addingTimeInterval(30),
                availableTypes: request.types,
                reader: reader,
                order: grantOrder))
            sendReadSuccess(
                location: location,
                id: "",
                password: password,
                requestsTypeList: true,
                availableTypes: request.types,
                requestedTypes: [],
                representations: [])
            return .kittyEvent(password: passwordString)
        }

        guard let text = request.text else { return .requiresText }
        let encoded = TerminalPaste.encode(
            text,
            bracketed: terminal.bracketedPasteMode,
            terminalControlBytes: terminal.tdel?.terminalControlBytesForPaste(source: terminal)
                ?? TerminalPasteControls.approximateTerminalControlBytes,
            allowUnsafe: allowUnsafe)
        guard case .encoded(let bytes) = encoded else { return .unsafePayload }
        terminal.registerUserInput(bytes[...])
        terminal.tdel?.send(source: terminal, data: bytes[...])
        return .text
    }

    func handle(_ data: ArraySlice<UInt8>) {
        guard let terminal, terminal.options.kittyClipboard.enabled else { return }
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
        case .invalid(let rawOperation):
            if rawOperation == .wdata || rawOperation == .walias {
                abortActiveWrite(status: .invalid)
            }
        case .valid(let metadata):
            switch metadata.operation {
            case .read:
                handleRead(metadata, payload: payload)
            case .write:
                beginWrite(metadata)
            case .wdata:
                handleWriteData(metadata, payload: payload)
            case .walias:
                handleWriteAlias(metadata, payload: payload)
            }
        }
    }

    private func handleRead(
        _ metadata: KittyClipboardMetadata,
        payload: ArraySlice<UInt8>
    ) {
        guard case .success(let decoded) = StrictBase64.decode(payload),
              let text = String(data: decoded, encoding: .utf8)
        else {
            return
        }
        var requestsTypeList = false
        var requested: [String] = []
        var invalid = false
        scanASCIIWords(text) { word in
            let type = String(word)
            guard type.utf8.count <= 256 else {
                invalid = true
                return false
            }
            if type == "." {
                requestsTypeList = true
            } else if requested.count < 64 {
                requested.append(type)
            }
            return true
        }
        guard !invalid else { return }

        if pending != nil || isReceivingWrite {
            sendStatus(operation: .read, status: .busy, id: metadata.id)
            return
        }

        let listingOnly = requested.isEmpty
        let pasteGrant = lookupPasteGrant(
            password: metadata.password,
            location: metadata.location,
            consume: !listingOnly)
        let hasGrant = pasteGrant != nil || grants.contains(
            password: metadata.password,
            direction: .read,
            location: metadata.location)
        let authorization: KittyClipboardAuthorization = listingOnly
            ? .notRequired
            : (hasGrant ? .granted : .required)
        let canRemember = !listingOnly && metadata.password != nil && authorization == .required

        let token = nextToken(direction: .read)
        let work = KittyClipboardReadWork(
            token: token,
            location: metadata.location,
            id: metadata.id,
            password: metadata.password,
            name: metadata.name,
            requested: requested,
            requestsTypeList: requestsTypeList,
            canRemember: canRemember)
        let request = KittyClipboardReadRequest(
            location: metadata.location,
            types: requested,
            requestsTypeList: requestsTypeList,
            applicationName: metadata.name,
            authorization: authorization,
            canRemember: canRemember)
        let gate = KittyClipboardCompletionGate()
        let completion: @Sendable (KittyClipboardReadResult) -> Void = { [weak self] result in
            guard gate.take() else { return }
            self?.completeRead(work, result: result)
        }
        if let pasteGrant {
            pasteGrant.reader(request, completion)
        } else if let delegate = terminal?.tdel, let terminal {
            delegate.kittyClipboardRead(source: terminal, request: request, completion: completion)
        } else {
            completion(.denied)
        }
    }

    private func completeRead(_ work: KittyClipboardReadWork, result: KittyClipboardReadResult) {
        withTerminalLock { [weak self] in
            guard let self,
                  self.pending == KittyClipboardPending(token: work.token, direction: .read)
            else {
                return
            }
            self.pending = nil
            switch result {
            case .success(let success):
                if success.remember, work.canRemember, let password = work.password {
                    self.addSessionGrant(
                        password: password,
                        direction: .read,
                        location: work.location)
                }
                self.sendReadSuccess(
                    location: work.location,
                    id: work.id,
                    password: nil,
                    requestsTypeList: work.requestsTypeList,
                    availableTypes: success.availableTypes,
                    requestedTypes: work.requested,
                    representations: success.representations)
            case .denied:
                self.sendStatus(operation: .read, status: .permission, id: work.id)
            case .unsupported:
                self.sendStatus(operation: .read, status: .unsupported, id: work.id)
            case .busy, .ioError:
                self.sendStatus(operation: .read, status: .busy, id: work.id)
            }
        }
    }

    private func beginWrite(_ metadata: KittyClipboardMetadata) {
        if pending != nil {
            sendStatus(operation: .write, status: .busy, id: metadata.id)
            writeInput = .discarding
            return
        }
        let configured = terminal?.options.kittyClipboard.writeLimitBytes ?? Int.max
        let limit = terminal?.kittyClipboardWriteLimitOverride ?? configured
        writeInput = .receiving(KittyClipboardWriteTransaction(
            location: metadata.location,
            id: metadata.id,
            password: metadata.password,
            name: metadata.name,
            byteLimit: limit))
    }

    private func handleWriteData(
        _ metadata: KittyClipboardMetadata,
        payload: ArraySlice<UInt8>
    ) {
        guard case .receiving(var transaction) = writeInput else { return }
        // Release the stored copy so the transaction's spool stays uniquely
        // referenced while it mutates; every path below stores the next state.
        writeInput = .idle
        if let type = metadata.mime {
            guard !type.isEmpty else {
                abortWrite(transaction, status: .invalid)
                return
            }
            if let status = transaction.append(type: type, payload: payload) {
                abortWrite(transaction, status: status)
                return
            }
            writeInput = .receiving(transaction)
            return
        }
        guard payload.isEmpty else {
            abortWrite(transaction, status: .invalid)
            return
        }
        switch transaction.commit() {
        case .failure(let status):
            abortWrite(transaction, status: status)
        case .success(let representations):
            commitWrite(transaction, representations: representations)
        }
    }

    private func handleWriteAlias(
        _ metadata: KittyClipboardMetadata,
        payload: ArraySlice<UInt8>
    ) {
        guard case .receiving(var transaction) = writeInput else { return }
        writeInput = .idle
        guard let target = metadata.mime, !target.isEmpty else {
            abortWrite(transaction, status: .invalid)
            return
        }
        if let status = transaction.addAliases(target: target, payload: payload) {
            abortWrite(transaction, status: status)
        } else {
            writeInput = .receiving(transaction)
        }
    }

    private func commitWrite(
        _ transaction: KittyClipboardWriteTransaction,
        representations: [KittyClipboardRepresentation]
    ) {
        let hasGrant = grants.contains(
            password: transaction.password,
            direction: .write,
            location: transaction.location)
        let authorization: KittyClipboardAuthorization = hasGrant ? .granted : .required
        let canRemember = transaction.password != nil && authorization == .required
        let token = nextToken(direction: .write)
        let work = KittyClipboardWriteWork(
            token: token,
            location: transaction.location,
            id: transaction.id,
            password: transaction.password,
            canRemember: canRemember)
        let request = KittyClipboardWriteRequest(
            location: transaction.location,
            representations: representations,
            applicationName: transaction.name,
            authorization: authorization,
            canRemember: canRemember)
        let gate = KittyClipboardCompletionGate()
        let completion: @Sendable (KittyClipboardWriteResult) -> Void = { [weak self] result in
            guard gate.take() else { return }
            self?.completeWrite(work, result: result)
        }
        if let delegate = terminal?.tdel, let terminal {
            delegate.kittyClipboardWrite(source: terminal, request: request, completion: completion)
        } else {
            completion(.unsupported)
        }
    }

    private func completeWrite(_ work: KittyClipboardWriteWork, result: KittyClipboardWriteResult) {
        withTerminalLock { [weak self] in
            guard let self,
                  self.pending == KittyClipboardPending(token: work.token, direction: .write)
            else {
                return
            }
            self.pending = nil
            let status: KittyClipboardStatus
            switch result {
            case .success(let success):
                if success.remember, work.canRemember, let password = work.password {
                    self.addSessionGrant(
                        password: password,
                        direction: .write,
                        location: work.location)
                }
                status = .done
            case .denied: status = .permission
            case .unsupported: status = .unsupported
            case .busy: status = .busy
            case .invalidData: status = .invalid
            case .ioError: status = .io
            }
            self.sendStatus(operation: .write, status: status, id: work.id)
        }
    }

    private var isReceivingWrite: Bool {
        if case .receiving = writeInput { return true }
        return false
    }

    private func abortActiveWrite(status: KittyClipboardStatus) {
        guard case .receiving(let transaction) = writeInput else { return }
        abortWrite(transaction, status: status)
    }

    private func abortWrite(
        _ transaction: KittyClipboardWriteTransaction,
        status: KittyClipboardStatus
    ) {
        writeInput = .discarding
        sendStatus(operation: .write, status: status, id: transaction.id)
    }

    private func nextToken(direction: KittyClipboardGrantDirection) -> UInt64 {
        generation &+= 1
        let token = generation
        pending = KittyClipboardPending(token: token, direction: direction)
        return token
    }

    private func lookupPasteGrant(
        password: Data?,
        location: KittyClipboardLocation,
        consume: Bool
    ) -> KittyClipboardPasteGrant? {
        guard let terminal, let password else { return nil }
        removeExpiredPasteGrants(now: terminal.kittyClipboardNow())
        guard let index = pasteGrants.firstIndex(where: {
            $0.password == password && $0.location == location
        }) else {
            return nil
        }
        if consume {
            return pasteGrants.remove(at: index)
        }
        return pasteGrants[index]
    }

    private func removeExpiredPasteGrants(now: Date) {
        pasteGrants.removeAll { $0.deadline <= now }
    }

    private func addSessionGrant(
        password: Data,
        direction: KittyClipboardGrantDirection,
        location: KittyClipboardLocation
    ) {
        grants.remove(password: password, direction: direction, location: location)
        makeGrantSpace()
        grantOrder &+= 1
        grants.add(
            password: password,
            direction: direction,
            location: location,
            order: grantOrder)
    }

    private func makeGrantSpace() {
        guard grants.count + pasteGrants.count >= KittyClipboardGrants.maximumCount else {
            return
        }
        let sessionOrder = grants.oldestOrder ?? UInt64.max
        let pasteOrder = pasteGrants.first?.order ?? UInt64.max
        if sessionOrder <= pasteOrder {
            grants.removeOldest()
        } else if !pasteGrants.isEmpty {
            pasteGrants.removeFirst()
        }
    }

    private func withTerminalLock(_ body: @escaping @Sendable () -> Void) {
        guard let terminal else { return }
        if terminal.terminalLock.isLockedByCurrentThread {
            body()
        } else {
            terminal.terminalLock.withLock(body)
        }
    }

    private func sendStatus(
        operation: KittyClipboardOperation,
        status: KittyClipboardStatus,
        id: String
    ) {
        sendPacket(operation: operation, status: status, id: id)
    }

    private func sendReadSuccess(
        location: KittyClipboardLocation,
        id: String,
        password: Data?,
        requestsTypeList: Bool,
        availableTypes: [String],
        requestedTypes: [String],
        representations: [KittyClipboardRepresentation]
    ) {
        sendPacket(
            operation: .read,
            status: .ok,
            location: location,
            id: id,
            password: password)
        if requestsTypeList {
            let listing = availableTypes.isEmpty
                ? Data()
                : Data((availableTypes.joined(separator: " ") + "\n").utf8)
            sendData(type: ".", data: listing, id: id, password: password, emitEmpty: true)
        }
        var firstByType: [String: Data] = [:]
        for representation in representations where firstByType[representation.type] == nil {
            firstByType[representation.type] = representation.data
        }
        for type in requestedTypes {
            guard let data = firstByType[type] else { continue }
            sendData(type: type, data: data, id: id, password: password, emitEmpty: true)
        }
        sendPacket(operation: .read, status: .done, id: id, password: password)
    }

    private func sendData(
        type: String,
        data: Data,
        id: String,
        password: Data?,
        emitEmpty: Bool
    ) {
        if data.isEmpty {
            if emitEmpty {
                sendPacket(
                    operation: .read,
                    status: .data,
                    id: id,
                    mime: type,
                    password: password,
                    payload: Data())
            }
            return
        }
        // Host-supplied Data can be a slice whose indices do not start at zero.
        var index = data.startIndex
        while index < data.endIndex {
            let end = data.index(index, offsetBy: 4096, limitedBy: data.endIndex)
                ?? data.endIndex
            sendPacket(
                operation: .read,
                status: .data,
                id: id,
                mime: type,
                password: password,
                payload: data[index..<end])
            index = end
        }
    }

    private func sendPacket(
        operation: KittyClipboardOperation,
        status: KittyClipboardStatus,
        location: KittyClipboardLocation? = nil,
        id: String = "",
        mime: String? = nil,
        password: Data? = nil,
        payload: Data? = nil
    ) {
        guard let terminal else { return }
        var metadata = "5522;type=\(operation.rawValue):status=\(status.rawValue)"
        if location == .primary { metadata += ":loc=primary" }
        if !id.isEmpty { metadata += ":id=\(id)" }
        if let mime, !mime.isEmpty {
            metadata += ":mime=\(Data(mime.utf8).base64EncodedString())"
        }
        if let password, !password.isEmpty {
            metadata += ":pw=\(password.base64EncodedString())"
        }
        if let payload {
            metadata += ";\(payload.base64EncodedString())"
        }
        terminal.sendResponse(terminal.cc.OSC, metadata, terminal.cc.ST)
    }
}

enum KittyClipboardOTP {
    static func generate() -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
#if canImport(Security)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
#else
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
#endif
        return Data(bytes).base64EncodedString()
    }
}
