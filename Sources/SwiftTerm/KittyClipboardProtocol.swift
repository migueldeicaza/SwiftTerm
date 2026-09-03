//
// KittyClipboardProtocol.swift
//
// DEC private mode 5522 (paste events) and the Kitty clipboard protocol,
// OSC 5522.
//
// The mode is reported as supported only when the host serves the complete
// extension for the standard clipboard: enumeration, one representation read,
// and one atomic multi-representation write. Both the terminal policy in
// ``TerminalOptions/kittyClipboardPolicy`` and the host capability set must
// allow an operation.
//
import Foundation
#if canImport(Security)
import Security
#endif

// MARK: - Public API

/// The clipboard selected by an OSC 5522 request.
public enum KittyClipboardLocation: Sendable, Equatable, Hashable {
    case standard
    case primary
}

/// OSC 5522 services that a host explicitly makes available.
///
/// Mode 5522 is reported as supported only when the host offers both
/// ``standardRead`` and ``standardWrite``. The primary-selection services are
/// optional; a host that does not provide them makes `loc=primary` answer
/// `ENOSYS`.
public struct KittyClipboardCapabilities: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The host can enumerate and read the standard clipboard.
    public static let standardRead = KittyClipboardCapabilities(rawValue: 1 << 0)
    /// The host can publish all representations of one write to the standard
    /// clipboard as one atomic operation.
    public static let standardWrite = KittyClipboardCapabilities(rawValue: 1 << 1)
    /// The host can enumerate and read the primary selection.
    public static let primaryRead = KittyClipboardCapabilities(rawValue: 1 << 2)
    /// The host can publish one atomic write to the primary selection.
    public static let primaryWrite = KittyClipboardCapabilities(rawValue: 1 << 3)

    /// The standard-clipboard service set that mode 5522 requires.
    public static let standard: KittyClipboardCapabilities = [.standardRead, .standardWrite]
    /// Every service, including the optional primary selection.
    public static let all: KittyClipboardCapabilities =
        [.standardRead, .standardWrite, .primaryRead, .primaryWrite]

    /// Source-compatible name for ``standardRead``.
    public static let read = KittyClipboardCapabilities.standardRead
    /// Source-compatible name for ``standardWrite``.
    public static let write = KittyClipboardCapabilities.standardWrite

    func allows(direction: KittyClipboardPermissionDirection, location: KittyClipboardLocation) -> Bool {
        switch (direction, location) {
        case (.read, .standard): return contains(.standardRead)
        case (.write, .standard): return contains(.standardWrite)
        case (.read, .primary): return contains(.primaryRead)
        case (.write, .primary): return contains(.primaryWrite)
        }
    }
}

/// Terminal policy applied in addition to the host's explicit capability result.
///
/// The default in ``TerminalOptions`` is empty, so a host must opt in.
public struct KittyClipboardPolicy: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let read = KittyClipboardPolicy(rawValue: 1 << 0)
    public static let write = KittyClipboardPolicy(rawValue: 1 << 1)
    public static let all: KittyClipboardPolicy = [.read, .write]

    func allows(direction: KittyClipboardPermissionDirection) -> Bool {
        switch direction {
        case .read: return contains(.read)
        case .write: return contains(.write)
        }
    }
}

public enum KittyClipboardPermissionDirection: Sendable, Equatable {
    case read
    case write
}

public struct KittyClipboardPermissionRequest: Sendable {
    public let direction: KittyClipboardPermissionDirection
    public let location: KittyClipboardLocation
    /// The decoded `name` field. It is untrusted application-supplied text.
    public let name: String
    public let mimeTypes: [String]
    /// Whether the host can offer a persistent session grant for this password.
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

/// One clipboard representation: a MIME name and its bytes.
public struct KittyClipboardRepresentation: Sendable, Equatable {
    public let mimeType: String
    public let data: Data

    public init(mimeType: String, data: Data) {
        self.mimeType = mimeType
        self.data = data
    }
}

/// One additional MIME name that refers to the bytes of ``target``.
public struct KittyClipboardAlias: Sendable, Equatable, Hashable {
    public let name: String
    public let target: String

    public init(name: String, target: String) {
        self.name = name
        self.target = target
    }
}

/// Everything one OSC 5522 write transaction publishes.
///
/// The host must publish all of it or none of it.
public struct KittyClipboardWriteContent: Sendable, Equatable {
    public let representations: [KittyClipboardRepresentation]
    /// Alias relations. Each alias names the same bytes as its target, which is
    /// one of the ``representations``. The data is not copied.
    public let aliases: [KittyClipboardAlias]

    public init(
        representations: [KittyClipboardRepresentation],
        aliases: [KittyClipboardAlias] = []
    ) {
        self.representations = representations
        self.aliases = aliases
    }

    /// The representations with every alias resolved to its own entry.
    ///
    /// A host whose platform pasteboard cannot express aliases can publish
    /// this list instead.
    public var flattened: [KittyClipboardRepresentation] {
        var result = representations
        for alias in aliases {
            guard let target = representations.first(where: { $0.mimeType == alias.target })
            else { continue }
            let value = KittyClipboardRepresentation(mimeType: alias.name, data: target.data)
            if let index = result.firstIndex(where: { $0.mimeType == alias.name }) {
                result[index] = value
            } else {
                result.append(value)
            }
        }
        return result
    }
}

/// The typed outcome of one representation read.
public enum KittyClipboardReadResult: Sendable, Equatable {
    /// The representation exists. Empty data is a valid representation.
    case data(Data)
    /// The location has no such representation, or the snapshot is stale.
    case unavailable
    /// The system, host policy, or user denied the read.
    case denied
    /// A temporary clipboard or multiplexer conflict prevents the read.
    case busy
}

public enum KittyClipboardWriteResult: Sendable, Equatable {
    case success
    case denied
    case unsupported
    case busy
    case invalidData
    case ioError
    /// The host cannot store data of this size.
    case tooLarge
}

/// The clipboard state captured when a user paste action starts.
///
/// The adapter enumerates the MIME names once and reads a representation only
/// after the terminal application asks for it. ``identity`` is the platform
/// change counter at capture time; a reader whose clipboard has been replaced
/// must answer ``KittyClipboardReadResult/unavailable``.
public struct TerminalClipboardSnapshot: Sendable {
    public typealias Reader = @Sendable (
        _ mimeType: String,
        _ completion: @escaping @Sendable (KittyClipboardReadResult) -> Void
    ) -> Bool

