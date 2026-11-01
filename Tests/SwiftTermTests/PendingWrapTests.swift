import Testing
@testable import SwiftTerm

/// The cursor after a write to the last column, and the DECAWM state that
/// DECSC/DECRC and XTSAVE/XTRESTORE keep.
final class PendingWrapTests {

    private func lastResponse(_ delegate: TerminalTestDelegate) -> String {
        String(decoding: delegate.sentData.last ?? [], as: UTF8.self)
    }

    @Test func cursorReportGivesTheLastColumnWhileAWrapIsPending() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 10, rows: 5)
        terminal.feed(text: String(repeating: "x", count: 10))
        terminal.feed(text: "\u{1b}[6n")
        #expect(lastResponse(delegate) == "\u{1b}[1;10R")
        terminal.feed(text: "\u{1b}[?6n")
        #expect(lastResponse(delegate) == "\u{1b}[?1;10;1R")

        // The next character still wraps.
        terminal.feed(text: "y\u{1b}[6n")
        #expect(lastResponse(delegate) == "\u{1b}[2;2R")
    }

    @Test func cursorReportGivesTheLastColumnWithoutAutowrap() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 10, rows: 5)
        terminal.feed(text: "\u{1b}[?7l" + String(repeating: "x", count: 12))
        terminal.feed(text: "\u{1b}[6n")
        #expect(lastResponse(delegate) == "\u{1b}[1;10R")
    }

    @Test func restoreCursorDoesNotRestoreAutowrap() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 10, rows: 5)
        terminal.feed(text: "\u{1b}[?7h\u{1b}7\u{1b}[?7l\u{1b}8")
        terminal.feed(text: "\u{1b}[1;9Habcd\u{1b}[6n")
        #expect(lastResponse(delegate) == "\u{1b}[1;10R")
    }

    @Test func xtermSaveAndRestoreKeepAutowrap() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 10, rows: 5)
        terminal.feed(text: "\u{1b}[?7h\u{1b}[?7s\u{1b}[?7l\u{1b}[?7r")
        #expect(terminal.wraparound)
        terminal.feed(text: "\u{1b}[?7l\u{1b}[?7s\u{1b}[?7h\u{1b}[?7r")
        #expect(!terminal.wraparound)

        terminal.feed(text: "\u{1b}[?7$p")
        #expect(lastResponse(delegate) == "\u{1b}[?7;2$y")
        terminal.feed(text: "\u{1b}[?7h\u{1b}[?7$p")
        #expect(lastResponse(delegate) == "\u{1b}[?7;1$y")
    }
}
