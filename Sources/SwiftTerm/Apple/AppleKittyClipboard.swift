//
// AppleKittyClipboard.swift
//
// Shared Apple support for the Kitty clipboard protocol, OSC 5522.
//
// MIME conversion, duplicate removal, snapshot policy, and the paste
// orchestration live here. The macOS and iOS views keep only four native
// pasteboard primitives: type enumeration, the change counter, one data read,
// and one atomic publish.
//
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import UniformTypeIdentifiers

/// Converts between platform pasteboard identifiers and MIME names.
enum AppleKittyClipboardMime {
    /// The type that `NSPasteboard.string(forType:)` and `UIPasteboard.string`
    /// read and write. Its preferred MIME type carries a `charset` parameter,
    /// so it is mapped by hand in both directions.
    static let utf8PlainTextIdentifier = "public.utf8-plain-text"
    static let plainTextMime = "text/plain"

    /// The MIME name for one platform type identifier.
    ///
    /// MIME parameters are removed before validation. A native identifier is
    /// kept only when its own raw value is already a valid MIME name, so
    /// identifiers with no MIME mapping are never advertised.
    static func mimeName(for identifier: String) -> String? {
        if identifier == utf8PlainTextIdentifier {
            return plainTextMime
        }
        if let preferred = UTType(identifier)?.preferredMIMEType {
            let mime = withoutParameters(preferred)
            if KittyClipboardMime.isValid(mime) {
                return mime
            }
        }
        return KittyClipboardMime.isValid(identifier) ? identifier : nil
    }

    /// Ordered MIME names for a platform type list, with duplicates removed.
    static func mimeNames(for identifiers: [String]) -> [String] {
        AppleKittyClipboardCatalog(identifiers: identifiers).mimeTypes
    }

    /// The platform identifier to publish `mimeType` under.
    ///
    /// `text/plain` goes to the UTF-8 plain-text type, so that the system
    /// string accessors and other applications can read it.
    static func writeIdentifier(for mimeType: String) -> String? {
        if KittyClipboardMime.matchKey(mimeType) == plainTextMime {
            return utf8PlainTextIdentifier
        }
        if let type = UTType(mimeType: mimeType) {
            return type.identifier
        }
        return KittyClipboardMime.isValid(mimeType) ? mimeType : nil
    }

    /// `text/plain;charset=utf-8` becomes `text/plain`.
    private static func withoutParameters(_ mime: String) -> String {
        guard let semicolon = mime.firstIndex(of: ";") else { return mime }
        return mime[..<semicolon].trimmingCharacters(in: .whitespaces)
    }
}

/// The MIME names at one clipboard location, and the platform identifier that
/// serves each of them.
///
/// Building it resolves every identifier once. A later read looks its
/// identifier up instead of resolving the whole type list again.
struct AppleKittyClipboardCatalog: Sendable {
    /// Every MIME name, in platform order, with duplicates removed.
    let mimeTypes: [String]
    private let identifiersByKey: [String: String]

    init(identifiers: [String]) {
        var mimeTypes: [String] = []
        var identifiersByKey: [String: String] = [:]
        mimeTypes.reserveCapacity(identifiers.count)
        for identifier in identifiers {
            guard let name = AppleKittyClipboardMime.mimeName(for: identifier) else { continue }
            let key = KittyClipboardMime.matchKey(name)
            guard identifiersByKey[key] == nil else { continue }
            identifiersByKey[key] = identifier
            mimeTypes.append(name)
        }
        self.mimeTypes = mimeTypes
        self.identifiersByKey = identifiersByKey
    }

    /// The platform identifier that serves `mimeType`, without case differences.
    func identifier(for mimeType: String) -> String? {
        identifiersByKey[KittyClipboardMime.matchKey(mimeType)]
    }
}

extension TerminalView {

    // MARK: Paste orchestration

    /// Whether the next user paste at `location` sends a mode 5522 event.
    @MainActor
    func kittyPasteEventPossible(location: KittyClipboardLocation) -> Bool {
        withTerminal { $0.kittyPasteEventPossible(location: location) }
    }

    /// Runs the mode 5522 half of one user paste action.
    ///
    /// Returns `true` when the event was sent. `false` means no event was
    /// possible or the output sink refused it, and the caller must run its
    /// own text-paste path.
    @MainActor
    func sendKittyPasteEvent(location: KittyClipboardLocation) -> Bool {
        refreshKittyClipboardCapabilities()
        guard kittyPasteEventPossible(location: location),
              let snapshot = kittyClipboardSnapshot(location: location)
        else {
            return false
        }
        let result = withTerminal { $0.paste(TerminalPasteRequest(snapshot: snapshot)) }
        return !result.needsTextFallback
    }

