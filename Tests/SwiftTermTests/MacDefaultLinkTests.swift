#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@Suite("Mac default link handling")
struct MacDefaultLinkTests {
    @Test func detectedPathsUseTheSameFileChecksAsOsc8() throws {
        try withTemporaryFile(named: "payload.command") { url in
            #expect(TerminalView.defaultLinkTarget(url.path, isExplicit: false).decision == .deny(.unsafeFile))
            #expect(TerminalView.defaultLinkTarget(url.absoluteString, isExplicit: false).decision == .deny(.unsafeFile))
            #expect(TerminalView.defaultLinkTarget(url.absoluteString, isExplicit: true).decision == .deny(.unsafeFile))
        }
    }

    @Test func explicitTargetsCannotFallBackToFilePaths() throws {
        try withTemporaryFile(named: "document.txt") { url in
            #expect(TerminalView.defaultLinkTarget(url.path, isExplicit: true).decision == .deny(.malformedURL))
            #expect(TerminalView.defaultLinkTarget("\(url.path):42:10", isExplicit: false).decision ==
                    .allow(url.standardizedFileURL.resolvingSymlinksInPath()))
        }
    }

    @Test func nameWithALocationIsAPathAndNotAScheme() throws {
        #expect(!TerminalView.hasURLScheme("main.swift:12"))
        #expect(!TerminalView.hasURLScheme("README.md:3:4"))
        #expect(TerminalView.hasURLScheme("https://example.com:443"))
        #expect(TerminalView.hasURLScheme("tel:5551234"))
        #expect(TerminalView.hasURLScheme("SMS:5551234"))
        #expect(!TerminalView.hasURLScheme("Makefile:12"))
        #expect(TerminalView.defaultLinkTarget("main.swift:12", isExplicit: true).decision == .deny(.malformedURL))
        #expect(TerminalView.defaultLinkTarget("missing-\(UUID()).swift:12", isExplicit: false).decision
                == .deny(.malformedURL))
        #expect(TerminalView.defaultLinkTarget("tel:5551234", isExplicit: false).decision
                == .confirm(URL(string: "tel:5551234")!))
        try withTemporaryFile(named: "main.swift") { url in
            let base = TerminalView.LinkPathBase.directory(url.deletingLastPathComponent().path)
            #expect(TerminalView.defaultLinkTarget("main.swift:12", isExplicit: false, pathBase: base).decision
                    == .allow(url.standardizedFileURL.resolvingSymlinksInPath()))
        }
    }

    @Test func knownSchemeIsNotAFileWithTheSameName() throws {
        try withTemporaryFile(named: "tel") { url in
            let base = TerminalView.LinkPathBase.directory(url.deletingLastPathComponent().path)
            #expect(TerminalView.defaultLinkURL("tel:5551234", pathBase: base) == URL(string: "tel:5551234"))
            #expect(TerminalView.defaultLinkTarget("tel:5551234", isExplicit: false, pathBase: base).decision
                    == .confirm(URL(string: "tel:5551234")!))
        }
        try withTemporaryFile(named: "Makefile") { url in
            let base = TerminalView.LinkPathBase.directory(url.deletingLastPathComponent().path)
            // Another name stays a path; the file check then decides.
            #expect(TerminalView.defaultLinkURL("Makefile:12", pathBase: base)?.path == url.path)
        }
    }

    @Test func osc7DirectoryIsTheBaseForRelativePaths() {
        #expect(TerminalView.linkPathBase(hostCurrentDirectory: nil) == .processDirectory)
        #expect(TerminalView.linkPathBase(hostCurrentDirectory: "/Users/me") == .directory("/Users/me"))
        #expect(TerminalView.linkPathBase(hostCurrentDirectory: "file:///Users/me") == .directory("/Users/me"))
        #expect(TerminalView.linkPathBase(hostCurrentDirectory: "file://localhost/Users/my%20dir")
                == .directory("/Users/my dir"))
        #expect(TerminalView.linkPathBase(hostCurrentDirectory: "file://remote.example.com/Users/me") == .remote)
        #expect(TerminalView.defaultLinkURL("/etc/hosts", pathBase: .remote) == nil)
    }

    @Test func rawPathControlsAreCheckedBeforeURLConversion() {
        let target = TerminalView.defaultLinkTarget("/tmp/document\u{202E}.txt", isExplicit: false)
        #expect(target.decision == .deny(.unsafeCharacters))
    }

    @Test @MainActor func previewsEscapeControlsAndRespectTheSetting() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        view.previewUrl(payload: ";https://example.com/\u{202E}file\u{2028}end")
        #expect(view.urlPreview?.stringValue == "https://example.com/\\u{202E}file\\u{2028}end")
        view.enableOsc8Hyperlinks = false
        #expect(view.urlPreview == nil)
        view.previewUrl(payload: ";https://example.com")
        #expect(view.urlPreview == nil)
    }

    @Test @MainActor func customSchemeConfirmationDefaultsToCancel() throws {
        let url = try #require(URL(string: "ssh://example.com"))
        let alert = TerminalLinkOpening.confirmationAlert(for: url, displayString: url.absoluteString)
        #expect(alert.buttons.map(\.title) == ["Cancel", "Open Link"])
        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(alert.buttons[1].keyEquivalent.isEmpty)
    }

    @Test @MainActor func coreSettingRemovesThePreviewOnTheNextFrame() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        view.frameDriver.invalidate()
        view.previewUrl(payload: ";https://example.com")
        #expect(view.urlPreview != nil)
        view.withTerminal { $0.enableOsc8Hyperlinks = false }
        _ = view.captureFrameViewState()
        #expect(view.urlPreview == nil)
    }

    @Test func keepsExplicitURL() throws {
        let expected = try #require(URL(string: "https://example.com/path"))

        #expect(TerminalView.defaultLinkURL(expected.absoluteString) == expected)
    }

    @Test func createsFileURLForExistingPathWithSpaces() throws {
        try withTemporaryFile(named: "file with spaces.txt") { fileURL in
            #expect(TerminalView.defaultLinkURL(fileURL.path) == fileURL)
        }
    }

    @Test func removesLineAndColumnLocation() throws {
        try withTemporaryFile(named: "source.swift") { fileURL in
            #expect(TerminalView.defaultLinkURL("\(fileURL.path):42") == fileURL)
            #expect(TerminalView.defaultLinkURL("\(fileURL.path):42:10") == fileURL)
        }
    }

    @Test func keepsExistingFilenameThatEndsWithLocationSyntax() throws {
        try withTemporaryFile(named: "source.swift:42") { fileURL in
            #expect(TerminalView.defaultLinkURL(fileURL.path) == fileURL)
        }
    }

    @Test func rejectsMissingFile() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path

        #expect(TerminalView.defaultLinkURL(path) == nil)
        #expect(TerminalView.defaultLinkURL("\(path):42:10") == nil)
    }

    private func withTemporaryFile(
        named name: String,
        body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent(name)
        #expect(FileManager.default.createFile(atPath: fileURL.path, contents: Data()))
        try body(fileURL)
    }
}
#endif