    public let location: KittyClipboardLocation
    /// Every available MIME name, in platform order, with duplicates removed.
    public let mimeTypes: [String]
    /// The platform change counter at capture time.
    public let identity: UInt64
    /// How long the snapshot stays usable. `nil` uses the protocol's own
    /// 30-second paste-token lifetime, which is also the upper bound.
    public let expiresAfter: TimeInterval?
    /// Reads one representation. It returns `false` when it did not accept the
    /// work, and otherwise invokes its completion exactly once.
    public let read: Reader

    public init(
        location: KittyClipboardLocation,
        mimeTypes: [String],
        identity: UInt64 = 0,
        expiresAfter: TimeInterval? = nil,
        read: @escaping Reader
    ) {
        self.location = location
        self.mimeTypes = mimeTypes
        self.identity = identity
        self.expiresAfter = expiresAfter
        self.read = read
    }
}

public enum TerminalPasteSource: Sendable, Equatable {
    case clipboard(KittyClipboardLocation)
    case text
}

/// One paste action offered to the terminal.
public struct TerminalPasteRequest: Sendable {
    public let source: TerminalPasteSource
    /// The UTF-8 text used when no paste event is sent. `nil` means the host
    /// keeps its own text-paste path and expects ``TerminalPasteResult/failed``.
    public let text: String?
    /// The clipboard snapshot for a `clipboard` source. Without one, no paste
    /// event is possible.
    public let snapshot: TerminalClipboardSnapshot?

    public init(
        source: TerminalPasteSource,
        text: String? = nil,
        snapshot: TerminalClipboardSnapshot? = nil
    ) {
        self.source = source
        self.text = text
        self.snapshot = snapshot
    }

    /// Text insertion that is not a clipboard paste event.
    public init(text: String) {
        self.init(source: .text, text: text)
    }
}

/// The single outcome of one paste action.
public enum TerminalPasteResult: Sendable, Equatable {
    /// The output sink accepted the one batch that holds all three event packets.
    case eventSent
    /// No event was started and the text was sent.
    case textSent
    /// The paste safety policy rejected the text.
    case rejected
    /// Neither event bytes nor text bytes were sent.
    case failed

    /// Whether the host can still run its own text-paste path for this action.
    public var needsTextFallback: Bool {
        self == .failed
    }
}

// MARK: - Wire vocabulary

enum KittyClipboardOSCTerminator: Sendable {
    case bell
    case stringTerminator
    case c1StringTerminator
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

/// The base64 name of the MIME-list pseudo type `.`.
private let kittyClipboardListMimeBase64 = "Lg=="

/// The 7-bit introducer and terminator used for every generated packet.
private let kittyClipboardOSCIntroducer: [UInt8] = [0x1b, UInt8(ascii: "]")]
private let kittyClipboardOSCTerminatorBytes: [UInt8] = [0x1b, UInt8(ascii: "\\")]

/// Decoded bytes carried by one `DATA` packet.
private let kittyClipboardChunkBytes = 4096

/// Paste-token lifetime, in nanoseconds.
private let kittyClipboardTokenLifetimeNanoseconds: UInt64 = 30 * 1_000_000_000

/// Live paste tokens kept for one session.
private let kittyClipboardMaximumTokens = 8 * 4

// MARK: - MIME names

enum KittyClipboardMime {
    /// Whether `name` is a syntactically valid `type/subtype` media name.
    ///
    /// Parameters, whitespace, and non-ASCII bytes are rejected. The Apple
    /// adapters use this to keep native pasteboard identifiers that have no
    /// MIME mapping out of the advertised list.
    static func isValid(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count > 2, bytes.count <= 255 else { return false }
        guard let slash = bytes.firstIndex(of: UInt8(ascii: "/")),
              slash > 0,
              slash < bytes.count - 1,
              bytes.lastIndex(of: UInt8(ascii: "/")) == slash
        else {
            return false
        }
        for (offset, byte) in bytes.enumerated() where offset != slash {
            guard isTokenByte(byte) else { return false }
        }
        return true
    }

    /// The ASCII-lowercase form used to compare two MIME names.
    static func matchKey(_ name: String) -> String {
        var bytes = Array(name.utf8)
        for index in bytes.indices
        where bytes[index] >= UInt8(ascii: "A") && bytes[index] <= UInt8(ascii: "Z") {
            bytes[index] += 0x20
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            return true
        case UInt8(ascii: "!"), UInt8(ascii: "#"), UInt8(ascii: "$"), UInt8(ascii: "&"),
             UInt8(ascii: "^"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "+"),
             UInt8(ascii: "-"):
            return true
        default:
            return false
        }
    }
}

/// Splits ASCII-whitespace-separated words without building intermediate arrays.
private func scanASCIIWords(
    _ bytes: [UInt8],
    _ body: (ArraySlice<UInt8>) -> Bool
) {
    func isSeparator(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d || byte == 0x0b || byte == 0x0c
    }
    var start: Int?
    var index = 0
    while index < bytes.count {
        if isSeparator(bytes[index]) {
            if let value = start, !body(bytes[value..<index]) { return }
            start = nil
        } else if start == nil {
            start = index
        }
        index += 1
    }
    if let value = start {
        _ = body(bytes[value..<bytes.count])
    }
}

// MARK: - Base64

/// Streaming RFC 4648 decoder with the standard alphabet.
///
/// Padding is required, whitespace and line breaks are rejected, noncanonical
/// trailing bits are rejected, and no byte is accepted after final padding. A
/// fragment boundary can fall at any position, including inside a quartet.
struct KittyClipboardBase64Decoder {
    enum Failure: Equatable {
        case invalid
        case tooLarge
    }

