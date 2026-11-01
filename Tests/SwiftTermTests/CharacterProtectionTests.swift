import Foundation
import Testing
@testable import SwiftTerm

/// Character protection: DECSCA (`CSI Ps " q`) and SPA/EPA (`ESC V` / `ESC W`).
///
/// As in xterm, DECSED, DECSEL and DECSERA keep cells that DECSCA protects.
/// ED, EL and ECH keep protected cells only when the protection came from
/// SPA (ISO protection).
final class CharacterProtectionTests {

    /// The text of a row, with erased (NUL) cells shown as spaces.
    private func row(_ terminal: Terminal, _ y: Int = 0) -> String {
        let text = terminal.getLine(row: y)?.translateToString(trimRight: true) ?? ""
        return String(text.map { $0 == "\u{0}" ? " " : $0 })
            .replacingOccurrences(of: " +$", with: "", options: .regularExpression)
    }

    @Test func decselKeepsDecProtectedCells() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "a\u{1b}[1\"qbc\u{1b}[0\"qd")
        terminal.feed(text: "\u{1b}[1;1H\u{1b}[?2K")
        #expect(row(terminal) == " bc")
    }

    @Test func decsedKeepsDecProtectedCellsOnAllRows() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "x\u{1b}[1\"qP\u{1b}[0\"qy\r\n")
        terminal.feed(text: "\u{1b}[1\"qQ\u{1b}[0\"qzz")
        terminal.feed(text: "\u{1b}[?2J")
        #expect(row(terminal, 0) == " P")
        #expect(row(terminal, 1) == "Q")
    }

    @Test func protectedTextUsesTheBulkPathAgainAfterProtectionEnds() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "\u{1b}[1\"qprotected\u{1b}[0\"qplain")
        terminal.feed(text: "\u{1b}[?2K")
        #expect(row(terminal) == "protected")
    }

    @Test func protectedWideCharacterKeepsBothCells() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "\u{1b}[1\"q\u{4e2d}\u{1b}[0\"qab")
        terminal.feed(text: "\u{1b}[?2K")
        #expect(row(terminal) == "\u{4e2d}")
    }

    @Test func edAndElIgnoreDecProtection() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "\u{1b}[1\"qab\u{1b}[0\"q")
        terminal.feed(text: "\u{1b}[1;1H\u{1b}[K")
        #expect(row(terminal) == "")
    }

    @Test func edElAndEchKeepIsoProtectedCells() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "ab\u{1b}Vc\u{1b}Wd")
        terminal.feed(text: "\u{1b}[1;1H\u{1b}[K")
        #expect(row(terminal) == "  c")
        terminal.feed(text: "\u{1b}[1;1H\u{1b}[J")
        #expect(row(terminal) == "  c")
        terminal.feed(text: "\u{1b}[1;1H\u{1b}[5X")
        #expect(row(terminal) == "  c")
    }

    @Test func decseraKeepsDecButNotIsoProtection() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "\u{1b}[1\"qa\u{1b}[0\"qb")
        terminal.feed(text: "\u{1b}[1;1;1;2${")
        #expect(row(terminal) == "a")

        terminal.feed(text: "\u{1b}[2;1H\u{1b}Va\u{1b}Wb")
        terminal.feed(text: "\u{1b}[2;1;2;2${")
        #expect(row(terminal, 1) == "")
    }

    @Test func decscAndDecrcSaveTheProtectionAttribute() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "\u{1b}[1\"q\u{1b}7\u{1b}[0\"q\u{1b}8a")
        terminal.feed(text: "\u{1b}[1;1H\u{1b}[?K")
        #expect(row(terminal) == "a")
    }

    @Test func softResetTurnsProtectionOff() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "\u{1b}V\u{1b}[!pab")
        terminal.feed(text: "\u{1b}[1;1H\u{1b}[?K")
        #expect(row(terminal) == "")
    }

    @Test func decrqssReportsDecsca() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "\u{1b}[1\"q\u{1b}P$q\"q\u{1b}\\")
        #expect(String(decoding: delegate.sentData.flatMap { $0 }, as: UTF8.self).hasSuffix("1$r1\"q\u{1b}\\"))
    }
}
