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

    @Test func nativeIdentifiersWithoutAMIMEMappingAreNotAdvertised() {
        let identifiers = [
            "com.example.private.pasteboard-type",
            "public.utf8-plain-text",
            "NSStringPboardType",
            "dyn.ah62d4rv4gu8zg55gq",
        ]
        let names = AppleKittyClipboardMime.mimeNames(for: identifiers)
        #expect(names.allSatisfy { KittyClipboardMime.isValid($0) })
        #expect(!names.contains("com.example.private.pasteboard-type"))
        #expect(!names.contains("NSStringPboardType"))
    }

    @Test func duplicateMIMENamesAreRemovedAndOrderIsKept() {
        // Both plain-text identifiers map to `text/plain`.
        let identifiers = ["public.utf8-plain-text", "public.plain-text", "public.html"]
        let names = AppleKittyClipboardMime.mimeNames(for: identifiers)
        #expect(names == Array(NSOrderedSet(array: names)) as? [String] ?? names)
        #expect(Set(names).count == names.count)
        if names.contains("text/plain"), names.contains("text/html") {
            #expect(names.firstIndex(of: "text/plain")! < names.firstIndex(of: "text/html")!)
        }
    }

    @Test func aMIMENameSelectsItsPlatformIdentifierWithoutCaseDifferences() {
        let identifiers = ["public.html", "public.utf8-plain-text"]
        guard AppleKittyClipboardMime.mimeName(for: "public.html") == "text/html" else {
            // The OS has no mapping for this identifier; nothing to check.
            return
        }
        #expect(AppleKittyClipboardMime.identifier(for: "TEXT/HTML", among: identifiers)
            == "public.html")
        #expect(AppleKittyClipboardMime.identifier(for: "image/png", among: identifiers) == nil)
    }

    @Test func anIdentifierThatIsAlreadyAMIMENameIsKept() {
        #expect(AppleKittyClipboardMime.mimeName(for: "text/x-private") == "text/x-private")
        #expect(AppleKittyClipboardMime.writeIdentifier(for: "text/x-private") != nil)
    }
}
#endif