    /// Sends `text` as a text paste. A paste that the safety policy rejected
    /// is sent again with the policy relaxed.
    @MainActor
    func pasteText(_ text: String) {
        let request = TerminalPasteRequest(text: text)
        var result = withTerminal { $0.paste(request) }
        if result == .rejected {
            result = withTerminal { $0.paste(request, allowUnsafe: true) }
        }
        _ = result
    }

    // MARK: Snapshots

    /// Captures the clipboard state for one user paste action.
    ///
    /// The MIME list is enumerated once. A representation is read only after
    /// the terminal application asks for it. A host that serves its own
    /// clipboard through ``TerminalViewDelegate`` is the source here too, so
    /// the paste event and a later OSC 5522 read describe the same clipboard.
    /// The platform pasteboard is read only while its change counter still
    /// matches.
    @MainActor
    func kittyClipboardSnapshot(location: KittyClipboardLocation) -> TerminalClipboardSnapshot? {
        if let custom = terminalDelegate?.kittyClipboardAvailableMimeTypes(
            source: self, location: location)
        {
            return TerminalClipboardSnapshot(
                location: location,
                mimeTypes: custom
            ) { [weak self] mimeType, completion in
                guard let self else { return false }
                self.onMain {
                    let result = self.terminalDelegate?.kittyClipboardRead(
                        source: self, location: location, mimeType: mimeType)
                    completion(result ?? self.kittyPlatformRead(
                        location: location, mimeType: mimeType))
                }
                return true
            }
        }

        guard let identifiers = kittyPlatformTypeIdentifiers(location: location) else {
            return nil
        }
        let catalog = AppleKittyClipboardCatalog(identifiers: identifiers)
        let identity = kittyPlatformChangeCount(location: location)
        return TerminalClipboardSnapshot(
            location: location,
            mimeTypes: catalog.mimeTypes,
            identity: identity
        ) { [weak self] mimeType, completion in
            guard let self else { return false }
            self.onMain {
                // A replaced clipboard makes the snapshot stale.
                guard self.kittyPlatformChangeCount(location: location) == identity,
                      let identifier = catalog.identifier(for: mimeType),
                      let data = self.kittyPlatformData(location: location, identifier: identifier)
                else {
                    completion(.unavailable)
                    return
                }
                completion(.data(data))
            }
            return true
        }
    }

    /// The MIME names currently at one clipboard location.
    @MainActor
    func kittyClipboardPlatformAvailableMimeTypes(
        location: KittyClipboardLocation
    ) -> [String]? {
        guard let identifiers = kittyPlatformTypeIdentifiers(location: location) else {
            return nil
        }
        return AppleKittyClipboardMime.mimeNames(for: identifiers)
    }

    // MARK: Platform pasteboard

    /// Reads one MIME representation from the platform pasteboard.
    @MainActor
    func kittyPlatformRead(
        location: KittyClipboardLocation,
        mimeType: String
    ) -> KittyClipboardReadResult {
        guard let identifiers = kittyPlatformTypeIdentifiers(location: location),
              let identifier = AppleKittyClipboardCatalog(identifiers: identifiers)
                  .identifier(for: mimeType),
              let data = kittyPlatformData(location: location, identifier: identifier)
        else {
            return .unavailable
        }
        return .data(data)
    }

    /// Publishes every representation and alias as one pasteboard item.
    ///
    /// `flattened` resolves every alias into its own entry: one pasteboard
    /// item holds one payload per type, so an alias and its target become two
    /// entries that share the same `Data` buffer. Two MIME names that map to
    /// one platform identifier collapse to the last one; the pasteboard cannot
    /// hold both, and the write stays all-or-nothing.
    @MainActor
    func kittyPlatformWrite(
        location: KittyClipboardLocation,
        content: KittyClipboardWriteContent
    ) -> KittyClipboardWriteResult {
        var items: [(identifier: String, data: Data)] = []
        for representation in content.flattened {
            guard let identifier = AppleKittyClipboardMime.writeIdentifier(
                for: representation.mimeType)
            else {
                return .invalidData
            }
            items.append((identifier, representation.data))
        }
        return kittyPlatformPublish(location: location, items: items)
    }
}
#endif
