#if os(macOS) && !SWIFTTERM_EMBEDDED
import Foundation
import Testing
@testable import SwiftTerm

@Suite("Mac terminal link policy")
struct MacUntrustedLinkTests {
    @Test(arguments: [
        "http://example.com", "https://example.com/path", "HTTPS://example.com/path",
        "mailto:user@example.com", "mailto:user@example.com?subject=Hello",
    ])
    func allowsWebAndMailLinks(_ value: String) throws {
        let url = try #require(URL(string: value))
        #expect(UntrustedTerminalLink(value).decision == .allow(url))
    }

    @Test(arguments: ["https:relative", "http:///missing-host", "https://"])
    func rejectsWebLinksWithoutHosts(_ value: String) {
        #expect(UntrustedTerminalLink(value).decision == .deny(.invalidWebURL))
    }

    @Test(arguments: ["", "/tmp/file.txt", "../file.txt", "payload.command", "mailto:", "mailto:?subject=Hello"])
    func rejectsMalformedLinks(_ value: String) {
        #expect(UntrustedTerminalLink(value).decision == .deny(.malformedURL))
    }

    @Test(arguments: ["vscode://file/tmp/example.swift", "ssh://example.com", "custom:payload"])
    func requiresConfirmationForCustomSchemes(_ value: String) throws {
        let url = try #require(URL(string: value))
        #expect(UntrustedTerminalLink(value).decision == .confirm(url))
    }

    @Test(arguments: [
        0x00, 0x09, 0x0A, 0x0D, 0x1F, 0x7F, 0x85, 0x9F, 0x061C,
        0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x2028, 0x2029,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2060,
        0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF,
    ])
    func rejectsUnsafeCharacters(_ value: UInt32) throws {
        let scalar = try #require(Unicode.Scalar(value))
        let target = "https://example.com/a\(scalar)b"
        #expect(UntrustedTerminalLink.containsUnsafeCharacters(target))
        #expect(UntrustedTerminalLink(target).decision == .deny(.unsafeCharacters))
        #expect(UntrustedTerminalLink(target).displayString ==
                "https://example.com/a\\u{\(String(value, radix: 16, uppercase: true))}b")
    }

    @Test(arguments: ["https://example.com/café", "mailto:日本@example.com", "custom:a b"])
    func permitsVisibleCharacters(_ value: String) {
        #expect(!UntrustedTerminalLink.containsUnsafeCharacters(value))
    }

    @Test
    func allowsRegularFilesAndDirectories() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try makeFile("document.txt", in: directory)
        for url in [directory, file] {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            #expect(UntrustedTerminalLink(url.absoluteString).decision == .allow(canonical))
        }
        let localHost = file.absoluteString.replacingOccurrences(of: "file:///", with: "file://localhost/")
        #expect(UntrustedTerminalLink(localHost).decision ==
                .allow(file.standardizedFileURL.resolvingSymlinksInPath()))
    }

    @Test(arguments: [
        "action", "app", "applescript", "class", "command", "desktop",
        "inetloc", "jar", "mobileconfig", "mpkg", "pkg", "scpt", "terminal",
        "tool", "url", "webloc", "workflow", "COMMAND",
    ])
    func rejectsExecutableExtensions(_ ext: String) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try makeFile("payload.\(ext)", in: directory)
        #expect(UntrustedTerminalLink(file.absoluteString).decision == .deny(.unsafeFile))
    }

    @Test(arguments: ["payload.sh", "payload.py", "payload.js"])
    func rejectsScriptTypesWithoutExecutePermission(_ name: String) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try makeFile(name, in: directory)
        #expect(UntrustedTerminalLink(file.absoluteString).decision == .deny(.unsafeFile))
    }

    @Test
    func rejectsExecutableFilesAndApplicationDirectories() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try makeFile("document.txt", in: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        #expect(UntrustedTerminalLink(file.absoluteString).decision == .deny(.unsafeFile))
        let application = directory.appendingPathComponent("Payload.app", isDirectory: true)
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: false)
        #expect(UntrustedTerminalLink(application.absoluteString).decision == .deny(.unsafeFile))
    }

    @Test
    func rejectsMissingFilesAndSpecialFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing.txt")
        #expect(UntrustedTerminalLink(missing.absoluteString).decision == .deny(.inaccessibleFile))
        #expect(UntrustedTerminalLink("file:///dev/null").decision == .deny(.inaccessibleFile))
    }

    @Test(arguments: ["file://remote.example/tmp/file.txt", "file:///tmp/file.txt?query", "file:///tmp/file.txt#fragment"])
    func rejectsRemoteFilesQueriesAndFragments(_ value: String) {
        #expect(UntrustedTerminalLink(value).decision == .deny(.malformedURL))
    }

    @Test
    func resolvesSymlinksBeforeCheckingAndShowingFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = try makeFile("payload.command", in: directory)
        let link = directory.appendingPathComponent("document.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: payload)
        let target = UntrustedTerminalLink(link.absoluteString)
        #expect(target.decision == .deny(.unsafeFile))
        #expect(target.displayString == payload.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    @Test(arguments: ["\u{0085}", "\u{2028}", "\u{2029}"])
    func previewRemovesPathPaddingAndTraversal(_ separator: String) {
        let value = "/tmp/preview\(separator)////../payload.command////"
        #expect(UntrustedTerminalLink(value).displayString == "/tmp/payload.command")
    }

    @Test(arguments: ["https://example.com/a////../b", "custom://host/a////../b", "https://example.com/a%0Ab"])
    func previewPreservesWebAndCustomTargets(_ value: String) {
        #expect(UntrustedTerminalLink(value).displayString == value)
    }

    @Test(arguments: [0x0A, 0x85, 0x2028, 0x202E, 0x2066])
    func previewEscapesEncodedControlsInLocalFilenames(_ value: UInt32) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scalar = try #require(Unicode.Scalar(value))
        let file = try makeFile("before\(scalar)after.txt", in: directory)
        let canonical = file.standardizedFileURL.resolvingSymlinksInPath()
        let target = UntrustedTerminalLink(file.absoluteString)
        #expect(!UntrustedTerminalLink.containsUnsafeCharacters(file.absoluteString))
        #expect(target.decision == .allow(canonical))
        #expect(target.displayString == canonical.path.replacingOccurrences(
            of: String(scalar), with: "\\u{\(String(value, radix: 16, uppercase: true))}"))
        #expect(!UntrustedTerminalLink.containsUnsafeCharacters(target.displayString))
    }

    @Test
    func filePreviewUsesTheCanonicalPath() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try makeFile("document.txt", in: directory)
        let padded = directory.absoluteString + "unused/../document.txt"
        let canonical = file.standardizedFileURL.resolvingSymlinksInPath()
        let target = UntrustedTerminalLink(padded)
        #expect(target.decision == .allow(canonical))
        #expect(target.displayString == canonical.path)
    }

    private func makeFile(_ name: String, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try "plain text".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        return file
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
#endif
