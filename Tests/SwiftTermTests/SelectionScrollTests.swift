//
//  SelectionScrollTests.swift
//
//  Selections are anchored to absolute buffer rows.  When an application
//  scrolls a region that does not start at the top of the screen, lines are
//  shifted in place rather than pushed into the scrollback, so those rows come
//  to hold different text.  The selection has to be translated to match.
//

import Foundation
import XCTest

@testable import SwiftTerm

final class SelectionScrollTests: XCTestCase {

    private func makeTerminal (rows: Int = 10, cols: Int = 40) -> Terminal {
        let headless = HeadlessTerminal (queue: nil) { _ in }
        headless.terminal.resize (cols: cols, rows: rows)
        return headless.terminal
    }

    private func paintLines (_ terminal: Terminal, count: Int) {
        for i in 1...count {
            terminal.feed (text: "\u{1b}[\(i);1HLINE_\(i)")
        }
    }

    private func selectedText (_ selection: SelectionService) -> String {
        selection.getSelectedText ().trimmingCharacters (in: .whitespaces)
    }

    /// Scrolling a region that starts below the top of the screen shifts lines
    /// in place; the selection must move with its text.
    func testSelectionFollowsTextOnPartialRegionScroll () {
        let terminal = makeTerminal ()
        terminal.feed (text: "\u{1b}[?1049h")
        paintLines (terminal, count: 10)

        let selection = SelectionService (terminal: terminal)
        selection.setSelection (start: Position (col: 0, row: 4), end: Position (col: 10, row: 4))
        XCTAssertEqual (selectedText (selection), "LINE_5")

        // Region rows 2...9, linefeed on its bottom row.
        terminal.feed (text: "\u{1b}[2;9r\u{1b}[9;1H\r\n\u{1b}[1;10r")

        XCTAssertEqual (terminal.buffer.yDisp, 0, "an in-place scroll does not move the viewport")
        XCTAssertEqual (selectedText (selection), "LINE_5", "selection should follow its text")
    }

    /// A selection that scrolls out of the region no longer refers to anything.
    func testSelectionClearedWhenScrolledOutOfRegion () {
        let terminal = makeTerminal ()
        terminal.feed (text: "\u{1b}[?1049h")
        paintLines (terminal, count: 10)

        let selection = SelectionService (terminal: terminal)
        // Row 1 (0-based) is the top row of the 2...9 region below.
        selection.setSelection (start: Position (col: 0, row: 1), end: Position (col: 10, row: 1))
        XCTAssertEqual (selectedText (selection), "LINE_2")

        terminal.feed (text: "\u{1b}[2;9r\u{1b}[9;1H\r\n\u{1b}[1;10r")

        XCTAssertFalse (selection.active, "selection scrolled off the top of the region")
    }

    /// Rows outside the scrolled region do not move, so neither does a
    /// selection anchored to them.
    func testSelectionOutsideRegionIsUntouched () {
        let terminal = makeTerminal ()
        terminal.feed (text: "\u{1b}[?1049h")
        paintLines (terminal, count: 10)

        let selection = SelectionService (terminal: terminal)
        // Row 0 sits above the 2...9 region.
        selection.setSelection (start: Position (col: 0, row: 0), end: Position (col: 10, row: 0))
        XCTAssertEqual (selectedText (selection), "LINE_1")

        terminal.feed (text: "\u{1b}[2;9r\u{1b}[9;1H\r\n\u{1b}[1;10r")

        XCTAssertTrue (selection.active)
        XCTAssertEqual (selectedText (selection), "LINE_1")
    }

    /// Full-screen scrolls push lines into the scrollback and advance yDisp, so
    /// absolute rows stay valid and no translation should happen.
    func testFullScreenScrollLeavesSelectionAlone () {
        let terminal = makeTerminal ()
        terminal.feed (text: "\u{1b}[?1049h")
        paintLines (terminal, count: 9)

        let selection = SelectionService (terminal: terminal)
        selection.setSelection (start: Position (col: 0, row: 4), end: Position (col: 10, row: 4))
        XCTAssertEqual (selectedText (selection), "LINE_5")

        terminal.feed (text: "\u{1b}[1;10r\u{1b}[10;1H\r\n\u{1b}[1;10r")

        XCTAssertEqual (terminal.buffer.yDisp, 1)
        XCTAssertEqual (selectedText (selection), "LINE_5")
    }

    // MARK: - Other in-place row movements

    /// ESC M inside a scroll region shifts rows down in place.
    func testSelectionFollowsTextOnReverseIndex () {
        let terminal = makeTerminal ()
        terminal.feed (text: "\u{1b}[?1049h")
        paintLines (terminal, count: 10)

        let selection = SelectionService (terminal: terminal)
        selection.setSelection (start: Position (col: 0, row: 4), end: Position (col: 10, row: 4))
        XCTAssertEqual (selectedText (selection), "LINE_5")

        // Region rows 2...9, cursor at its top row, then reverse index.
        terminal.feed (text: "\u{1b}[2;9r\u{1b}[2;1H\u{1b}M\u{1b}[1;10r")

        XCTAssertEqual (selectedText (selection), "LINE_5", "selection should follow text pushed down")
    }

    /// CSI L inserts blank lines, pushing the rows below the cursor down.
    func testSelectionFollowsTextOnInsertLines () {
        let terminal = makeTerminal ()
        terminal.feed (text: "\u{1b}[?1049h")
        paintLines (terminal, count: 10)

        let selection = SelectionService (terminal: terminal)
        selection.setSelection (start: Position (col: 0, row: 4), end: Position (col: 10, row: 4))
        XCTAssertEqual (selectedText (selection), "LINE_5")

        // Insert one line at row 3, pushing LINE_3 onwards down.
        terminal.feed (text: "\u{1b}[3;1H\u{1b}[1L")

        XCTAssertEqual (selectedText (selection), "LINE_5")
    }

