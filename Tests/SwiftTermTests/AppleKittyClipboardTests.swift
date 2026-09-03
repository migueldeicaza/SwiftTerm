#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import SwiftTerm

/// Section 16.7: the Apple pasteboard-to-MIME mapping.
@Suite struct AppleKittyClipboardMimeTests {

    @Test func commonTypesRoundTripBetweenMIMEAndPlatformIdentifiers() {
        let mimeTypes = [
            "text/plain",
            "text/html",
            "image/png",
            "image/tiff",
            "application/pdf",
            "text/uri-list",
        ]
        for mimeType in mimeTypes {
            guard let identifier = AppleKittyClipboardMime.writeIdentifier(for: mimeType) else {
                Issue.record("\(mimeType) produced no platform identifier")
                continue
            }
            // A type the OS does not know keeps its own MIME name, which is
            // still a valid round trip.
            guard UTType(identifier)?.preferredMIMEType != nil else {
                #expect(identifier == mimeType)
                continue
            }
            #expect(AppleKittyClipboardMime.mimeName(for: identifier) == mimeType)
        }
    }

    @Test func plainTextUsesTheUTF8PlainTextPasteboardType() {
        // `public.utf8-plain-text` is what the system string accessors use.
        // Its preferred MIME type carries `;charset=utf-8`, which is not a
        // valid bare MIME name, so both directions are mapped by hand.
        #expect(AppleKittyClipboardMime.mimeName(for: "public.utf8-plain-text") == "text/plain")
        #expect(AppleKittyClipboardMime.writeIdentifier(for: "text/plain") == "public.utf8-plain-text")
        #expect(AppleKittyClipboardMime.writeIdentifier(for: "TEXT/Plain") == "public.utf8-plain-text")

        // The list a `setString` clipboard publishes advertises `text/plain`.
        let names = AppleKittyClipboardMime.mimeNames(for: ["public.utf8-plain-text", "NSStringPboardType"])
        #expect(names == ["text/plain"])
    }

    @Test func mimeParametersAreRemovedBeforeValidation() {
        // Any identifier whose preferred MIME type carries parameters must
        // still advertise the bare media name.
        for identifier in ["public.utf8-plain-text", "public.plain-text", "public.html"] {
            guard let preferred = UTType(identifier)?.preferredMIMEType else { continue }
            let bare = String(preferred.prefix { $0 != ";" }).trimmingCharacters(in: .whitespaces)
            #expect(AppleKittyClipboardMime.mimeName(for: identifier) == bare)
        }
    }

    @Test func nativeIdentifiersWithoutAMIMEMappingAreNotAdvertised() {
        let identifiers = [
            "com.example.private.pasteboard-type",
            "NSStringPboardType",
            "dyn.ah62d4rv4gu8zg55gq",
        ]
        let names = AppleKittyClipboardMime.mimeNames(for: identifiers)
        #expect(names.allSatisfy { KittyClipboardMime.isValid($0) })
        #expect(!names.contains("com.example.private.pasteboard-type"))
        #expect(!names.contains("NSStringPboardType"))
    }

    @Test func duplicateMIMENamesAreRemovedAndOrderIsKept() {
        // Both plain-text identifiers map to `text/plain`; the first one wins
        // and serves the later read.
        let identifiers = ["public.utf8-plain-text", "public.plain-text", "public.html"]
        let catalog = AppleKittyClipboardCatalog(identifiers: identifiers)
        #expect(catalog.mimeTypes.first == "text/plain")
        #expect(Set(catalog.mimeTypes).count == catalog.mimeTypes.count)
        #expect(catalog.identifier(for: "text/plain") == "public.utf8-plain-text")
        if catalog.mimeTypes.contains("text/html") {
            #expect(catalog.mimeTypes == ["text/plain", "text/html"])
        }
    }

    @Test func aMIMENameSelectsItsPlatformIdentifierWithoutCaseDifferences() {
        let catalog = AppleKittyClipboardCatalog(identifiers: ["public.html", "public.utf8-plain-text"])
        guard AppleKittyClipboardMime.mimeName(for: "public.html") == "text/html" else {
            // The OS has no mapping for this identifier; nothing to check.
            return
        }
        #expect(catalog.identifier(for: "TEXT/HTML") == "public.html")
        #expect(catalog.identifier(for: "image/png") == nil)
    }

    @Test func anIdentifierThatIsAlreadyAMIMENameIsKept() {
        #expect(AppleKittyClipboardMime.mimeName(for: "text/x-private") == "text/x-private")
        #expect(AppleKittyClipboardMime.writeIdentifier(for: "text/x-private") != nil)
    }
}
#endif
