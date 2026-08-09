#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

@Suite("Mac default link handling")
struct MacDefaultLinkTests {
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