    private static let table: [Int8] = {
        var value = [Int8](repeating: -1, count: 256)
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        for (index, byte) in alphabet.enumerated() {
            value[Int(byte)] = Int8(index)
        }
        return value
    }()

    private var accumulator: UInt32 = 0
    private var quartetCount = 0
    private var padding = 0
    private var finished = false
    private(set) var decoded = Data()

    init() {}

    /// Whether every quartet seen so far is complete.
    var isComplete: Bool {
        quartetCount == 0
    }

    /// Appends one base64 fragment. `remainingLimit` bounds the total decoded
    /// byte count of this decoder.
    mutating func append(_ bytes: ArraySlice<UInt8>, remainingLimit: Int) -> Failure? {
        guard !bytes.isEmpty else { return nil }
        if finished { return .invalid }
        if decoded.count > remainingLimit { return .tooLarge }

        var output = [UInt8]()
        output.reserveCapacity((bytes.count / 4) * 3 + 3)
        let budget = remainingLimit - decoded.count

        for byte in bytes {
            if finished { commit(&output); return .invalid }
            if byte == UInt8(ascii: "=") {
                guard quartetCount >= 2 else { commit(&output); return .invalid }
                padding += 1
                quartetCount += 1
                accumulator <<= 6
                if quartetCount == 4 {
                    switch padding {
                    case 1:
                        guard (accumulator >> 6) & 0x03 == 0 else { commit(&output); return .invalid }
                        output.append(UInt8((accumulator >> 16) & 0xff))
                        output.append(UInt8((accumulator >> 8) & 0xff))
                    case 2:
                        guard (accumulator >> 12) & 0x0f == 0 else { commit(&output); return .invalid }
                        output.append(UInt8((accumulator >> 16) & 0xff))
                    default:
                        commit(&output)
                        return .invalid
                    }
                    finished = true
                    accumulator = 0
                    quartetCount = 0
                    padding = 0
                    if output.count > budget {
                        commit(&output)
                        return .tooLarge
                    }
                }
                continue
            }
            guard padding == 0 else { commit(&output); return .invalid }
            let value = Self.table[Int(byte)]
            guard value >= 0 else { commit(&output); return .invalid }
            accumulator = (accumulator << 6) | UInt32(UInt8(bitPattern: value))
            quartetCount += 1
            if quartetCount == 4 {
                output.append(UInt8((accumulator >> 16) & 0xff))
                output.append(UInt8((accumulator >> 8) & 0xff))
                output.append(UInt8(accumulator & 0xff))
                accumulator = 0
                quartetCount = 0
            }
            if output.count > budget {
                commit(&output)
                return .tooLarge
            }
        }
        commit(&output)
        return nil
    }

    private mutating func commit(_ output: inout [UInt8]) {
        if !output.isEmpty {
            decoded.append(contentsOf: output)
            output.removeAll(keepingCapacity: true)
        }
    }

    /// Decodes one complete base64 value.
    static func decode(_ bytes: ArraySlice<UInt8>, maximumDecodedBytes: Int = Int.max) -> Data? {
        var decoder = KittyClipboardBase64Decoder()
        guard decoder.append(bytes, remainingLimit: maximumDecodedBytes) == nil,
              decoder.isComplete
        else {
            return nil
        }
        return decoder.decoded
    }

    static func encode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        Data(bytes).base64EncodedString()
    }
}

// MARK: - Packet metadata

private struct KittyClipboardMetadata: Sendable {
    let operation: KittyClipboardOperation
    let location: KittyClipboardLocation
    let id: String
    let mime: String
    let name: String
    let password: String

    enum ParseResult {
        case valid(KittyClipboardMetadata)
        /// Nothing usable. The operation is unknown, so no reply is possible.
        case invalidSyntax
        /// The operation is known but one value is malformed.
        case invalidValue(KittyClipboardOperation)
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
                // A repeated known key uses its last value.
                recognized[key] = record[record.index(after: equals)...]
            default:
                break
            }
            guard end != bytes.endIndex else { break }
            start = bytes.index(after: end)
        }

        guard let operation = recognized["type"].flatMap({
            KittyClipboardOperation(rawValue: String(decoding: $0, as: UTF8.self))
        }) else {
            return .invalidSyntax
        }

        let location: KittyClipboardLocation
        if let raw = recognized["loc"], !raw.isEmpty {
            guard String(decoding: raw, as: UTF8.self) == "primary" else {
                return .invalidValue(operation)
            }
            location = .primary
        } else {
            location = .standard
        }

        // The complete sanitized ID is echoed. The OSC packet limit bounds it.
        var idBytes: [UInt8] = []
        if let rawID = recognized["id"] {
            idBytes.reserveCapacity(rawID.count)
            for byte in rawID {
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
        }

        guard let mime = decodeText(recognized["mime"]),
              let name = decodeText(recognized["name"]),
              let password = decodeText(recognized["pw"])
        else {
            return .invalidValue(operation)
        }

        return .valid(KittyClipboardMetadata(
            operation: operation,
            location: location,
            id: String(decoding: idBytes, as: UTF8.self),
            mime: mime,
            name: name,
            password: password))
    }

    private static func decodeText(_ bytes: ArraySlice<UInt8>?) -> String? {
        guard let bytes, !bytes.isEmpty else { return "" }
        guard let data = KittyClipboardBase64Decoder.decode(bytes, maximumDecodedBytes: 4096),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }
}

// MARK: - Write transaction

private struct KittyClipboardWriteTransaction {
    let serial: UInt64
    let generation: UInt64
    let location: KittyClipboardLocation
    let id: String
    let password: String
    let name: String
    let byteLimit: Int
    let representationLimit: Int
    let aliasLimit: Int

