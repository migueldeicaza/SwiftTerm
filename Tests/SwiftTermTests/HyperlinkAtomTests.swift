//
//  HyperlinkAtomTests.swift
//
//  A hyperlink redrawn many times, as a full-screen program under tmux redraws it,
//  must not spend the 16-bit atom space; codes the collector releases must be
//  handed out again; and a terminal must collect on its own as links accumulate.
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

    private func cursorCode(_ terminal: Terminal) -> UInt16 {
        terminal.displayBuffer.lines[terminal.buffer.y + terminal.buffer.yBase][0].payload.code
    }

    private func leaveFreeCodes(_ count: Int) throws {
        var atoms: [TinyAtom] = []
        defer {
            for atom in atoms {
                atom.release()
            }
        }
        for _ in 0..<count {
            atoms.append(try #require(TinyAtom.lookup(value: "earlier test")))
        }
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
        // An earlier test can leave more free codes than this test allocates.
        try leaveFreeCodes(1024)

        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 30, rows: 2, scrollback: 0))
        var codes = Set<UInt16>()
        for n in 0..<200 {
            terminal.feed(text: link("https://example.com/\(n)", "link \(n)"))
            codes.insert(cursorCode(terminal))
            terminal.feed(text: "\r\n")
        }
        codes.remove(0)
        #expect(codes.count == 200)

        // Every link has scrolled away with no scrollback, so the collector releases them all.
        terminal.feed(text: "\r\n\r\n\r\n")
        terminal.garbageCollectPayload()

        // Older free codes can precede ours anywhere in the 16-bit code space.
        // Release each probe so this test does not drain the shared table.
        var reused = false
        for _ in 0..<(Int(UInt16.max) - 1) {
            let probe = try #require(TinyAtom.lookup(value: "probe"))
            reused = codes.contains(probe.code)
            probe.release()
            if reused {
                break
            }
        }
        #expect(reused)
    }

    @Test func testCollectedLinkRedrawnResolvesToItsOwnURL() throws {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 30, rows: 2, scrollback: 0))
        let drawn = link("https://example.com/a", "link a")
        terminal.feed(text: drawn)
        terminal.feed(text: "\r\n\r\n\r\n")
        terminal.garbageCollectPayload()

        // Whatever now holds link a's old code, drawing link a again must not reuse a stale entry.
        let probe = try #require(TinyAtom.lookup(value: "probe"))
        defer { probe.release() }
        terminal.feed(text: drawn)
        let row = terminal.buffer.y
        #expect(terminal.link(at: .screen(Position(col: 1, row: row)), mode: .explicitOnly) == "https://example.com/a")
        #expect(probe.target as? String == "probe")
    }

    @Test func testTerminalCollectsOnItsOwnAsLinksAccumulate() throws {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 30, rows: 2, scrollback: 0))
        let firstPayload = "id=x;https://example.com/first"
        terminal.feed(text: link("https://example.com/first", "first"))
        let first = cursorCode(terminal)
        #expect(first != 0)
        terminal.feed(text: "\r\n")

        // Far more distinct links than the first collection threshold, each scrolled away.
        for n in 0..<3_000 {
            terminal.feed(text: link("https://example.com/\(n)", "link \(n)") + "\r\n")
        }

        // The first link's code was released along the way: it no longer names that link.
        #expect(TinyAtom.stored(code: first).target as? String != firstPayload)
    }
}
