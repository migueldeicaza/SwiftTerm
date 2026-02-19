import Testing
@testable import SwiftTerm

/// Tests that CSI sequences correctly parse their numeric parameters from the
/// input stream and that the resulting `pars` array drives the expected
/// terminal behaviour.
final class CsiParameterParsingTests {
    private let esc = "\u{1b}"

    // MARK: - CUU (Cursor Up) — ESC [ Ps A

    @Test func testCursorUpDefaultParam() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[10;1H")   // row 10, col 1
        terminal.feed(text: "\(esc)[A")        // default = 1
        TerminalTestHarness.assertCursor(terminal.buffer, col: 0, row: 8) // 10-1-1 = 8
    }

    @Test func testCursorUpExplicitParam() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[10;1H")
        terminal.feed(text: "\(esc)[4A")       // up 4
        TerminalTestHarness.assertCursor(terminal.buffer, col: 0, row: 5) // 10-1-4 = 5
    }

    @Test func testCursorUpClampedToTop() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[3;1H")     // row 3
        terminal.feed(text: "\(esc)[99A")      // way past top
        TerminalTestHarness.assertCursor(terminal.buffer, col: 0, row: 0)
    }

    // MARK: - CUD (Cursor Down) — ESC [ Ps B

    @Test func testCursorDownDefaultParam() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[1;1H")
        terminal.feed(text: "\(esc)[B")        // default = 1
        TerminalTestHarness.assertCursor(terminal.buffer, col: 0, row: 1)
    }

    @Test func testCursorDownExplicitParam() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[1;1H")
        terminal.feed(text: "\(esc)[7B")       // down 7
        TerminalTestHarness.assertCursor(terminal.buffer, col: 0, row: 7)
    }