    private var order: [String] = []
    private var decoders: [String: KittyClipboardBase64Decoder] = [:]
    private var aliasOrder: [KittyClipboardAlias] = []
    private var aliasIndex: [String: Int] = [:]
    private var startedMimes: Set<String> = []
    private var decodedBytes = 0
    private var activeMime: String?

    mutating func append(mime: String, payload: ArraySlice<UInt8>) -> KittyClipboardStatus? {
        guard KittyClipboardMime.isValid(mime) else { return .invalid }
        if activeMime != mime {
            // All packets for one MIME type must be sequential.
            if startedMimes.contains(mime) { return .invalid }
            if decoders.count >= representationLimit { return .tooLarge }
            activeMime = mime
            startedMimes.insert(mime)
            order.append(mime)
            decoders[mime] = KittyClipboardBase64Decoder()
        }
        guard var decoder = decoders[mime] else { return .invalid }
        let before = decoder.decoded.count
        let failure = decoder.append(payload, remainingLimit: byteLimit - (decodedBytes - before))
        decodedBytes += decoder.decoded.count - before
        decoders[mime] = decoder
        switch failure {
        case .none: return nil
        case .invalid: return .invalid
        case .tooLarge: return .tooLarge
        }
    }

    mutating func addAliases(target: String, payload: ArraySlice<UInt8>) -> KittyClipboardStatus? {
        guard KittyClipboardMime.isValid(target) else { return .invalid }
        guard let data = KittyClipboardBase64Decoder.decode(payload) else { return .invalid }
        var status: KittyClipboardStatus?
        scanASCIIWords(Array(data)) { word in
            let name = String(decoding: word, as: UTF8.self)
            guard KittyClipboardMime.isValid(name) else {
                status = .invalid
                return false
            }
            if let index = aliasIndex[name] {
                aliasOrder[index] = KittyClipboardAlias(name: name, target: target)
                return true
            }
            guard aliasOrder.count < aliasLimit else {
                status = .tooLarge
                return false
            }
            aliasIndex[name] = aliasOrder.count
            aliasOrder.append(KittyClipboardAlias(name: name, target: target))
            return true
        }
        return status
    }

    /// Validates every representation and returns the content to publish.
    func commit() -> KittyClipboardWriteContent? {
        var representations: [KittyClipboardRepresentation] = []
        representations.reserveCapacity(order.count)
        for mime in order {
            guard let decoder = decoders[mime], decoder.isComplete else { return nil }
            representations.append(
                KittyClipboardRepresentation(mimeType: mime, data: decoder.decoded))
        }
        // An alias whose target has no data does not create clipboard data.
        let aliases = aliasOrder.filter { alias in
            alias.name != alias.target && startedMimes.contains(alias.target)
        }
        return KittyClipboardWriteContent(representations: representations, aliases: aliases)
    }
}

// MARK: - Deferred work

private struct KittyClipboardDelegateHandle: @unchecked Sendable {
    let value: TerminalDelegate
}

private struct KittyClipboardReadWork: Sendable {
    let location: KittyClipboardLocation
    let id: String
    let password: String
    let name: String
    let requested: [String]
    let listOnly: Bool
    let generation: UInt64
    let snapshot: TerminalClipboardSnapshot?
    let preauthorized: Bool
}

private struct KittyClipboardPasteToken {
    let token: [UInt8]
    let location: KittyClipboardLocation
    let snapshot: TerminalClipboardSnapshot
    let deadline: UInt64
    let generation: UInt64
}

// MARK: - Protocol state machine

final class KittyClipboardProtocol: @unchecked Sendable {
    private weak var terminal: Terminal?
    private let completionQueue = DispatchQueue(label: "org.tirania.SwiftTerm.kitty-clipboard")

    // All of this state is owned by the terminal serialization context.
    private var grants = KittyClipboardGrants()
    private var tokens: [KittyClipboardPasteToken] = []
    private var transaction: KittyClipboardWriteTransaction?
    private var serial: UInt64 = 0
    private var sessionGeneration: UInt64 = 0
    private var lastCapabilities = KittyClipboardCapabilities()

    init(terminal: Terminal) {
        self.terminal = terminal
        lastCapabilities = Self.capabilities(of: terminal)
    }

    // MARK: Session lifecycle

    /// Clears every piece of protocol session state. RIS and destruction use it.
    func clear() {
        grants.clear()
        tokens.removeAll()
        transaction = nil
        serial &+= 1
        sessionGeneration &+= 1
    }

    func terminalDestroyed() {
        terminal = nil
        completionQueue.async { [self] in
            grants.clear()
            tokens.removeAll()
            transaction = nil
            sessionGeneration &+= 1
        }
    }

    /// Re-reads the host capability set after the host changed its services.
    ///
    /// Loss of support resets mode 5522, revokes every grant and token, and
    /// aborts an active write with `ENOSYS`.
    func refreshCapabilities() {
        guard let terminal else { return }
        let updated = Self.capabilities(of: terminal)
        guard updated != lastCapabilities else { return }
        let wasSupported = lastCapabilities.isSuperset(of: .standard)
        lastCapabilities = updated
        // A location whose read service is gone keeps no live paste token.
        tokens.removeAll { !updated.allows(direction: .read, location: $0.location) }
        guard wasSupported, !updated.isSuperset(of: .standard) else { return }

        if let current = transaction {
            transaction = nil
            serial &+= 1
            send(encodePacket(operation: .write, status: .unsupported, id: current.id))
        }
        clear()
        terminal.clearKittyPasteEvents()
    }

    private static func capabilities(of terminal: Terminal) -> KittyClipboardCapabilities {
        terminal.tdel?.kittyClipboardCapabilities(source: terminal) ?? []
    }

