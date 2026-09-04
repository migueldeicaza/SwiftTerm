import Foundation
import Testing

@testable import SwiftTerm

@Suite final class RegionScrollFastPathTests {
    private let esc = "\u{1b}"

    private func makeTerminal(cols: Int = 80, rows: Int = 25, scrollback: Int = 100) -> Terminal {
        TerminalTestHarness.makeTerminal(cols: cols, rows: rows, scrollback: scrollback).terminal
    }

    private func paintNumberedRows(_ terminal: Terminal) {
        for row in 1...terminal.rows {
            terminal.feed(text: "\(esc)[\(row);1HROW\(String(format: "%02d", row))")
        }
    }

    private func visibleRows(_ terminal: Terminal) -> [String] {
        TerminalTestHarness.visibleLinesText(buffer: terminal.buffer, terminal: terminal)
    }

    private func feedBottomLineScrolls(_ terminal: Terminal, count: Int) {
        for _ in 0..<count {
            terminal.feed(text: "y\n")
        }
    }

    @Test func bottomAlternateRegionScrollsInPlace() {
        let terminal = makeTerminal()
        terminal.feed(text: "\(esc)[?1049h")
        paintNumberedRows(terminal)
        terminal.feed(text: "\(esc)[1;24r\(esc)[24;1H")
        terminal.clearUpdateRange()

        feedBottomLineScrolls(terminal, count: 3)

        let expected = (4...23).map { "ROW\(String(format: "%02d", $0))" }
            + ["yOW24", " y", "  y", "", "ROW25"]
        #expect(visibleRows(terminal) == expected)
        #expect(terminal.getUpdateRange()?.startY == 0)
        #expect(terminal.getUpdateRange()?.endY == 23)
        #expect(terminal.getScrollInvariantUpdateRange()?.startY == 0)
        #expect(terminal.getScrollInvariantUpdateRange()?.endY == 23)
    }

    @Test func topRegionLeavesFirstRowAndScrollbackUntouched() {
        let terminal = makeTerminal()
        paintNumberedRows(terminal)
        terminal.feed(text: "\(esc)[2;25r\(esc)[25;1H")
        let originalCount = terminal.buffer.lines.count
        let originalYBase = terminal.buffer.yBase

        feedBottomLineScrolls(terminal, count: 3)

        let expected = ["ROW01"]
            + (5...24).map { "ROW\(String(format: "%02d", $0))" }
            + ["yOW25", " y", "  y", ""]
        #expect(visibleRows(terminal) == expected)
        #expect(terminal.buffer.lines.count == originalCount)
        #expect(terminal.buffer.yBase == originalYBase)
    }

    @Test func topAnchoredMainRegionStillSplicesIntoScrollback() {
        let terminal = makeTerminal()
        paintNumberedRows(terminal)
        terminal.feed(text: "\(esc)[1;24r\(esc)[24;1H")
        let originalCount = terminal.buffer.lines.count
        let originalYBase = terminal.buffer.yBase
        let originalFirstLine = terminal.buffer.lines[0]

        feedBottomLineScrolls(terminal, count: 1)

        #expect(terminal.buffer.lines.count == originalCount + 1)
        #expect(terminal.buffer.yBase == originalYBase + 1)
        #expect(terminal.buffer.lines[0] === originalFirstLine)
    }

    @Test func activeSelectionUsesGeneralRegionPath() {
        let terminal = makeTerminal()
        terminal.feed(text: "\(esc)[?1049h")
        paintNumberedRows(terminal)
        let selection = SelectionService(terminal: terminal)
        selection.setSelection(start: Position(col: 0, row: 4),
                               end: Position(col: 5, row: 4))
        terminal.feed(text: "\(esc)[1;24r\(esc)[24;1H")

        feedBottomLineScrolls(terminal, count: 3)

        #expect(selection.active)
        #expect(selection.start.row == 1)
        #expect(selection.getSelectedText().trimmingCharacters(in: .whitespaces) == "ROW05")
    }