    @Test func testCursorDownClampedToBottom() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[1;1H")
        terminal.feed(text: "\(esc)[999B")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 0, row: 23)
    }

    // MARK: - CUF (Cursor Forward) — ESC [ Ps C

    @Test func testCursorForwardDefaultParam() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[1;1H")
        terminal.feed(text: "\(esc)[C")        // default = 1
        TerminalTestHarness.assertCursor(terminal.buffer, col: 1, row: 0)
    }

    @Test func testCursorForwardExplicitParam() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[1;1H")
        terminal.feed(text: "\(esc)[15C")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 15, row: 0)
    }

    @Test func testCursorForwardClampedToRight() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[1;1H")
        terminal.feed(text: "\(esc)[500C")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 79, row: 0)
    }

    // MARK: - CUB (Cursor Backward) — ESC [ Ps D

    @Test func testCursorBackwardDefaultParam() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[1;20H")    // col 20
        terminal.feed(text: "\(esc)[D")        // default = 1
        TerminalTestHarness.assertCursor(terminal.buffer, col: 18, row: 0)
    }

    @Test func testCursorBackwardExplicitParam() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[1;20H")
        terminal.feed(text: "\(esc)[5D")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 14, row: 0)
    }

    @Test func testCursorBackwardClampedToLeft() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[1;5H")
        terminal.feed(text: "\(esc)[999D")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 0, row: 0)
    }

    // MARK: - CUP (Cursor Position) — ESC [ Ps ; Ps H

    @Test func testCursorPositionBothParams() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[12;34H")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 33, row: 11)
    }

    @Test func testCursorPositionRowOnly() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[8H")       // only row, col defaults to 1
        TerminalTestHarness.assertCursor(terminal.buffer, col: 0, row: 7)
    }

    @Test func testCursorPositionNoParams() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[5;10H")    // move away first
        terminal.feed(text: "\(esc)[H")        // home
        TerminalTestHarness.assertCursor(terminal.buffer, col: 0, row: 0)
    }

    @Test func testCursorPositionZeroParamsTreatedAsOne() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[0;0H")     // 0 → treated as 1
        TerminalTestHarness.assertCursor(terminal.buffer, col: 0, row: 0)
    }

    // MARK: - EL (Erase In Line) — ESC [ Ps K

    @Test func testEraseInLineFromCursorToEnd() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
        terminal.feed(text: "ABCDEFGHIJ")
        terminal.feed(text: "\(esc)[1;4H")     // col 4
        terminal.feed(text: "\(esc)[0K")       // erase from cursor to end
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "ABC")
    }

    @Test func testEraseInLineFromStartToCursor() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
        terminal.feed(text: "ABCDEFGHIJ")
        terminal.feed(text: "\(esc)[1;4H")     // col 4 (0-based: 3)
        terminal.feed(text: "\(esc)[1K")       // erase from start to cursor
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "    EFGHIJ")
    }

    @Test func testEraseInLineEntire() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
        terminal.feed(text: "ABCDEFGHIJ")
        terminal.feed(text: "\(esc)[2K")       // erase entire line
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "")
    }

    @Test func testEraseInLineDefaultParam() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
        terminal.feed(text: "ABCDEFGHIJ")
        terminal.feed(text: "\(esc)[1;4H")
        terminal.feed(text: "\(esc)[K")        // no param → same as 0
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "ABC")
    }

    // MARK: - ECH (Erase Characters) — ESC [ Ps X

    @Test func testEraseCharsDefault() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
        terminal.feed(text: "ABCDEFGHIJ")
        terminal.feed(text: "\(esc)[1;1H")
        terminal.feed(text: "\(esc)[X")        // default = 1, erase 1 char
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: " BCDEFGHIJ")
    }

    @Test func testEraseCharsExplicit() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
        terminal.feed(text: "ABCDEFGHIJ")
        terminal.feed(text: "\(esc)[1;1H")
        terminal.feed(text: "\(esc)[5X")       // erase 5 chars
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "     FGHIJ")
    }

    // MARK: - REP (Repeat Preceding Character) — ESC [ Ps b

    @Test func testRepeatCharDefault() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
        terminal.feed(text: "X")               // preceding char
        terminal.feed(text: "\(esc)[b")        // default = 1
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "XX")
    }

    @Test func testRepeatCharExplicit() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
        terminal.feed(text: "Z")
        terminal.feed(text: "\(esc)[4b")       // repeat 4 times
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "ZZZZZ")
    }

    // MARK: - DECSTBM (Set Scroll Region) — ESC [ Ps ; Ps r

    @Test func testSetScrollRegionBothParams() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[5;20r")    // top=5, bottom=20
        #expect(terminal.buffer.scrollTop == 4)    // 1-based → 0-based
        #expect(terminal.buffer.scrollBottom == 19)
    }

    @Test func testSetScrollRegionNoParams() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[5;20r")    // set first
        terminal.feed(text: "\(esc)[r")        // reset to full screen
        #expect(terminal.buffer.scrollTop == 0)
        #expect(terminal.buffer.scrollBottom == 23)
    }

    // MARK: - ICH (Insert Characters) — ESC [ Ps @

    @Test func testInsertCharsDefault() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
        terminal.feed(text: "ABCDEFGHIJ")
        terminal.feed(text: "\(esc)[1;3H")     // col 3 (0-based: 2)
        terminal.feed(text: "\(esc)[@")        // default = 1 blank inserted
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "AB CDEFGHI")
    }

    @Test func testInsertCharsExplicit() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
        terminal.feed(text: "ABCDEFGHIJ")
        terminal.feed(text: "\(esc)[1;3H")
        terminal.feed(text: "\(esc)[3@")       // insert 3 blanks
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "AB   CDEFG")
    }

    // MARK: - DCH (Delete Characters) — ESC [ Ps P

    @Test func testDeleteCharsDefault() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
        terminal.feed(text: "ABCDEFGHIJ")
        terminal.feed(text: "\(esc)[1;3H")     // col 3 (0-based: 2)
        terminal.feed(text: "\(esc)[P")        // default = 1
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "ABDEFGHIJ")
    }

    @Test func testDeleteCharsExplicit() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
        terminal.feed(text: "ABCDEFGHIJ")
        terminal.feed(text: "\(esc)[1;3H")
        terminal.feed(text: "\(esc)[4P")       // delete 4
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "ABGHIJ")
    }

    // MARK: - Multi-digit and multi-parameter parsing

    @Test func testMultiDigitParam() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 50)
        terminal.feed(text: "\(esc)[42;17H")   // row 42, col 17
        TerminalTestHarness.assertCursor(terminal.buffer, col: 16, row: 41)
    }

    @Test func testLargeParam() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 200, rows: 100)
        terminal.feed(text: "\(esc)[100;150H")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 149, row: 99)
    }

    @Test func testZeroParamTreatedAsDefault() {
        // For most CSI commands, 0 is treated the same as 1 (the default)
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[5;5H")     // start at row 5, col 5
        terminal.feed(text: "\(esc)[0A")       // CUU with 0 → treated as 1
        TerminalTestHarness.assertCursor(terminal.buffer, col: 4, row: 3)
    }

    @Test func testSemicolonOnlyParamsDefaultToZero() {
        // ESC [ ; H — both params default to 0, treated as 1;1
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[10;10H")
        terminal.feed(text: "\(esc)[;H")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 0, row: 0)
    }
}
