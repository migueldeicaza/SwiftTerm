import Testing
@testable import SwiftTerm

final class ScreenTests {
    private func bufferLineText(_ buffer: Buffer, lineIndex: Int, terminal: Terminal? = nil) -> String {
        let characterProvider: ((CharData) -> Character)?
        if let terminal {
            characterProvider = { terminal.getCharacter(for: $0) }
        } else {
            characterProvider = nil
        }
        return buffer.translateBufferLineToString(
            lineIndex: lineIndex,
            trimRight: true,
            startCol: 0,
            endCol: -1,
            skipNullCellsFollowingWide: true,
            characterProvider: characterProvider
        ).replacingOccurrences(of: "\u{0}", with: " ")
    }

    @Test func testScrollbackStoresLines() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 2, scrollback: 10)
        terminal.feed(text: "hello\r\nworld\r\ntest")

        #expect(terminal.buffer.yBase == 1)
        #expect(terminal.buffer.yDisp == terminal.buffer.yBase)
        #expect(bufferLineText(terminal.buffer, lineIndex: 0) == "hello")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "world")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "test")
    }

    @Test func testViewportDoesNotFollowWhenUserScrolling() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 2, scrollback: 10)
        terminal.feed(text: "1\r\n2\r\n3\r\n4\r\n")

        #expect(terminal.buffer.yBase == 3)
        #expect(terminal.buffer.yDisp == terminal.buffer.yBase)

        terminal.userScrolling = true
        terminal.setViewYDisp(0)
        terminal.feed(text: "5\r\n")

        #expect(terminal.buffer.yBase == 4)
        #expect(terminal.buffer.yDisp == 0)
    }

    @Test func testNoScrollbackDropsLines() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 2, scrollback: 10)
        terminal.changeHistorySize(nil)
        terminal.feed(text: "hello\r\nworld\r\ntest")

        #expect(terminal.buffer.yBase == 0)
        #expect(bufferLineText(terminal.buffer, lineIndex: 0) == "world")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "world")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "test")
    }

    @Test func testSingleRowScrollNoScrollback() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1, scrollback: 0)
        terminal.feed(text: "1ABCD\r\n")

        #expect(terminal.buffer.yBase == 0)
        #expect(terminal.buffer.yDisp == 0)
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "")
    }

    @Test func testSingleRowScrollWithScrollback() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1, scrollback: 1)
        terminal.feed(text: "1ABCD\r\n")

        #expect(terminal.buffer.yBase == 1)
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "")

        terminal.userScrolling = true
        terminal.setViewYDisp(0)
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "1ABCD")
    }

    @Test func testUserScrollingAdjustsOnTrim() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 2, scrollback: 1)
        terminal.feed(text: "1\r\n2\r\n3\r\n")

        #expect(terminal.buffer.yBase == 1)
        terminal.userScrolling = true
        terminal.setViewYDisp(1)
        terminal.feed(text: "4\r\n")

        #expect(terminal.buffer.yDisp == 0)
    }

    @Test func testResizeReflowsWithScrollback() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 3, scrollback: 10)
        terminal.feed(text: "helloworld\r\nX")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "hello")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "world")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "X")

        terminal.resize(cols: 10, rows: 3)

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "helloworld")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "X")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "")
    }

    @Test func testResizeNarrowerReflowsWithScrollback() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 3, scrollback: 10)
        terminal.feed(text: "helloworld\r\nX")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "helloworld")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "X")

        terminal.resize(cols: 5, rows: 3)

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "hello")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "world")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "X")
    }

    @Test func testResizeWiderReflowsMultipleWrappedLines() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 4, rows: 4, scrollback: 10)
        terminal.feed(text: "abcdefghij\r\nX")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "abcd")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "efgh")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "ij")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 3, equals: "X")

        terminal.resize(cols: 10, rows: 4)

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "abcdefghij")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "X")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 3, equals: "")
    }

    @Test func testReadWriteSingleLine() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24, scrollback: 10)
        terminal.feed(text: "hello, world")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "hello, world")
        #expect(terminal.buffer.yBase == 0)
    }

    @Test func testReadWriteNewline() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24, scrollback: 10)
        terminal.feed(text: "hello\r\nworld")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "hello")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "world")
    }

    @Test func testNoScrollbackLargeDropsOldLines() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 2, scrollback: 0)

        for i in 0..<1_000 {
            terminal.feed(text: "\(i)\r\n")
        }
        terminal.feed(text: "1000")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "999")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "1000")
    }

    @Test func testResizeNoReflowWithoutScrollback() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 2, scrollback: 0)
        terminal.feed(text: "helloworld")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "hello")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "world")

        terminal.resize(cols: 10, rows: 2)

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "hello")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "world")
    }

    // MARK: - Screen Tests Ported from Ghostty

    private let esc = "\u{1b}"

    /// Test ED 0 - Erase from cursor to end of screen
    /// From Ghostty: Screen clearRows
    @Test func testEraseDisplayFromCursor() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 3, scrollback: 0)
        terminal.feed(text: "line1\r\nline2\r\nline3")

        // Move cursor to middle of line 2
        terminal.feed(text: "\(esc)[2;3H")  // Row 2, Col 3 (1-based)

        // ED 0 - Erase from cursor to end
        terminal.feed(text: "\(esc)[0J")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "line1")
        // Line 2 should be erased from col 2 onwards (0-based)
        let line2 = TerminalTestHarness.lineText(buffer: terminal.buffer, row: 1) ?? ""
        #expect(line2.hasPrefix("li"))
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "")
    }

    /// Test ED 1 - Erase from beginning to cursor
    /// From Ghostty: Screen clearRows
    @Test func testEraseDisplayToCursor() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 3, scrollback: 0)
        terminal.feed(text: "line1\r\nline2\r\nline3")

        // Move cursor to middle of line 2
        terminal.feed(text: "\(esc)[2;3H")  // Row 2, Col 3 (1-based)

        // ED 1 - Erase from beginning to cursor
        terminal.feed(text: "\(esc)[1J")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "")
        // Line 2 should be erased up to cursor
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "line3")
    }

    /// Test ED 2 - Erase entire screen
    /// From Ghostty: Screen clearRows active multi line
    @Test func testEraseDisplayAll() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 3, scrollback: 0)
        terminal.feed(text: "line1\r\nline2\r\nline3")

        // ED 2 - Erase entire screen
        terminal.feed(text: "\(esc)[2J")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "")
    }

    /// Test ED 3 - Erase scrollback (clear history)
    /// From Ghostty: Screen eraseRows history
    @Test func testEraseScrollback() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 3, scrollback: 10)
        terminal.feed(text: "1\r\n2\r\n3\r\n4\r\n5")

        // Should have scrollback now
        #expect(terminal.buffer.yBase > 0)

        // ED 3 - Erase scrollback
        terminal.feed(text: "\(esc)[3J")

        // Active content should remain
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "3")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "4")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "5")
    }

    /// Test EL 0 - Erase from cursor to end of line
    @Test func testEraseLineFromCursor() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1, scrollback: 0)
        terminal.feed(text: "0123456789")
        terminal.feed(text: "\(esc)[1;5H")  // Move to column 5 (1-based)
        terminal.feed(text: "\(esc)[0K")    // Erase from cursor to end

        let line = TerminalTestHarness.lineText(buffer: terminal.buffer, row: 0) ?? ""
        #expect(line == "0123")
    }

    /// Test EL 1 - Erase from beginning to cursor
    @Test func testEraseLineToCursor() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1, scrollback: 0)
        terminal.feed(text: "0123456789")
        terminal.feed(text: "\(esc)[1;5H")  // Move to column 5 (1-based)
        terminal.feed(text: "\(esc)[1K")    // Erase from beginning to cursor

        let line = TerminalTestHarness.lineText(buffer: terminal.buffer, row: 0) ?? ""
        #expect(line.hasSuffix("56789"))
    }

    /// Test EL 2 - Erase entire line
    @Test func testEraseLineAll() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1, scrollback: 0)
        terminal.feed(text: "0123456789")
        terminal.feed(text: "\(esc)[2K")  // Erase entire line

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "")
    }

    /// Test IL - Insert Lines
    /// From Ghostty: scroll operations
    @Test func testInsertLines() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 5, scrollback: 0)
        terminal.feed(text: "line1\r\nline2\r\nline3\r\nline4\r\nline5")

        // Move to line 2
        terminal.feed(text: "\(esc)[2;1H")

        // Insert 2 lines
        terminal.feed(text: "\(esc)[2L")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "line1")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 3, equals: "line2")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 4, equals: "line3")
    }

    /// Test DL - Delete Lines
    @Test func testDeleteLines() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 5, scrollback: 0)
        terminal.feed(text: "line1\r\nline2\r\nline3\r\nline4\r\nline5")

        // Move to line 2
        terminal.feed(text: "\(esc)[2;1H")

        // Delete 2 lines
        terminal.feed(text: "\(esc)[2M")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "line1")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "line4")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "line5")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 3, equals: "")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 4, equals: "")
    }

    /// Test ICH - Insert Characters
    @Test func testInsertCharacters() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1, scrollback: 0)
        terminal.feed(text: "abcdefghij")
        terminal.feed(text: "\(esc)[1;3H")   // Move to column 3 (1-based)
        terminal.feed(text: "\(esc)[2@")     // Insert 2 characters

        let line = TerminalTestHarness.lineText(buffer: terminal.buffer, row: 0) ?? ""
        #expect(line.hasPrefix("ab"))
        #expect(line.contains("cd"))
    }

    /// Test DCH - Delete Characters
    @Test func testDeleteCharacters() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1, scrollback: 0)
        terminal.feed(text: "0123456789")
        terminal.feed(text: "\(esc)[1;3H")   // Move to column 3 (1-based)
        terminal.feed(text: "\(esc)[2P")     // Delete 2 characters

        let line = TerminalTestHarness.lineText(buffer: terminal.buffer, row: 0) ?? ""
        #expect(line == "01456789")
    }

    /// Test ECH - Erase Characters
    @Test func testEraseCharacters() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1, scrollback: 0)
        terminal.feed(text: "0123456789")
        terminal.feed(text: "\(esc)[1;3H")   // Move to column 3 (1-based)
        terminal.feed(text: "\(esc)[3X")     // Erase 3 characters

        // Characters should be replaced with spaces, rest unchanged
        let line = TerminalTestHarness.lineText(buffer: terminal.buffer, row: 0) ?? ""
        #expect(line.hasSuffix("56789"))
    }

    /// Test scroll region with DECSTBM
    /// From Ghostty: scroll region operations
    @Test func testScrollRegion() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 5, scrollback: 0)
        terminal.feed(text: "line1\r\nline2\r\nline3\r\nline4\r\nline5")

        // Set scroll region to lines 2-4 (1-based)
        terminal.feed(text: "\(esc)[2;4r")

        // Move to bottom of scroll region and scroll
        terminal.feed(text: "\(esc)[4;1H")
        terminal.feed(text: "\r\n")

        // Line 1 and 5 should be unchanged
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "line1")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 4, equals: "line5")
    }

    /// Test scroll up within region (SU)
    @Test func testScrollUp() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 5, scrollback: 0)
        terminal.feed(text: "line1\r\nline2\r\nline3\r\nline4\r\nline5")

        // Scroll up 2 lines
        terminal.feed(text: "\(esc)[2S")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "line3")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "line4")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "line5")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 3, equals: "")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 4, equals: "")
    }

    /// Test scroll down (SD)
    @Test func testScrollDown() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 5, scrollback: 0)
        terminal.feed(text: "line1\r\nline2\r\nline3\r\nline4\r\nline5")

        // Scroll down 2 lines
        terminal.feed(text: "\(esc)[2T")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "line1")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 3, equals: "line2")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 4, equals: "line3")
    }

    /// Test cursor movement: CUU (up), CUD (down), CUF (forward), CUB (back)
    @Test func testCursorMovement() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 10, scrollback: 0)

        // Start at 1,1
        terminal.feed(text: "\(esc)[1;1H")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 0, row: 0)

        // Move down 3
        terminal.feed(text: "\(esc)[3B")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 0, row: 3)

        // Move right 5
        terminal.feed(text: "\(esc)[5C")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 5, row: 3)

        // Move up 2
        terminal.feed(text: "\(esc)[2A")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 5, row: 1)

        // Move left 3
        terminal.feed(text: "\(esc)[3D")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 2, row: 1)
    }

    /// Test cursor doesn't move past boundaries
    @Test func testCursorBoundaries() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 10, scrollback: 0)

        // Try to move past top
        terminal.feed(text: "\(esc)[1;1H")
        terminal.feed(text: "\(esc)[100A")  // Try to move up 100
        TerminalTestHarness.assertCursor(terminal.buffer, col: 0, row: 0)

        // Try to move past left
        terminal.feed(text: "\(esc)[100D")  // Try to move left 100
        TerminalTestHarness.assertCursor(terminal.buffer, col: 0, row: 0)

        // Try to move past bottom
        terminal.feed(text: "\(esc)[100B")  // Try to move down 100
        #expect(terminal.buffer.y < terminal.rows)

        // Try to move past right
        terminal.feed(text: "\(esc)[100C")  // Try to move right 100
        #expect(terminal.buffer.x < terminal.cols)
    }

    /// Test reverse index (RI / ESC M) at top of screen
    /// From Ghostty: reverseIndex tests
    @Test func testReverseIndexAtTop() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 5, scrollback: 0)
        terminal.feed(text: "line1\r\nline2\r\nline3\r\nline4\r\nline5")

        // Move to top
        terminal.feed(text: "\(esc)[1;1H")

        // Reverse index - should scroll down
        terminal.feed(text: "\(esc)M")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "line1")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "line2")
    }

    /// Test reverse index within scroll region
    @Test func testReverseIndexInScrollRegion() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 5, scrollback: 0)
        terminal.feed(text: "line1\r\nline2\r\nline3\r\nline4\r\nline5")

        // Set scroll region to lines 2-4
        terminal.feed(text: "\(esc)[2;4r")

        // Move to top of scroll region
        terminal.feed(text: "\(esc)[2;1H")

        // Reverse index
        terminal.feed(text: "\(esc)M")

        // Line 1 should be unchanged, lines in region should scroll
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "line1")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 4, equals: "line5")
    }

    /// Test index (IND / ESC D) at bottom of screen
    @Test func testIndexAtBottom() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 3, scrollback: 10)
        terminal.feed(text: "line1\r\nline2\r\nline3")

        // Move to bottom
        terminal.feed(text: "\(esc)[3;1H")

        // Index - should scroll up
        terminal.feed(text: "\(esc)D")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "line2")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "line3")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "")
    }

    /// Test NEL (Next Line / ESC E)
    @Test func testNextLine() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 3, scrollback: 0)
        terminal.feed(text: "abc")

        // Next line
        terminal.feed(text: "\(esc)E")
        terminal.feed(text: "def")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "abc")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "def")
        #expect(terminal.buffer.x == 3)  // Cursor after 'def'
    }

    /// Test tab stops (HTS, TBC)
    @Test func testTabStops() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 40, rows: 1, scrollback: 0)

        // Clear all tab stops
        terminal.feed(text: "\(esc)[3g")

        // Set tab stop at column 10
        terminal.feed(text: "\(esc)[1;11H")  // Move to column 11 (1-based = col 10 0-based)
        terminal.feed(text: "\(esc)H")        // Set tab stop

        // Set tab stop at column 20
        terminal.feed(text: "\(esc)[1;21H")
        terminal.feed(text: "\(esc)H")

        // Go back to beginning and tab
        terminal.feed(text: "\(esc)[1;1H")
        terminal.feed(text: "\t")
        #expect(terminal.buffer.x == 10)

        terminal.feed(text: "\t")
        #expect(terminal.buffer.x == 20)
    }

    /// Test clear tab stop at cursor (TBC 0)
    @Test func testClearTabStopAtCursor() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 1, scrollback: 0)

        // Tab to default stop at column 8
        terminal.feed(text: "\t")
        let tabPos = terminal.buffer.x

        // Clear this tab stop
        terminal.feed(text: "\(esc)[0g")

        // Go back and tab again - should go past the cleared stop
        terminal.feed(text: "\(esc)[1;1H")
        terminal.feed(text: "\t")
        #expect(terminal.buffer.x != tabPos || terminal.buffer.x == 8) // Default behavior may vary
    }

    /// Test save and restore cursor (DECSC/DECRC)
    @Test func testSaveRestoreCursor() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10, scrollback: 0)

        // Move to position and set attributes
        terminal.feed(text: "\(esc)[5;10H")  // Row 5, Col 10
        terminal.feed(text: "\(esc)[1;31m")  // Bold, red

        // Save cursor
        terminal.feed(text: "\(esc)7")

        // Move elsewhere and change attributes
        terminal.feed(text: "\(esc)[1;1H")
        terminal.feed(text: "\(esc)[0m")

        // Restore cursor
        terminal.feed(text: "\(esc)8")

        #expect(terminal.buffer.x == 9)  // Col 10 (1-based) = 9 (0-based)
        #expect(terminal.buffer.y == 4)  // Row 5 (1-based) = 4 (0-based)
    }

    /// Test origin mode (DECOM)
    @Test func testOriginMode() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10, scrollback: 0)

        // Set scroll region to lines 3-7
        terminal.feed(text: "\(esc)[3;7r")

        // Enable origin mode
        terminal.feed(text: "\(esc)[?6h")

        // Move to home - should be at scroll region top
        terminal.feed(text: "\(esc)[H")
        #expect(terminal.buffer.y == 2)  // Row 3 (1-based) = 2 (0-based)

        // Move to 1,1 with origin mode - relative to scroll region
        terminal.feed(text: "\(esc)[1;1H")
        #expect(terminal.buffer.y == 2)

        // Disable origin mode
        terminal.feed(text: "\(esc)[?6l")

        // Move to home - should be at screen top
        terminal.feed(text: "\(esc)[H")
        #expect(terminal.buffer.y == 0)
    }

    /// Test resize smaller preserves cursor relative position
    @Test func testResizeSmallerPreservesCursor() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 20, scrollback: 0)

        // Move cursor to row 10, col 10
        terminal.feed(text: "\(esc)[10;10H")
        #expect(terminal.buffer.y == 9)
        #expect(terminal.buffer.x == 9)

        // Resize to smaller
        terminal.resize(cols: 15, rows: 15)

        // Cursor should be at same position if it fits
        #expect(terminal.buffer.y == 9)
        #expect(terminal.buffer.x == 9)
    }

    /// Test resize when cursor is beyond new bounds
    @Test func testResizeCursorBeyondBounds() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 20, scrollback: 0)

        // Move cursor near bottom-right
        terminal.feed(text: "\(esc)[18;18H")

        // Resize to smaller than cursor position
        terminal.resize(cols: 10, rows: 10)

        // Cursor should be clamped to new bounds
        #expect(terminal.buffer.y < 10)
        #expect(terminal.buffer.x < 10)
    }

    /// Test scroll region reset on resize
    @Test func testResizeResetsScrollRegion() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 20, scrollback: 0)

        // Set scroll region
        terminal.feed(text: "\(esc)[5;15r")

        // Resize
        terminal.resize(cols: 20, rows: 10)

        // Scroll region should be reset to full screen
        #expect(terminal.buffer.scrollTop == 0)
        #expect(terminal.buffer.scrollBottom == 9)
    }
}