    /// CSI M deletes lines, pulling the rows below the cursor up.
    func testSelectionFollowsTextOnDeleteLines () {
        let terminal = makeTerminal ()
        terminal.feed (text: "\u{1b}[?1049h")
        paintLines (terminal, count: 10)

        let selection = SelectionService (terminal: terminal)
        selection.setSelection (start: Position (col: 0, row: 4), end: Position (col: 10, row: 4))
        XCTAssertEqual (selectedText (selection), "LINE_5")

        // Delete one line at row 3, pulling LINE_4 onwards up.
        terminal.feed (text: "\u{1b}[3;1H\u{1b}[1M")

        XCTAssertEqual (selectedText (selection), "LINE_5")
    }

    /// CSI S scrolls the region up without using scrollback.
    func testSelectionFollowsTextOnScrollUp () {
        let terminal = makeTerminal ()
        terminal.feed (text: "\u{1b}[?1049h")
        paintLines (terminal, count: 10)

        let selection = SelectionService (terminal: terminal)
        selection.setSelection (start: Position (col: 0, row: 4), end: Position (col: 10, row: 4))
        XCTAssertEqual (selectedText (selection), "LINE_5")

        terminal.feed (text: "\u{1b}[2;9r\u{1b}[1S\u{1b}[1;10r")

        XCTAssertEqual (selectedText (selection), "LINE_5")
    }

    /// CSI T scrolls the region down without using scrollback.
    func testSelectionFollowsTextOnScrollDown () {
        let terminal = makeTerminal ()
        terminal.feed (text: "\u{1b}[?1049h")
        paintLines (terminal, count: 10)

        let selection = SelectionService (terminal: terminal)
        selection.setSelection (start: Position (col: 0, row: 4), end: Position (col: 10, row: 4))
        XCTAssertEqual (selectedText (selection), "LINE_5")

        terminal.feed (text: "\u{1b}[2;9r\u{1b}[1T\u{1b}[1;10r")

        XCTAssertEqual (selectedText (selection), "LINE_5")
    }

    /// A column-restricted scroll cannot move a row-based selection safely.
    func testSelectionClearedOnColumnRestrictedScroll () {
        let terminal = makeTerminal ()
        terminal.feed (text: "\u{1b}[?1049h")
        paintLines (terminal, count: 10)

        let selection = SelectionService (terminal: terminal)
        selection.setSelection (start: Position (col: 1, row: 4), end: Position (col: 4, row: 4))

        terminal.feed (text: "\u{1b}[?69h\u{1b}[2;4s\u{1b}[1S")

        XCTAssertFalse (selection.active)
    }

    /// Recycling a full line buffer shifts all absolute row indices up.
    func testSelectionFollowsTextWhenFullScreenBufferIsFull () {
        let terminal = makeTerminal (rows: 25)
        terminal.feed (text: "\u{1b}[?1049h")
        paintLines (terminal, count: 25)

        let selection = SelectionService (terminal: terminal)
        selection.setSelection (start: Position (col: 0, row: 4), end: Position (col: 10, row: 4))
        XCTAssertEqual (selectedText (selection), "LINE_5")

        terminal.feed (text: "\u{1b}[25;1H\r\n")

        XCTAssertEqual (terminal.buffer.yDisp, 0)
        XCTAssertEqual (selection.start.row, 3)
        XCTAssertEqual (selectedText (selection), "LINE_5")
    }

    /// A selection that crosses the moved region cannot stay contiguous.
    func testSelectionClearedWhenItCrossesScrollRegion () {
        let terminal = makeTerminal ()
        terminal.feed (text: "\u{1b}[?1049h")
        paintLines (terminal, count: 10)

        let selection = SelectionService (terminal: terminal)
        selection.setSelection (start: Position (col: 0, row: 0), end: Position (col: 10, row: 9))

        terminal.feed (text: "\u{1b}[2;9r\u{1b}[9;1H\r\n\u{1b}[1;10r")

        XCTAssertFalse (selection.active)
    }

    /// Word-mode drags use a saved anchor that must move with the selection.
    func testWordSelectionAnchorFollowsText () {
        let terminal = makeTerminal ()
        terminal.feed (text: "\u{1b}[?1049h")
        paintLines (terminal, count: 10)

        let selection = SelectionService (terminal: terminal)
        selection.selectWordOrExpression (at: Position (col: 2, row: 4), in: terminal.buffer)
        XCTAssertEqual (selectedText (selection), "LINE_5")

        terminal.feed (text: "\u{1b}[2;9r\u{1b}[9;1H\r\n\u{1b}[1;10r")

        XCTAssertEqual (selection.wordSelectionAnchor?.start.row, 3)
        XCTAssertEqual (selection.wordSelectionAnchor?.end.row, 3)
        selection.dragExtend (bufferPosition: Position (col: 2, row: 3))
        XCTAssertEqual (selectedText (selection), "LINE_5")
    }

    /// The iOS selection pivot must move with the selected row.
    func testSelectionPivotFollowsText () {
        let terminal = makeTerminal ()
        terminal.feed (text: "\u{1b}[?1049h")
        paintLines (terminal, count: 10)

        let selection = SelectionService (terminal: terminal)
        selection.setSelection (start: Position (col: 0, row: 4), end: Position (col: 10, row: 4))
        selection.pivot = selection.end

        terminal.feed (text: "\u{1b}[2;9r\u{1b}[9;1H\r\n\u{1b}[1;10r")

        XCTAssertEqual (selection.pivot?.row, 3)
        XCTAssertEqual (selectedText (selection), "LINE_5")
    }
}