    /// Whether mode 5522 can be reported as supported.
    ///
    /// The complete standard-clipboard read and write service must be present
    /// in both the terminal policy and the host capability set.
    func isModeSupported() -> Bool {
        guard let terminal else { return false }
        guard terminal.options.kittyClipboardPolicy.isSuperset(of: .all) else { return false }
        return Self.capabilities(of: terminal).isSuperset(of: .standard)
    }

    private func isAvailable(
        direction: KittyClipboardPermissionDirection,
        location: KittyClipboardLocation
    ) -> Bool {
        guard let terminal else { return false }
        guard terminal.options.kittyClipboardPolicy.allows(direction: direction) else { return false }
        return Self.capabilities(of: terminal).allows(direction: direction, location: location)
    }

    // MARK: Paste

    func paste(_ request: TerminalPasteRequest, allowUnsafe: Bool) -> TerminalPasteResult {
        guard let terminal else { return .failed }

        if case .clipboard(let location) = request.source,
           terminal.kittyPasteEventsEnabled,
           isModeSupported(),
           let snapshot = request.snapshot,
           snapshot.location == location,
           sendPasteEvent(snapshot, location: location, terminal: terminal)
        {
            return .eventSent
        }

        guard let text = request.text else { return .failed }
        let encoded = TerminalPaste.encode(
            text,
            bracketed: terminal.bracketedPasteMode,
            terminalControlBytes: terminal.tdel?.terminalControlBytesForPaste(source: terminal)
                ?? TerminalPasteControls.approximateTerminalControlBytes,
            allowUnsafe: allowUnsafe)
        guard case .encoded(let bytes) = encoded else {
            return .rejected
        }
        terminal.registerUserInput(bytes[...])
        terminal.tdel?.send(source: terminal, data: bytes[...])
        return .textSent
    }

    /// Builds and submits the three event packets as one ordered byte batch.
    private func sendPasteEvent(
        _ snapshot: TerminalClipboardSnapshot,
        location: KittyClipboardLocation,
        terminal: Terminal
    ) -> Bool {
        // A missing secure random source is not a reason to skip the event: the
        // protocol makes `pw` optional and a later read uses normal permission.
        let token = terminal.kittyClipboardTokenGenerator()

        var batch = encodePacket(
            operation: .read,
            status: .ok,
            location: location,
            password: token)
        let list = snapshot.mimeTypes.isEmpty
            ? Data()
            : Data((snapshot.mimeTypes.joined(separator: " ") + "\n").utf8)
        batch.append(contentsOf: encodePacket(
            operation: .read,
            status: .data,
            mimeBase64: kittyClipboardListMimeBase64,
            payload: list))
        batch.append(contentsOf: encodePacket(operation: .read, status: .done))

        guard terminal.tdel?.kittyClipboardSendPasteEvent(source: terminal, data: batch[...]) == true
        else {
            return false
        }
        terminal.registerUserInput(batch[...])
        if let token {
            storeToken(token, location: location, snapshot: snapshot)
        }
        return true
    }

    // MARK: Paste tokens

    private func storeToken(
        _ token: String,
        location: KittyClipboardLocation,
        snapshot: TerminalClipboardSnapshot
    ) {
        guard let terminal else { return }
        let now = terminal.kittyClipboardClock()
        expireTokens(now: now)
        if tokens.count >= kittyClipboardMaximumTokens {
            tokens.removeFirst()
        }
        var lifetime = kittyClipboardTokenLifetimeNanoseconds
        if let expiresAfter = snapshot.expiresAfter, expiresAfter > 0 {
            // Clamp before the conversion. A host that says `.infinity`, or any
            // value past the 30-second cap, must not trap here.
            let capped = min(expiresAfter, Double(lifetime) / 1_000_000_000)
            if capped.isFinite {
                lifetime = min(lifetime, UInt64(capped * 1_000_000_000))
            }
        }
        tokens.append(KittyClipboardPasteToken(
            token: Array(token.utf8),
            location: location,
            snapshot: snapshot,
            deadline: now &+ lifetime,
            generation: sessionGeneration))
    }

    private func expireTokens(now: UInt64) {
        tokens.removeAll { $0.deadline <= now || $0.generation != sessionGeneration }
    }

    /// Consumes a paste token atomically. Only a read at the token's own
    /// location, with a nonempty decoded name, uses one.
    private func consumeToken(
        password: String,
        name: String,
        direction: KittyClipboardPermissionDirection,
        location: KittyClipboardLocation
    ) -> TerminalClipboardSnapshot? {
        guard let terminal, direction == .read, !password.isEmpty, !name.isEmpty else { return nil }
        expireTokens(now: terminal.kittyClipboardClock())
        let candidate = Array(password.utf8)
        var match = -1
        // Scan every entry so that the table order does not leak through timing.
        for (index, entry) in tokens.enumerated() {
            let equal = constantTimeEquals(entry.token, candidate)
            if equal && entry.location == location && match < 0 {
                match = index
            }
        }
        guard match >= 0 else { return nil }
        return tokens.remove(at: match).snapshot
    }

    private func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        var difference = UInt8(lhs.count == rhs.count ? 0 : 1)
        let count = min(lhs.count, rhs.count)
        for index in 0..<count {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0 && lhs.count == rhs.count
    }

    // MARK: Packet dispatch

    func handle(_ data: ArraySlice<UInt8>) {
        let metadataBytes: ArraySlice<UInt8>
        let payload: ArraySlice<UInt8>
        let hasPayload: Bool
        if let separator = data.firstIndex(of: UInt8(ascii: ";")) {
            metadataBytes = data[..<separator]
            payload = data[data.index(after: separator)...]
            hasPayload = true
        } else {
            metadataBytes = data
            payload = []
            hasPayload = false
        }

        switch KittyClipboardMetadata.parse(metadataBytes) {
        case .invalidSyntax:
            return
        case .invalidValue(let operation):
            switch operation {
            case .read:
                // An invalid read packet gets no response.
                return
            case .write:
                // A `write` replaces an active transaction even when its own
                // metadata is invalid, so the old staged data never commits.
                transaction = nil
                serial &+= 1
                sendStatus(operation: .write, status: .invalid, id: "")
            case .wdata, .walias:
                abortWrite(status: .invalid)
            }
        case .valid(let metadata):
            switch metadata.operation {
            case .read:
                handleRead(metadata, payload: payload, hasPayload: hasPayload)
            case .write:
                beginWrite(metadata, hasPayload: hasPayload)
            case .wdata:
                handleWriteData(metadata, payload: payload, hasPayload: hasPayload)
            case .walias:
                handleWriteAlias(metadata, payload: payload, hasPayload: hasPayload)
            }
        }
    }

