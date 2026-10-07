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

    /// A line feed that scrolls brings in a fresh row; it must stay unwrapped,
    /// and text that genuinely wraps after it must still be marked as wrapped.
    @Test func realSoftWrapsAfterALineFeedAreKept() {
        let terminal = makeTerminal(cols: 10)
        terminal.feed(text: "x\r\nABCDEFGHIJKL")

        #expect(!terminal.buffer.lines[terminal.buffer.yBase + 1].isWrapped)
        #expect(terminal.buffer.lines[terminal.buffer.yBase + 2].isWrapped)
    }
}
