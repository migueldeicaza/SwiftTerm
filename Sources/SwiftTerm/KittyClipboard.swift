import Foundation

/// A clipboard location used by the Kitty clipboard protocol.
public enum KittyClipboardLocation: Sendable, Equatable {
    case clipboard
    case primary
}

/// One binary clipboard representation and its type name.
public struct KittyClipboardRepresentation: Sendable, Equatable {
    public var type: String
    public var data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// The authorization state for a host clipboard request.
public enum KittyClipboardAuthorization: Sendable, Equatable {
    case notRequired
    case required
    case granted
}

/// A typed request to read a clipboard location.
public struct KittyClipboardReadRequest: Sendable, Equatable {
    public var location: KittyClipboardLocation
    public var types: [String]
    public var requestsTypeList: Bool
    public var applicationName: String?
    public var authorization: KittyClipboardAuthorization
    public var canRemember: Bool

    public init(
        location: KittyClipboardLocation,
        types: [String],
        requestsTypeList: Bool,
        applicationName: String?,
        authorization: KittyClipboardAuthorization,
        canRemember: Bool
    ) {
        self.location = location
        self.types = types
        self.requestsTypeList = requestsTypeList
        self.applicationName = applicationName
        self.authorization = authorization
        self.canRemember = canRemember
    }
}

/// A successful host clipboard read.
public struct KittyClipboardReadSuccess: Sendable, Equatable {
    public var representations: [KittyClipboardRepresentation]
    public var availableTypes: [String]
    public var remember: Bool

    public init(
        representations: [KittyClipboardRepresentation],
        availableTypes: [String],
        remember: Bool
    ) {
        self.representations = representations
        self.availableTypes = availableTypes
        self.remember = remember
    }
}

/// The result of a host clipboard read.
public enum KittyClipboardReadResult: Sendable, Equatable {
    case success(KittyClipboardReadSuccess)
    case denied
    case unsupported
    case busy
    case ioError
}

/// A typed request to replace a clipboard location.
public struct KittyClipboardWriteRequest: Sendable, Equatable {
    public var location: KittyClipboardLocation
    public var representations: [KittyClipboardRepresentation]
    public var applicationName: String?
    public var authorization: KittyClipboardAuthorization
    public var canRemember: Bool

    public init(
        location: KittyClipboardLocation,
        representations: [KittyClipboardRepresentation],
        applicationName: String?,
        authorization: KittyClipboardAuthorization,
        canRemember: Bool
    ) {
        self.location = location
        self.representations = representations
        self.applicationName = applicationName
        self.authorization = authorization
        self.canRemember = canRemember
    }
}

/// A successful host clipboard write.
public struct KittyClipboardWriteSuccess: Sendable, Equatable {
    public var remember: Bool

    public init(remember: Bool) {
        self.remember = remember
    }
}

/// The result of a host clipboard write.
public enum KittyClipboardWriteResult: Sendable, Equatable {
    case success(KittyClipboardWriteSuccess)
    case denied
    case unsupported
    case busy
    case invalidData
    case ioError
}

/// Configuration for OSC 5522 clipboard requests.
public struct KittyClipboardConfiguration: Sendable, Equatable {
    /// The minimum decoded write size that an enabled implementation accepts.
    public static let minimumWriteLimitBytes = 64 * 1024 * 1024

    /// Enables OSC 5522 request handling.
    public var enabled: Bool {
        didSet { normalizeWriteLimit() }
    }

    /// The maximum decoded bytes in one write, or `nil` for no local limit.
    public var writeLimitBytes: Int? {
        didSet { normalizeWriteLimit() }
    }

    public init(
        enabled: Bool = true,
        writeLimitBytes: Int? = KittyClipboardConfiguration.minimumWriteLimitBytes
    ) {
        self.enabled = enabled
        self.writeLimitBytes = writeLimitBytes
        normalizeWriteLimit()
    }

    private mutating func normalizeWriteLimit() {
        guard enabled, let writeLimitBytes,
              writeLimitBytes < Self.minimumWriteLimitBytes
        else {
            return
        }
        self.writeLimitBytes = Self.minimumWriteLimitBytes
    }
}

/// The source of a user-initiated paste.
public enum TerminalPasteSource: Sendable, Equatable {
    case clipboard(KittyClipboardLocation)
    case text
}

/// Clipboard metadata and deferred data access for a user-initiated paste.
public struct TerminalPasteRequest: Sendable {
    public typealias Reader = @Sendable (
        _ request: KittyClipboardReadRequest,
        _ completion: @escaping @Sendable (KittyClipboardReadResult) -> Void
    ) -> Void

    public let source: TerminalPasteSource
    public let types: [String]
    public let text: String?
    public let read: Reader?

    public init(
        source: TerminalPasteSource,
        types: [String] = [],
        text: String? = nil,
        read: Reader? = nil
    ) {
        self.source = source
        self.types = types
        self.text = text
        self.read = read
    }
}

/// The result of routing a user-initiated paste.
public enum TerminalPasteResult: Sendable, Equatable {
    case kittyEvent(password: String)
    case text
    case requiresText
    case unsafePayload
    case entropyUnavailable
    case unsupported

    var needsTextFallback: Bool {
        switch self {
        case .requiresText, .entropyUnavailable, .unsupported:
            return true
        case .kittyEvent, .text, .unsafePayload:
            return false
        }
    }
}
