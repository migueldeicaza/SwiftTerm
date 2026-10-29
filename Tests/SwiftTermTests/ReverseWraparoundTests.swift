import Testing
@testable import SwiftTerm

/// Reverse wraparound as xterm 383 and later: mode 45 wraps back only across
/// rows that wrapped, and mode 1045 keeps the original behavior.
final class ReverseWraparoundTests {

    private func cursor(_ terminal: Terminal) -> (x: Int, y: Int) {
        (terminal.buffer.x, terminal.buffer.y)
    }

    @Test func mode45WrapsBackAcrossAWrappedRow() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 6)
        terminal.feed(text: "\u{1b}[?45h" + String(repeating: "x", count: 12))
        #expect(cursor(terminal) == (2, 1))
        terminal.feed(text: "\u{8}\u{8}\u{8}")
        #expect(cursor(terminal) == (9, 0))
    }

    @Test func mode45StopsAtARowThatDidNotWrap() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 6)
        terminal.feed(text: "\u{1b}[?45habc\r\ndef")
        terminal.feed(text: String(repeating: "\u{8}", count: 20))
        #expect(cursor(terminal) == (0, 1))
    }

    @Test func mode1045WrapsAcrossAnyRowAndFromTopToBottom() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 6)
        terminal.feed(text: "\u{1b}[?1045h\u{1b}[2;1H\u{8}")
        #expect(cursor(terminal) == (9, 0))
        terminal.feed(text: "\u{1b}[2;5r\u{1b}[2;1H\u{8}")
        #expect(cursor(terminal) == (9, 4))
    }

    @Test func cubWrapsBackLikeBackspace() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 6)
        terminal.feed(text: "\u{1b}[1;9Habcd\u{1b}[?1045h\u{1b}[4D")
        #expect(cursor(terminal) == (8, 0))
    }

    @Test func reverseWrapNeedsAutowrapWhenTheCursorMoves() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 6)
        // Setting the mode while DECAWM is off still sets it.
        terminal.feed(text: "\u{1b}[?7l\u{1b}[?1045h\u{1b}[2;1H\u{8}")
        #expect(cursor(terminal) == (0, 1))
        terminal.feed(text: "\u{1b}[?7h\u{8}")
        #expect(cursor(terminal) == (9, 0))
    }

    @Test func backspaceFromAPendingWrapStaysOnTheLastColumn() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 6)
        terminal.feed(text: "\u{1b}[?45h\u{1b}[1;9Hab\u{8}X")
        #expect(terminal.getLine(row: 0)?.translateToString(trimRight: true).hasSuffix("aX") == true)
    }

    @Test func restoreCursorDoesNotRestoreReverseWrap() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 6)
        terminal.feed(text: "\u{1b}[?1045h\u{1b}7\u{1b}[?1045l\u{1b}8")
        #expect(!terminal.reverseWraparoundExtended)
    }

    @Test func decrqmReportsBothModes() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 10, rows: 6)
        terminal.feed(text: "\u{1b}[?1045h\u{1b}[?1045$p\u{1b}[?45$p")
        let replies = delegate.sentData.map { String(decoding: $0, as: UTF8.self) }
        #expect(replies.suffix(2) == ["\u{1b}[?1045;1$y", "\u{1b}[?45;2$y"])
    }
}
