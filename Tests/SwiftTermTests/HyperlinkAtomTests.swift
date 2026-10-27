//
//  HyperlinkAtomTests.swift
//
//  A hyperlink redrawn many times, as a full-screen program under tmux redraws it,
//  must not spend the 16-bit atom space; and codes the collector releases must be
//  handed out again.
//

import Foundation
import Testing

@testable import SwiftTerm

final class HyperlinkAtomTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {
    }

    private func link(_ url: String, _ text: String) -> String {
        "\u{1b}]8;id=x;\(url)\u{1b}\\\(text)\u{1b}]8;;\u{1b}\\"
    }

    @Test func testRedrawnHyperlinkReusesOneAtom() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 2))
        let drawn = link("https://example.com/a", "PR #1")
        terminal.feed(text: drawn)
        let first = terminal.displayBuffer.lines[0][0].payload.code
        #expect(first != 0)

        // More redraws than there are 16-bit codes: before, the link stopped resolving
        // once they were spent, in this terminal and every other one in the process.
        for _ in 0..<70_000 {
            terminal.feed(text: "\r" + drawn)
        }

        #expect(terminal.displayBuffer.lines[0][0].payload.code == first)
        #expect(terminal.link(at: .screen(Position(col: 1, row: 0)), mode: .explicitOnly) == "https://example.com/a")
    }

    @Test func testCollectedAtomsAreHandedOutAgain() throws {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 30, rows: 2, scrollback: 0))
        var codes = Set<UInt16>()
        for n in 0..<200 {
            terminal.feed(text: link("https://example.com/\(n)", "link \(n)"))
            codes.insert(terminal.displayBuffer.lines[terminal.buffer.y + terminal.buffer.yBase][0].payload.code)
            terminal.feed(text: "\r\n")
        }
        codes.remove(0)
        #expect(codes.count == 200)

        // Every link has scrolled away with no scrollback, so the collector releases them all.
        terminal.feed(text: "\r\n\r\n\r\n")
        terminal.garbageCollectPayload()

        let again = try #require(TinyAtom.lookup(value: "probe"))
        defer { again.release() }
        #expect(codes.contains(again.code))
    }
}
