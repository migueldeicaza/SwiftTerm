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
