import Testing
@testable import SwiftTerm

/// DECRQM and DECRQSS report modes and settings that SwiftTerm only keeps,
/// DECSCL levels limit DECRQM and DECLRMM, and RIS leaves 132-column mode.
final class StatusReportTests {

    private func replies(_ delegate: TerminalTestDelegate) -> [String] {
        delegate.sentData.map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func reportedOnlyModesKeepTheirState() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        for mode in [18, 19, 35, 42] {
            terminal.feed(text: "\u{1b}[?\(mode)$p\u{1b}[?\(mode)h\u{1b}[?\(mode)$p\u{1b}[?\(mode)l\u{1b}[?\(mode)$p")
            #expect(replies(delegate).suffix(3) == [
                "\u{1b}[?\(mode);2$y", "\u{1b}[?\(mode);1$y", "\u{1b}[?\(mode);2$y",
            ])
        }
        terminal.feed(text: "\u{1b}[?42h\u{1b}c\u{1b}[?42$p")
        #expect(replies(delegate).last == "\u{1b}[?42;2$y")
    }

    @Test func dechccmIsPermanentlyReset() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "\u{1b}[?60h\u{1b}[?60$p")
        #expect(replies(delegate) == ["\u{1b}[?60;4$y"])
    }

    @Test func decrqssReportsAttributeExtentAndStatusLine() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "\u{1b}[2*x\u{1b}P$q*x\u{1b}\\\u{1b}[0*x\u{1b}P$q*x\u{1b}\\")
        terminal.feed(text: "\u{1b}P$q$~\u{1b}\\\u{1b}P$q$}\u{1b}\\")
        terminal.feed(text: "\u{1b}P$qt\u{1b}\\\u{1b}P$q*|\u{1b}\\")
        #expect(replies(delegate) == [
            "\u{1b}P1$r2*x\u{1b}\\", "\u{1b}P1$r0*x\u{1b}\\",
            "\u{1b}P1$r0$~\u{1b}\\", "\u{1b}P1$r0$}\u{1b}\\",
            "\u{1b}P1$r5t\u{1b}\\", "\u{1b}P1$r5*|\u{1b}\\",
        ])
    }

    @Test func decssdtDoesNotDeleteColumns() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "abc\u{1b}[H\u{1b}[0$~")
        #expect(terminal.getCharacter(col: 0, row: 0) == "a")
        terminal.feed(text: "\u{1b}['~")
        #expect(terminal.getCharacter(col: 0, row: 0) == "b")
    }

    @Test func decslppAndDecsnlsAskTheHostToResize() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "\u{1b}[30t\u{1b}[12*|\u{1b}[23t")
        let sizes = delegate.windowCommands.compactMap { command -> [Int]? in
            if case .resizeTerminal(let cols, let rows) = command {
                return [cols, rows]
            }
            return nil
        }
        #expect(sizes == [[20, 30], [20, 12]])
    }

    @Test func decsclLevel2HasNoDecrqm() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "\u{1b}[62;1\"p\u{1b}[4$p\u{1b}[?7$p")
        #expect(replies(delegate).isEmpty)
        terminal.feed(text: "\u{1b}[63;1\"p\u{1b}[4$p")
        #expect(replies(delegate) == ["\u{1b}[4;2$y"])
    }

    @Test func decsclLevel3HasNoDeclrmm() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "\u{1b}[63;1\"p\u{1b}[?69h")
        #expect(!terminal.marginMode)
        terminal.feed(text: "\u{1b}[64;1\"p\u{1b}[?69h")
        #expect(terminal.marginMode)
    }

    @Test func fullResetLeaves132ColumnMode() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 5)
        terminal.feed(text: "\u{1b}[?40h\u{1b}[?3h")
        #expect(terminal.cols == 132)
        terminal.feed(text: "\u{1b}c")
        #expect(terminal.cols == 80)
    }
}