    // MARK: Read

    private func handleRead(
        _ metadata: KittyClipboardMetadata,
        payload: ArraySlice<UInt8>,
        hasPayload: Bool
    ) {
        // A read needs one payload separator and a nonempty, valid base64 list.
        guard hasPayload, !payload.isEmpty,
              let decoded = KittyClipboardBase64Decoder.decode(payload)
        else {
            return
        }

        var listOnly = false
        var requested: [String] = []
        var seen: Set<String> = []
        var invalid = false
        scanASCIIWords(Array(decoded)) { word in
            let name = String(decoding: word, as: UTF8.self)
            if name == "." {
                // `.` cannot be combined with a content request.
                if !requested.isEmpty { invalid = true; return false }
                listOnly = true
                return true
            }
            if listOnly { invalid = true; return false }
            guard KittyClipboardMime.isValid(name) else { invalid = true; return false }
            let key = KittyClipboardMime.matchKey(name)
            if seen.insert(key).inserted {
                requested.append(name)
            }
            return true
        }
        guard !invalid, listOnly || !requested.isEmpty else { return }

        guard let terminal, let delegate = terminal.tdel else { return }
        guard isAvailable(direction: .read, location: metadata.location) else {
            sendStatus(operation: .read, status: .unsupported, id: metadata.id)
            return
        }

        // A paste token authorizes exactly one content read of its snapshot.
        let snapshot = listOnly
            ? nil
            : consumeToken(
                password: metadata.password,
                name: metadata.name,
                direction: .read,
                location: metadata.location)
        let granted = snapshot != nil
            || (!metadata.password.isEmpty && !metadata.name.isEmpty
                && grants.check(
                    password: metadata.password,
                    direction: .read,
                    location: metadata.location))

        let work = KittyClipboardReadWork(
            location: metadata.location,
            id: metadata.id,
            password: metadata.password,
            name: metadata.name,
            requested: requested,
            listOnly: listOnly,
            generation: sessionGeneration,
            snapshot: snapshot,
            preauthorized: granted)
        let handle = KittyClipboardDelegateHandle(value: delegate)
        completionQueue.async { [self] in
            enumerateForRead(work, delegate: handle)
        }
    }

    /// Step 1: learn the available MIME names. This never prompts.
    private func enumerateForRead(
        _ work: KittyClipboardReadWork,
        delegate: KittyClipboardDelegateHandle
    ) {
        guard isCurrent(work.generation), let terminal else { return }
        if let snapshot = work.snapshot {
            selectForRead(work, delegate: delegate, available: snapshot.mimeTypes)
            return
        }
        let accepted = delegate.value.kittyClipboardAvailableMimeTypes(
            source: terminal,
            location: work.location
        ) { [self] mimeTypes in
            completionQueue.async { [self] in
                guard let mimeTypes else {
                    finishRead(work, status: .unsupported)
                    return
                }
                selectForRead(work, delegate: delegate, available: mimeTypes)
            }
        }
        if !accepted {
            finishRead(work, status: .unsupported)
        }
    }

    /// Step 2: answer a type-list request, or match the request against the
    /// available names and ask for permission.
    private func selectForRead(
        _ work: KittyClipboardReadWork,
        delegate: KittyClipboardDelegateHandle,
        available: [String]
    ) {
        guard isCurrent(work.generation), let terminal else { return }
        if work.listOnly {
            let list = available.isEmpty
                ? Data()
                : Data((available.joined(separator: " ") + "\n").utf8)
            terminal.terminalLock.withLock {
                guard work.generation == sessionGeneration else { return }
                var response = encodePacket(operation: .read, status: .ok, id: work.id)
                response.append(contentsOf: encodePacket(
                    operation: .read,
                    status: .data,
                    id: work.id,
                    mimeBase64: kittyClipboardListMimeBase64,
                    payload: list))
                response.append(contentsOf: encodePacket(
                    operation: .read, status: .done, id: work.id))
                terminal.sendResponse(response)
            }
            return
        }

        // MIME names match without case differences; the available list holds
        // the canonical spelling.
        var canonical: [String: String] = [:]
        for name in available {
            let key = KittyClipboardMime.matchKey(name)
            if canonical[key] == nil { canonical[key] = name }
        }
        let selected = work.requested.compactMap { canonical[KittyClipboardMime.matchKey($0)] }
        guard !selected.isEmpty else {
            finishRead(work, status: .unsupported)
            return
        }

        if work.preauthorized {
            readRepresentation(at: 0, work: work, delegate: delegate, selected: selected, results: [])
            return
        }
        let request = KittyClipboardPermissionRequest(
            direction: .read,
            location: work.location,
            name: work.name,
            mimeTypes: selected,
            canRememberPassword: !work.password.isEmpty && !work.name.isEmpty)
        let accepted = delegate.value.kittyClipboardRequestPermission(
            source: terminal,
            request: request
        ) { [self] result in
            completionQueue.async { [self] in
                switch result {
                case .deny:
                    finishRead(work, status: .permission)
                case .allow(let remember):
                    guard let terminal = self.terminal else { return }
                    let current = terminal.terminalLock.withLock { () -> Bool in
                        guard work.generation == sessionGeneration else { return false }
                        if remember, !work.password.isEmpty, !work.name.isEmpty {
                            grants.add(
                                password: work.password,
                                direction: .read,
                                location: work.location)
                        }
                        return true
                    }
                    guard current else { return }
                    readRepresentation(
                        at: 0, work: work, delegate: delegate, selected: selected, results: [])
                }
            }
        }
        if !accepted {
            finishRead(work, status: .permission)
        }
    }

