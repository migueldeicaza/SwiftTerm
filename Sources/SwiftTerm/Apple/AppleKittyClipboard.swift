//
// AppleKittyClipboard.swift
//
// Shared Apple support for the Kitty clipboard protocol, OSC 5522.
//
// MIME conversion, duplicate removal, and snapshot policy live here so that
// the macOS and iOS views keep only their native pasteboard operations.
//
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import UniformTypeIdentifiers

/// Converts between platform pasteboard identifiers and MIME names.
enum AppleKittyClipboardMime {
    /// The MIME name for one platform type identifier.
    ///
    /// A native identifier is kept only when its own raw value is already a
    /// valid MIME name, so identifiers with no MIME mapping are never
    /// advertised.
    static func mimeName(for identifier: String) -> String? {
        if let mime = UTType(identifier)?.preferredMIMEType, KittyClipboardMime.isValid(mime) {
            return mime
        }
        return KittyClipboardMime.isValid(identifier) ? identifier : nil
    }

    /// Ordered MIME names for a platform type list, with duplicates removed.
    static func mimeNames(for identifiers: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        result.reserveCapacity(identifiers.count)
        for identifier in identifiers {
            guard let name = mimeName(for: identifier),
                  seen.insert(KittyClipboardMime.matchKey(name)).inserted
            else {
                continue
            }
            result.append(name)
        }
        return result
    }

    /// The platform identifier in `identifiers` that serves `mimeType`.
    static func identifier(for mimeType: String, among identifiers: [String]) -> String? {
        let key = KittyClipboardMime.matchKey(mimeType)
        return identifiers.first {
            guard let name = mimeName(for: $0) else { return false }
            return KittyClipboardMime.matchKey(name) == key
        }
    }

    /// The platform identifier to publish `mimeType` under.
    static func writeIdentifier(for mimeType: String) -> String? {
        if let type = UTType(mimeType: mimeType) {
            return type.identifier
        }
        return KittyClipboardMime.isValid(mimeType) ? mimeType : nil
    }
}

extension TerminalView {
    /// Captures the clipboard state for one user paste action.
    ///
    /// The MIME list is enumerated once. A representation is read only after
    /// the terminal application asks for it, and only while the platform
    /// change counter still matches.
    @MainActor
    func kittyClipboardSnapshot(location: KittyClipboardLocation) -> TerminalClipboardSnapshot? {
        guard let identifiers = kittyPlatformTypeIdentifiers(location: location) else {
            return nil
        }
        let identity = kittyPlatformChangeCount(location: location)
        return TerminalClipboardSnapshot(
            location: location,
            mimeTypes: AppleKittyClipboardMime.mimeNames(for: identifiers),
            identity: identity
        ) { [weak self] mimeType, completion in
            guard let self else { return false }
            self.onMain {
                guard self.kittyPlatformChangeCount(location: location) == identity else {
                    // The clipboard was replaced, so the snapshot is stale.
                    completion(.unavailable)
                    return
                }
                completion(self.kittyPlatformRead(location: location, mimeType: mimeType))
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
}
#endif
