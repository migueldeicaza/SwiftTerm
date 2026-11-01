import Testing
@testable import SwiftTerm

/// KAM, SRM and DECBKM keep their state for DECRQM, DECID answers like DA1,
/// and RIS clears the alternate screen.
final class ModeReportTests {

    private func replies(_ delegate: TerminalTestDelegate) -> [String] {
        delegate.sentData.map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func decrqmReportsKamAndSrm() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "\u{1b}[2$p\u{1b}[2h\u{1b}[2$p\u{1b}[2l\u{1b}[2$p")
        terminal.feed(text: "\u{1b}[12$p\u{1b}[12l\u{1b}[12$p\u{1b}[12h\u{1b}[12$p")
        #expect(replies(delegate) == [
            "\u{1b}[2;2$y", "\u{1b}[2;1$y", "\u{1b}[2;2$y",
            "\u{1b}[12;1$y", "\u{1b}[12;2$y", "\u{1b}[12;1$y",
        ])
    }

    @Test func decbkmIsReportedSavedAndReset() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "\u{1b}[?67$p\u{1b}[?67h\u{1b}[?67$p")
        #expect(replies(delegate) == ["\u{1b}[?67;2$y", "\u{1b}[?67;1$y"])
        #expect(terminal.backarrowKeyMode)

        terminal.feed(text: "\u{1b}[?67s\u{1b}[?67l\u{1b}[?67r")
        #expect(terminal.backarrowKeyMode)

        terminal.feed(text: "\u{1b}[!p")
        #expect(!terminal.backarrowKeyMode)
        terminal.feed(text: "\u{1b}[?67h\u{1b}c")
        #expect(!terminal.backarrowKeyMode)
    }

    @Test func decbkmMakesTheBackspaceKeySendControlH() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.sendHostKey(key: "Backspace", code: "Backspace", modifiers: 0, eventType: 1, text: nil)
        terminal.feed(text: "\u{1b}[?67h")
        terminal.sendHostKey(key: "Backspace", code: "Backspace", modifiers: 0, eventType: 1, text: nil)
        #expect(delegate.sentData.suffix(2) == [[0x7f], [0x08]])
    }

    @Test func decidAnswersLikePrimaryDeviceAttributes() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "\u{1b}[c\u{1b}Z")
        let answers = replies(delegate)
        #expect(answers.count == 2)
        #expect(answers.first == answers.last)
    }

    @Test func fullResetClearsTheAlternateScreen() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "m\u{1b}[?47h\u{1b}[Ha\u{1b}c\u{1b}[?47h")
        #expect(terminal.isCurrentBufferAlternate)
        #expect(terminal.getCharacter(col: 0, row: 0) == "\u{0}" || terminal.getCharacter(col: 0, row: 0) == " ")
    }
}