    /// Step 3: obtain every selected representation before the `OK` packet.
    private func readRepresentation(
        at index: Int,
        work: KittyClipboardReadWork,
        delegate: KittyClipboardDelegateHandle,
        selected: [String],
        results: [KittyClipboardRepresentation]
    ) {
        guard isCurrent(work.generation), let terminal else { return }
        if index == selected.count {
            guard !results.isEmpty else {
                finishRead(work, status: .unsupported)
                return
            }
            terminal.terminalLock.withLock {
                guard work.generation == sessionGeneration else { return }
                terminal.sendResponse(encodeReadSuccess(id: work.id, representations: results))
            }
            return
        }
        let mime = selected[index]
        let completion: @Sendable (KittyClipboardReadResult) -> Void = { [self] result in
            completionQueue.async { [self] in
                switch result {
                case .denied:
                    finishRead(work, status: .permission)
                case .busy:
                    finishRead(work, status: .busy)
                case .unavailable:
                    // An unavailable type is skipped when another one answers.
                    readRepresentation(
                        at: index + 1, work: work, delegate: delegate,
                        selected: selected, results: results)
                case .data(let data):
                    // Empty but available data is a valid representation.
                    readRepresentation(
                        at: index + 1, work: work, delegate: delegate, selected: selected,
                        results: results + [
                            KittyClipboardRepresentation(mimeType: mime, data: data)
                        ])
                }
            }
        }
        let accepted: Bool
        if let snapshot = work.snapshot {
            accepted = snapshot.read(mime, completion)
        } else {
            accepted = delegate.value.kittyClipboardRead(
                source: terminal,
                location: work.location,
                mimeType: mime,
                completion: completion)
        }
        if !accepted {
            finishRead(work, status: .unsupported)
        }
    }

