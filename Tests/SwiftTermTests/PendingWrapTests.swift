//
//  PendingWrapTests.swift
//
//  The pending-wrap flag: after a write to the last column the cursor stays
//  on that column and the next printed character wraps first. The rules
//  follow xterm 411 (`do_wrap` in charproc.c, cursor.c and util.c), which
//  Ghostty (`cursor.pending_wrap`) also follows except where a test says so.
//
import Foundation
import Testing

@testable import SwiftTerm

@Suite("Pending wrap")
struct PendingWrapTests {
    private let esc = "\u{1b}"
    private let csi = "\u{1b}["

    private func make(cols: Int = 10, rows: Int = 4, scrollback: Int = 0)
        -> (Terminal, TerminalTestDelegate) {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(
            cols: cols, rows: rows, scrollback: scrollback)
        return (terminal, delegate)
    }

    private func line(_ terminal: Terminal, _ row: Int) -> String {
        TerminalTestHarness.lineText(buffer: terminal.buffer, row: row, trimRight: false) ?? ""
    }

    private func character(_ terminal: Terminal, row: Int, col: Int) -> String {
        let buffer = terminal.buffer
        return buffer.lines[buffer.yBase + row].packedView(at: col).getText()
    }

    private func response(_ delegate: TerminalTestDelegate) -> String {
        String(decoding: delegate.sentData.flatMap { $0 }, as: UTF8.self)
    }

    /// Fills row `row` (0-based) of a 10-column terminal, so a wrap is pending.
    private func fillRow(_ terminal: Terminal, row: Int = 0, text: String = "0123456789") {
        terminal.feed(text: "\(csi)\(row + 1);1H\(text)")
    }

    // MARK: - The flag and the cursor column

    @Test func lastColumnKeepsCursorOnItWithFlag() {
        let (terminal, _) = make()
        fillRow(terminal)
        #expect(terminal.buffer.x == 9)
        #expect(terminal.buffer.y == 0)
        #expect(terminal.buffer.pendingWrap)

        terminal.feed(text: "Z")
        #expect(character(terminal, row: 1, col: 0) == "Z")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 1, row: 1)
        #expect(!terminal.buffer.pendingWrap)
        #expect(TerminalTestHarness.isWrapped(buffer: terminal.buffer, row: 1) == true)
    }

    /// The same result for each print path: the ASCII run, the scalar batch,
    /// a single scalar, and the per-character path (insert mode blocks the
    /// bulk paths).
    @Test(arguments: [
        ("ascii", "0123456789", ""),
        ("scalarBatch", "αβγδεζηθικ", ""),
        ("singleScalar", "012345678é", ""),
        ("insertMode", "0123456789", "\u{1b}[4h"),
    ])
    func eachPrintPathSetsTheFlag(name: String, text: String, setup: String) {
        let (terminal, _) = make()
        terminal.feed(text: setup)
        terminal.feed(text: text)
        #expect(terminal.buffer.x == 9, "\(name)")
        #expect(terminal.buffer.pendingWrap, "\(name)")
        terminal.feed(text: "Z")
        #expect(character(terminal, row: 1, col: 0) == "Z", "\(name)")
    }

    @Test func byteByByteFeedSetsTheFlag() {
        let (terminal, _) = make()
        for byte in "0123456789Z".utf8 {
            terminal.feed(byteArray: [byte])
        }
        #expect(line(terminal, 0) == "0123456789")
        #expect(character(terminal, row: 1, col: 0) == "Z")
    }

    @Test func wideCharacterEndingOnLastColumnSetsTheFlag() {
        let (terminal, _) = make()
        terminal.feed(text: "01234567中")
        #expect(terminal.buffer.x == 9)
        #expect(terminal.buffer.pendingWrap)
        terminal.feed(text: "Z")
        #expect(character(terminal, row: 1, col: 0) == "Z")
    }

    // MARK: - DECAWM