    @Test func userScrollingPreservesAlternateViewport() {
        let terminal = makeTerminal()
        terminal.feed(text: "\(esc)[?1049h")
        paintNumberedRows(terminal)
        terminal.feed(text: "\(esc)[1;24r\(esc)[24;1H")
        terminal.userScrolling = true
        let originalYDisp = terminal.buffer.yDisp

        feedBottomLineScrolls(terminal, count: 3)

        #expect(terminal.buffer.yDisp == originalYDisp)
        #expect(terminal.buffer.yDisp == 0)
    }

    @Test func marginModeKeepsUsingColumnRestrictedCopy() {
        let terminal = makeTerminal(cols: 80, rows: 4, scrollback: 0)
        terminal.feed(text: "\(esc)[?1049h")
        for row in 1...4 {
            let scalar = UnicodeScalar(64 + row)!
            terminal.feed(text: "\(esc)[\(row);1H\(String(repeating: Character(scalar), count: 80))")
        }
        terminal.feed(text: "\(esc)[1;4r\(esc)[?69h\(esc)[10;70s\(esc)[4;10H\n")

        let lines = terminal.buffer.lines
        for row in 0..<3 {
            #expect(lines[row][0].code == Int32(65 + row))
            #expect(lines[row][9].code == Int32(66 + row))
            #expect(lines[row][69].code == Int32(66 + row))
            #expect(lines[row][70].code == Int32(65 + row))
        }
        #expect(lines[3][0].code == 68)
        #expect(lines[3][9].code == 0)
        #expect(lines[3][69].code == 0)
        #expect(lines[3][70].code == 68)
    }

    @Test func wrappedRegionScrollCarriesBottomBidiState() {
        let terminal = makeTerminal(cols: 8, rows: 5, scrollback: 0)
        terminal.feed(text: "\(esc)[?1049h\(esc)[1;4r")
        let expectedState = BidiPresentationState(supportMode: .explicit,
                                                  autodetectDirection: false,
                                                  fallbackDirection: .rightToLeft)
        terminal.buffer.lines[3].bidiState = expectedState
        terminal.feed(text: "\(esc)[4;8HA")

        terminal.feed(text: "B")

        #expect(terminal.buffer.lines[3].isWrapped)
        #expect(terminal.buffer.lines[3].bidiState == expectedState)
    }

    @Test func borrowingAndNonBorrowingRangeUpdatesMatch() {
        let owned = makeTerminal(rows: 5)
        let borrowed = makeTerminal(rows: 5)
        owned.feed(text: "1\r\n2\r\n3\r\n4\r\n5\r\n6")
        borrowed.feed(text: "1\r\n2\r\n3\r\n4\r\n5\r\n6")
        owned.clearUpdateRange()
        borrowed.clearUpdateRange()

        owned.updateRange(startLine: 1, endLine: 3)
        borrowed.updateRange(borrowing: borrowed.buffer, startLine: 1, endLine: 3)

        #expect(owned.getUpdateRange()?.startY == borrowed.getUpdateRange()?.startY)
        #expect(owned.getUpdateRange()?.endY == borrowed.getUpdateRange()?.endY)
        #expect(owned.getScrollInvariantUpdateRange()?.startY == borrowed.getScrollInvariantUpdateRange()?.startY)
        #expect(owned.getScrollInvariantUpdateRange()?.endY == borrowed.getScrollInvariantUpdateRange()?.endY)

        owned.clearUpdateRange()
        borrowed.clearUpdateRange()
        owned.updateRange(startLine: 1, endLine: 3, scrolling: true)
        borrowed.updateRange(borrowing: borrowed.buffer, startLine: 1, endLine: 3,
                             scrolling: true)

        #expect(owned.getUpdateRange()?.startY == borrowed.getUpdateRange()?.startY)
        #expect(owned.getUpdateRange()?.endY == borrowed.getUpdateRange()?.endY)
        #expect(owned.getScrollInvariantUpdateRange() == nil)
        #expect(borrowed.getScrollInvariantUpdateRange() == nil)
    }
}