    private func finishRead(_ work: KittyClipboardReadWork, status: KittyClipboardStatus) {
        guard let terminal else { return }
        terminal.terminalLock.withLock {
            guard work.generation == sessionGeneration else { return }
            sendStatus(operation: .read, status: status, id: work.id)
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        guard let terminal else { return false }
        return terminal.terminalLock.withLock { generation == sessionGeneration }
    }

    private func isCurrentWrite(_ current: KittyClipboardWriteTransaction) -> Bool {
        guard let terminal else { return false }
        return terminal.terminalLock.withLock {
            current.serial == serial && current.generation == sessionGeneration
        }
    }

    // MARK: Write

    private func beginWrite(_ metadata: KittyClipboardMetadata, hasPayload: Bool) {
        serial &+= 1
        transaction = nil
        guard let terminal else { return }
        // An initial `write` carries no payload and no `mime`.
        guard !hasPayload, metadata.mime.isEmpty else {
            sendStatus(operation: .write, status: .invalid, id: metadata.id)
            return
        }
        guard isAvailable(direction: .write, location: metadata.location) else {
            sendStatus(operation: .write, status: .unsupported, id: metadata.id)
            return
        }
        transaction = KittyClipboardWriteTransaction(
            serial: serial,
            generation: sessionGeneration,
            location: metadata.location,
            id: metadata.id,
            password: metadata.password,
            name: metadata.name,
            byteLimit: terminal.options.kittyClipboardWriteLimitBytes,
            representationLimit: terminal.options.kittyClipboardMaximumRepresentations,
            aliasLimit: terminal.options.kittyClipboardMaximumAliases)
    }

    private func handleWriteData(
        _ metadata: KittyClipboardMetadata,
        payload: ArraySlice<UInt8>,
        hasPayload: Bool
    ) {
        guard var current = transaction else { return }
        transaction = nil
        if metadata.mime.isEmpty {
            // The commit packet has no `mime` and no payload separator.
            guard !hasPayload else {
                abortWrite(current, status: .invalid)
                return
            }
            guard let content = current.commit() else {
                abortWrite(current, status: .invalid)
                return
            }
            commitWrite(current, content: content)
            return
        }
        guard hasPayload else {
            abortWrite(current, status: .invalid)
            return
        }
        if let status = current.append(mime: metadata.mime, payload: payload) {
            abortWrite(current, status: status)
            return
        }
        transaction = current
    }

    private func handleWriteAlias(
        _ metadata: KittyClipboardMetadata,
        payload: ArraySlice<UInt8>,
        hasPayload: Bool
    ) {
        guard var current = transaction else { return }
        transaction = nil
        guard hasPayload, !metadata.mime.isEmpty else {
            abortWrite(current, status: .invalid)
            return
        }
        if let status = current.addAliases(target: metadata.mime, payload: payload) {
            abortWrite(current, status: status)
            return
        }
        transaction = current
    }

    private func commitWrite(
        _ current: KittyClipboardWriteTransaction,
        content: KittyClipboardWriteContent
    ) {
        let granted = !current.password.isEmpty && !current.name.isEmpty
            && grants.check(
                password: current.password,
                direction: .write,
                location: current.location)
        guard let terminal, let delegate = terminal.tdel else {
            sendStatus(operation: .write, status: .unsupported, id: current.id)
            return
        }
        let handle = KittyClipboardDelegateHandle(value: delegate)
        completionQueue.async { [self] in
            guard let terminal = self.terminal else { return }
            if granted {
                performHostWrite(current, content: content, delegate: handle)
                return
            }
            let request = KittyClipboardPermissionRequest(
                direction: .write,
                location: current.location,
                name: current.name,
                mimeTypes: content.representations.map(\.mimeType) + content.aliases.map(\.name),
                canRememberPassword: !current.password.isEmpty && !current.name.isEmpty)
            let accepted = handle.value.kittyClipboardRequestPermission(
                source: terminal,
                request: request
            ) { [self] result in
                completionQueue.async { [self] in
                    switch result {
                    case .deny:
                        finishWrite(current, result: .denied)
                    case .allow(let remember):
                        guard let terminal = self.terminal else { return }
                        let isCurrent = terminal.terminalLock.withLock { () -> Bool in
                            guard current.serial == serial,
                                  current.generation == sessionGeneration
                            else { return false }
                            if remember, !current.password.isEmpty, !current.name.isEmpty {
                                grants.add(
                                    password: current.password,
                                    direction: .write,
                                    location: current.location)
                            }
                            return true
                        }
                        guard isCurrent else { return }
                        performHostWrite(current, content: content, delegate: handle)
                    }
                }
            }
            if !accepted {
                finishWrite(current, result: .denied)
            }
        }
    }

    private func performHostWrite(
        _ current: KittyClipboardWriteTransaction,
        content: KittyClipboardWriteContent,
        delegate: KittyClipboardDelegateHandle
    ) {
        guard let terminal, isCurrentWrite(current) else { return }
        let accepted = delegate.value.kittyClipboardWrite(
            source: terminal,
            location: current.location,
            content: content
        ) { [self] result in
            completionQueue.async { [self] in
                finishWrite(current, result: result)
            }
        }
        if !accepted {
            finishWrite(current, result: .unsupported)
        }
    }

    private func finishWrite(
        _ current: KittyClipboardWriteTransaction,
        result: KittyClipboardWriteResult
    ) {
        guard let terminal else { return }
        terminal.terminalLock.withLock {
            guard current.serial == serial, current.generation == sessionGeneration else { return }
            serial &+= 1
            let status: KittyClipboardStatus
            switch result {
            case .success: status = .done
            case .denied: status = .permission
            case .unsupported: status = .unsupported
            case .busy: status = .busy
            case .invalidData: status = .invalid
            case .ioError: status = .io
            case .tooLarge: status = .tooLarge
            }
            sendStatus(operation: .write, status: status, id: current.id)
        }
    }

    private func abortWrite(status: KittyClipboardStatus) {
        guard let current = transaction else { return }
        transaction = nil
        abortWrite(current, status: status)
    }

    private func abortWrite(
        _ current: KittyClipboardWriteTransaction,
        status: KittyClipboardStatus
    ) {
        serial &+= 1
        sendStatus(operation: .write, status: status, id: current.id)
    }

    // MARK: Encoding

    private func sendStatus(
        operation: KittyClipboardOperation,
        status: KittyClipboardStatus,
        id: String
    ) {
        send(encodePacket(operation: operation, status: status, id: id))
    }

    private func send(_ bytes: [UInt8]) {
        guard let terminal, !bytes.isEmpty else { return }
        terminal.sendResponse(bytes)
    }

    private func encodeReadSuccess(
        id: String,
        representations: [KittyClipboardRepresentation]
    ) -> [UInt8] {
        var result = encodePacket(operation: .read, status: .ok, id: id)
        for representation in representations {
            let mime = KittyClipboardBase64Decoder.encode(Array(representation.mimeType.utf8))
            var offset = 0
            repeat {
                let end = min(offset + kittyClipboardChunkBytes, representation.data.count)
                result.append(contentsOf: encodePacket(
                    operation: .read,
                    status: .data,
                    id: id,
                    mimeBase64: mime,
                    payload: representation.data[
                        representation.data.startIndex + offset
                            ..< representation.data.startIndex + end]))
                offset = end
            } while offset < representation.data.count
        }
        result.append(contentsOf: encodePacket(operation: .read, status: .done, id: id))
        return result
    }

    /// Builds one canonical 7-bit OSC 5522 packet.
    ///
    /// A non-nil `payload` always writes the `;` separator, so empty data is
    /// distinguishable from no data.
    private func encodePacket(
        operation: KittyClipboardOperation,
        status: KittyClipboardStatus,
        location: KittyClipboardLocation? = nil,
        id: String = "",
        mimeBase64: String? = nil,
        password: String? = nil,
        payload: Data? = nil
    ) -> [UInt8] {
        var metadata = "5522;type=\(operation.rawValue):status=\(status.rawValue)"
        if location == .primary {
            metadata += ":loc=primary"
        }
        if !id.isEmpty {
            metadata += ":id=\(id)"
        }
        if let mimeBase64 {
            metadata += ":mime=\(mimeBase64)"
        }
        if let password, !password.isEmpty {
            metadata += ":pw=\(KittyClipboardBase64Decoder.encode(Array(password.utf8)))"
        }
        if let payload {
            metadata += ";\(payload.base64EncodedString())"
        }
        return kittyClipboardOSCIntroducer + Array(metadata.utf8) + kittyClipboardOSCTerminatorBytes
    }
}

// MARK: - Token generation

enum KittyClipboardTokenGenerator {
    /// A 57-symbol alphabet without visually ambiguous characters. Twenty-two
    /// symbols carry about 128.3 bits, which meets the 128-bit requirement.
    static let alphabet = Array("23456789abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ".utf8)
    static let length = 22

    /// Returns a fresh token, or `nil` when no secure entropy is available.
    static func generate() -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(length)
#if canImport(Security)
        // Rejection sampling keeps the symbols uniform.
        let acceptedRange = UInt8.max - (UInt8.max % UInt8(alphabet.count))
        while bytes.count < length {
            var random: UInt8 = 0
            guard SecRandomCopyBytes(kSecRandomDefault, 1, &random) == errSecSuccess else {
                return nil
            }
            guard random < acceptedRange else { continue }
            bytes.append(alphabet[Int(random) % alphabet.count])
        }
#else
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<length {
            bytes.append(alphabet[Int.random(in: 0..<alphabet.count, using: &generator)])
        }
#endif
        return String(decoding: bytes, as: UTF8.self)
    }
}