    /// esctest DECSETTests.test_DECSET_DECAWM_OffRespectsLeftRightMargin.
    @Test func decawmResetRespectsLeftRightMargin() {
        let (terminal, delegate) = make()
        terminal.feed(text: "\(csi)?69h\(csi)5;9s\(csi)1;8H\(csi)?7labcdef")
        #expect(line(terminal, 0) == "       af ")
        #expect(terminal.buffer.x == 8)
        terminal.feed(text: "\(csi)6n")
        #expect(response(delegate) == "\(csi)1;9R")
    }

    @Test func decawmResetWithoutMargins() {
        let (terminal, delegate) = make()
        terminal.feed(text: "\(csi)?7l\(csi)1;8Habcdef")
        // As xterm: the last character of the string ends on the last column.
        #expect(line(terminal, 0) == "       abf")
        #expect(line(terminal, 1) == "          ")
        terminal.feed(text: "\(csi)6n")
        #expect(response(delegate) == "\(csi)1;10R")
    }

    /// The flag is set also with DECAWM reset (xterm `need_wrap`). Setting
    /// DECAWM before the next print makes that print wrap.
    @Test func flagSetWithDecawmResetWrapsAfterDecawmSet() {
        let (terminal, _) = make()
        terminal.feed(text: "\(csi)?7l0123456789")
        #expect(terminal.buffer.pendingWrap)
        terminal.feed(text: "\(csi)?7hZ")
        #expect(line(terminal, 0) == "0123456789")
        #expect(character(terminal, row: 1, col: 0) == "Z")
    }

    /// DECAWM reset after the flag was set: the print cancels the wrap and
    /// overwrites the last cell (xterm `dotext`, Ghostty `print`).
    @Test func decawmResetAfterFlagOverwritesLastCell() {
        let (terminal, _) = make()
        fillRow(terminal)
        terminal.feed(text: "\(csi)?7lZ")
        #expect(line(terminal, 0) == "012345678Z")
        #expect(line(terminal, 1) == "          ")
        #expect(terminal.buffer.x == 9)
    }

    @Test func wideCharacterOnLastColumnWrapsWithDecawmSet() {
        let (terminal, _) = make()
        terminal.feed(text: "012345678中")
        #expect(line(terminal, 0) == "012345678 ")
        #expect(character(terminal, row: 1, col: 0) == "中")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 2, row: 1)
    }

    /// As xterm and Ghostty: a wide character that does not fit is dropped.
    @Test func wideCharacterOnLastColumnIsDroppedWithDecawmReset() {
        let (terminal, _) = make()
        terminal.feed(text: "\(csi)?7l012345678中")
        #expect(line(terminal, 0) == "012345678 ")
        #expect(line(terminal, 1) == "          ")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 9, row: 0)
        #expect(!terminal.buffer.pendingWrap)
    }

    // MARK: - Margins

    /// xterm `dotext`: with the cursor right of the right margin, the line
    /// ends at the last column, not at the margin. The wrap goes to the left
    /// margin of the next row.
    @Test func printRightOfRightMarginContinuesToLineEnd() {
        let (terminal, _) = make()
        terminal.feed(text: "\(csi)?69h\(csi)3;6s\(csi)1;8Habcd")
        #expect(line(terminal, 0) == "       abc")
        #expect(character(terminal, row: 1, col: 2) == "d")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 3, row: 1)
    }

    /// A write to the right margin is a pending wrap, not a cursor after the
    /// margin: a line feed then scrolls the region (xterm `xtermIndex`).
    @Test func pendingWrapOnRightMarginIsInsideTheMargins() {
        let (terminal, _) = make(rows: 3)
        terminal.feed(text: "\(csi)?69h\(csi)3;6s\(csi)3;3Habcd")
        #expect(terminal.buffer.x == 5)
        #expect(terminal.buffer.pendingWrap)
        terminal.feed(text: "\n")
        // The region scrolled: row 2 is blank inside the margins.
        #expect(line(terminal, 1) == "  abcd    ")
        #expect(line(terminal, 2) == "          ")
    }

    // MARK: - Reports

    @Test func cursorPositionReportGivesTheLastColumn() {
        let (terminal, delegate) = make()
        fillRow(terminal)
        terminal.feed(text: "\(csi)6n")
        #expect(response(delegate) == "\(csi)1;10R")
        delegate.clearSentData()
        terminal.feed(text: "\(csi)?6n")
        #expect(response(delegate) == "\(csi)?1;10;1R")
        // A report does not change the flag.
        #expect(terminal.buffer.pendingWrap)
    }

