//
//  LineFeedWrapTests.swift
//
//  A line feed into an existing row ends any soft wrap that row carried.
//  Programs that repaint in place (Claude Code and other Ink apps redraw the
//  whole screen with CR LF after a SIGWINCH) write new lines over rows that a
//  narrowing reflow had marked as continuations. If the flag survives, the next
//  widening reflow joins those unrelated lines onto the ones above them.
//

import Foundation
import Testing

@testable import SwiftTerm

@Suite final class LineFeedWrapTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    private func makeTerminal(cols: Int, rows: Int = 4) -> Terminal {
        Terminal(delegate: self,
                 options: TerminalOptions(cols: cols, rows: rows, scrollback: 10))
    }

    private func row(_ terminal: Terminal, _ index: Int) -> String {
        terminal.buffer.translateBufferLineToString(lineIndex: terminal.buffer.yBase + index, trimRight: true)
    }

    @Test func lineFeedIntoASoftWrappedRowEndsTheWrap() {
        let terminal = makeTerminal(cols: 10)
        terminal.feed(text: "ABCDEFGHIJKLMNO")
        #expect(terminal.buffer.lines[terminal.buffer.yBase + 1].isWrapped)

        terminal.feed(text: "\u{1b}[H\u{1b}[2Kfirst\r\n\u{1b}[2Ksecond")

        #expect(!terminal.buffer.lines[terminal.buffer.yBase + 1].isWrapped)
    }

    /// The way it shows: a repaint after narrowing, then widening back.
    @Test func repaintedRowsAreNotJoinedByTheNextWidening() {
        let terminal = makeTerminal(cols: 20)
        terminal.feed(text: "0123456789abcdefghij\r\n> ")
        terminal.resize(cols: 10, rows: 4)
        #expect(terminal.buffer.lines[terminal.buffer.yBase + 1].isWrapped)

        terminal.feed(text: "\u{1b}[H\u{1b}[2Kfirst\r\n\u{1b}[2Ksecond\r\n\u{1b}[2K> ")
        terminal.resize(cols: 20, rows: 4)

        #expect(row(terminal, 0) == "first")
        #expect(row(terminal, 1) == "second")
        #expect(row(terminal, 2) == "> ")
    }

    @Test func realSoftWrapsAfterAScrollingLineFeedAreKept() {
        let terminal = makeTerminal(cols: 10, rows: 2)
        terminal.feed(text: "x\r\nx\r\n")
        #expect(terminal.buffer.yBase > 0)
        #expect(!terminal.buffer.lines[terminal.buffer.yBase + 1].isWrapped)

        terminal.feed(text: "ABCDEFGHIJKL")

        #expect(!terminal.buffer.lines[terminal.buffer.yBase].isWrapped)
        #expect(terminal.buffer.lines[terminal.buffer.yBase + 1].isWrapped)
    }

    @Test(arguments: [false, true])
    func splittingAWrappedParagraphRequestsRedraw(hasScrollback: Bool) throws {
        let terminal = makeTerminal(cols: 10)
        if hasScrollback {
            terminal.feed(text: String(repeating: "old\r\n", count: 5))
            terminal.feed(text: "\u{1b}[H")
            #expect(terminal.buffer.yBase > 0)
        }
        terminal.feed(text: String(repeating: "ب", count: 12))
        terminal.feed(text: "\u{1b}[H")
        terminal.clearUpdateRange()

        terminal.feed(text: "\n")

        let range = terminal.getUpdateRange()
        let dirty = try #require(range)
        #expect(dirty.startY == 0)
        #expect(dirty.endY == 1)
    }
}