    // MARK: - Save and restore

    @Test func saveAndRestoreCursorKeepTheFlag() {
        let (terminal, _) = make()
        fillRow(terminal)
        terminal.feed(text: "\(esc)7\(csi)3;3H\(esc)8")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 9, row: 0)
        #expect(terminal.buffer.pendingWrap)
        terminal.feed(text: "Z")
        #expect(character(terminal, row: 1, col: 0) == "Z")
    }

    @Test func ansiSaveAndRestoreCursorKeepTheFlag() {
        let (terminal, _) = make()
        fillRow(terminal)
        terminal.feed(text: "\(csi)s\(csi)3;3H\(csi)uZ")
        #expect(character(terminal, row: 1, col: 0) == "Z")
    }

    @Test func restoreWithoutFlagClearsIt() {
        let (terminal, _) = make()
        terminal.feed(text: "\(csi)1;10H\(esc)7")
        fillRow(terminal, row: 2)
        terminal.feed(text: "\(esc)8Z")
        #expect(line(terminal, 0) == "         Z")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 9, row: 0)
        #expect(terminal.buffer.pendingWrap)
    }

    @Test func alternateScreenRestoresTheFlag() {
        let (terminal, _) = make()
        fillRow(terminal)
        terminal.feed(text: "\(csi)?1049h\(csi)2;2Hx\(csi)?1049lZ")
        #expect(line(terminal, 0) == "0123456789")
        #expect(character(terminal, row: 1, col: 0) == "Z")
    }

    // MARK: - Combining marks and REP

    @Test func combiningMarkAttachesToTheLastCell() {
        let (terminal, _) = make()
        terminal.feed(text: "012345678e\u{301}")
        #expect(character(terminal, row: 0, col: 9) == "e\u{301}")
        #expect(character(terminal, row: 0, col: 8) == "8")
        #expect(terminal.buffer.pendingWrap)
        terminal.feed(text: "Z")
        #expect(character(terminal, row: 1, col: 0) == "Z")
    }

    @Test func combiningMarkAttachesToWideGlyphOnLastColumns() {
        let (terminal, _) = make()
        terminal.feed(text: "01234567中\u{301}")
        #expect(character(terminal, row: 0, col: 8) == "中\u{301}")
        #expect(terminal.buffer.pendingWrap)
    }

    /// A variation selector that widens the last cell does not fit: the glyph
    /// moves to the next row (as before the flag existed).
    @Test func widenedLastCellMovesToNextRow() {
        let (terminal, _) = make()
        terminal.feed(text: "012345678\u{2764}\u{FE0F}")
        #expect(character(terminal, row: 1, col: 0) == "\u{2764}\u{FE0F}")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 2, row: 1)
    }

    /// A glyph widened on the column before the last one ends on the last
    /// column: the wrap is pending.
    @Test func widenedCellEndingOnLastColumnSetsTheFlag() {
        let (terminal, _) = make()
        terminal.feed(text: "01234567\u{2764}\u{FE0F}")
        #expect(character(terminal, row: 0, col: 8) == "\u{2764}\u{FE0F}")
        #expect(terminal.buffer.x == 9)
        #expect(terminal.buffer.pendingWrap)
    }

    @Test func repeatAtPendingWrapRepeatsTheLastCell() {
        let (terminal, _) = make()
        fillRow(terminal, text: "012345678q")
        terminal.feed(text: "\(csi)2b")
        #expect(line(terminal, 0) == "012345678q")
        #expect(line(terminal, 1) == "qq        ")
    }

    @Test func repeatAfterWideGlyphRepeatsTheGlyph() {
        let (terminal, _) = make()
        terminal.feed(text: "01234567中\(csi)b")
        #expect(character(terminal, row: 1, col: 0) == "中")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 2, row: 1)
    }

    // MARK: - Resize

    @Test func resizeWiderMovesCursorAfterTheLastCell() {
        let (terminal, _) = make()
        fillRow(terminal)
        terminal.resize(cols: 12, rows: 4)
        TerminalTestHarness.assertCursor(terminal.buffer, col: 10, row: 0)
        #expect(!terminal.buffer.pendingWrap)
        terminal.feed(text: "Z")
        #expect(line(terminal, 0) == "0123456789Z ")
    }

    @Test func resizeNarrowerKeepsTheFlag() {
        let (terminal, _) = make()
        fillRow(terminal)
        terminal.resize(cols: 8, rows: 4)
        TerminalTestHarness.assertCursor(terminal.buffer, col: 7, row: 0)
        #expect(terminal.buffer.pendingWrap)
        terminal.feed(text: "Z")
        #expect(character(terminal, row: 1, col: 0) == "Z")
    }

    @Test func resizeRowsOnlyKeepsTheFlag() {
        let (terminal, _) = make()
        fillRow(terminal)
        terminal.resize(cols: 10, rows: 6)
        #expect(terminal.buffer.x == 9)
        #expect(terminal.buffer.pendingWrap)
    }

    @Test func resizeWithReflowKeepsTheCursorInRange() {
        let (terminal, _) = make(scrollback: 100)
        fillRow(terminal)
        terminal.resize(cols: 6, rows: 4)
        #expect(terminal.buffer.x < terminal.cols)
        terminal.resize(cols: 14, rows: 4)
        #expect(terminal.buffer.x < terminal.cols)
    }

    @Test func resizeAdjustsTheSavedFlag() {
        let (terminal, _) = make()
        fillRow(terminal)
        terminal.feed(text: "\(esc)7")
        terminal.resize(cols: 12, rows: 4)
        terminal.feed(text: "\(csi)3;3H\(esc)8Z")
        #expect(line(terminal, 0) == "0123456789Z ")
    }

    // MARK: - Backspace and reverse wrap

    @Test func backspaceMovesFromTheLastColumn() {
        let (terminal, _) = make()
        fillRow(terminal)
        terminal.feed(text: "\u{8}Z")
        #expect(line(terminal, 0) == "01234567Z9")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 9, row: 0)
    }

    /// With a right margin: BS goes to the column before the margin (xterm
    /// `CursorBack`). Before the flag, BS went to the margin itself.
    @Test func backspaceAtPendingWrapOnRightMargin() {
        let (terminal, _) = make()
        terminal.feed(text: "\(csi)?69h\(csi)1;5s\(csi)1;1Habcde\u{8}Z")
        #expect(line(terminal, 0) == "abcZe     ")
    }

    @Test func reverseWrapBackspaceOnlyCancelsTheWrap() {
        let (terminal, _) = make()
        terminal.feed(text: "\(csi)?45h")
        fillRow(terminal)
        terminal.feed(text: "\u{8}")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 9, row: 0)
        #expect(!terminal.buffer.pendingWrap)
        terminal.feed(text: "Z")
        #expect(line(terminal, 0) == "012345678Z")
        #expect(line(terminal, 1) == "          ")
    }

    // MARK: - Operations that cancel the wrap

    /// Each operation cancels the pending wrap: the next print does not
    /// wrap. The cursor starts on row 1, column 9 (0-based).
    @Test(arguments: [
        ("CR", "\r", 1, 0),
        ("BS", "\u{8}", 1, 8),
        ("CUU", "\u{1b}[A", 0, 9),
        ("CUD", "\u{1b}[B", 2, 9),
        ("CUF", "\u{1b}[C", 1, 9),
        ("CUB", "\u{1b}[D", 1, 8),
        ("CUP", "\u{1b}[2;10H", 1, 9),
        ("HVP", "\u{1b}[2;10f", 1, 9),
        ("CHA", "\u{1b}[10G", 1, 9),
        ("HPA", "\u{1b}[10`", 1, 9),
        ("HPR", "\u{1b}[a", 1, 9),
        ("VPA", "\u{1b}[3d", 2, 9),
        ("VPR", "\u{1b}[e", 2, 9),
        ("CNL", "\u{1b}[E", 2, 0),
        ("CPL", "\u{1b}[F", 0, 0),
        ("LF", "\n", 2, 9),
        ("VT", "\u{0b}", 2, 9),
        ("FF", "\u{0c}", 2, 9),
        ("IND", "\u{1b}D", 2, 9),
        ("NEL", "\u{1b}E", 2, 0),
        ("RI", "\u{1b}M", 0, 9),
        ("DECBI", "\u{1b}6", 1, 8),
        ("IL", "\u{1b}[L", 1, 9),
        ("DL", "\u{1b}[M", 1, 9),
        ("ICH", "\u{1b}[@", 1, 9),
        ("DCH", "\u{1b}[P", 1, 9),
        ("ECH", "\u{1b}[X", 1, 9),
        ("EL", "\u{1b}[K", 1, 9),
        ("ED", "\u{1b}[J", 1, 9),
        ("DECSEL", "\u{1b}[?K", 1, 9),
        ("DECSED", "\u{1b}[?J", 1, 9),
        ("TAB", "\t", 1, 9),
    ])
    func operationCancelsTheWrap(name: String, sequence: String, row: Int, col: Int) {
        let (terminal, _) = make()
        fillRow(terminal, row: 1)
        #expect(terminal.buffer.pendingWrap)
        terminal.feed(text: sequence)
        #expect(!terminal.buffer.pendingWrap, "\(name)")
        TerminalTestHarness.assertCursor(terminal.buffer, col: col, row: row)
        terminal.feed(text: "Z")
        #expect(character(terminal, row: row, col: col) == "Z", "\(name)")
    }

    @Test func fullResetHomesTheCursor() {
        let (terminal, _) = make()
        fillRow(terminal)
        terminal.feed(text: "\(esc)cZ")
        #expect(line(terminal, 0) == "Z         ")
    }

    // MARK: - Operations that keep the wrap

    /// SU and SD do not move the cursor (xterm `xtermScroll`, Ghostty
    /// `scrollUp`/`scrollDown`).
    @Test(arguments: [("SU", "\u{1b}[S"), ("SD", "\u{1b}[T")])
    func scrollKeepsTheWrap(name: String, sequence: String) {
        let (terminal, _) = make()
        fillRow(terminal, row: 1)
        terminal.feed(text: sequence)
        #expect(terminal.buffer.pendingWrap, "\(name)")
        terminal.feed(text: "Z")
        #expect(character(terminal, row: 2, col: 0) == "Z", "\(name)")
    }

    /// xterm `xtermColScroll` keeps `do_wrap`; Ghostty `forwardIndex` and
    /// `insertColumns`/`deleteColumns` clear it. This follows xterm.
    @Test(arguments: [("DECFI", "\u{1b}9"), ("DECIC", "\u{1b}['}"), ("DECDC", "\u{1b}['~")])
    func columnScrollKeepsTheWrap(name: String, sequence: String) {
        let (terminal, _) = make()
        fillRow(terminal, row: 1)
        terminal.feed(text: sequence)
        #expect(terminal.buffer.pendingWrap, "\(name)")
        #expect(terminal.buffer.x == 9, "\(name)")
    }

    /// xterm DECSTR does not move the cursor and keeps `do_wrap`.
    @Test func softResetKeepsTheWrap() {
        let (terminal, _) = make()
        fillRow(terminal)
        terminal.feed(text: "\(csi)!pZ")
        #expect(character(terminal, row: 1, col: 0) == "Z")
    }

    // MARK: - Tests from #782 (the report and the DECAWM state)

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

    // MARK: - Invariant

    /// `x` is always a valid column, also for sequences that ask for a
    /// column past the line.
    @Test func cursorColumnIsAlwaysValid() {
        let (terminal, _) = make()
        for sequence in ["\(csi)1;999H", "\(csi)999C", "\(csi)999G", "\(csi)999`",
                         "\(csi)999a", "\(csi)?6h\(csi)?69h\(csi)3;6s\(csi)999G",
                         "\(csi)1;999f", "0123456789012345"] {
            terminal.feed(text: sequence)
            #expect(terminal.buffer.x < terminal.cols, "\(sequence)")
        }
    }
}
