import Foundation
import Testing

@testable import SwiftTerm

/// The print and scroll paths do not mark rows in the update ranges.
/// `getUpdateRange` and `getScrollInvariantUpdateRange` find the rows from
/// the line generations and identities after `clearUpdateRange`.
@Suite final class LineChangeTrackerTests {
    private let esc = "\u{1b}"

    private func makeTerminal(rows: Int = 5, scrollback: Int = 100) -> Terminal {
        TerminalTestHarness.makeTerminal(cols: 20, rows: rows, scrollback: scrollback).terminal
    }

    private func range(_ value: (startY: Int, endY: Int)?) -> [Int]? {
        value.map { [$0.startY, $0.endY] }
    }

    @Test func noChangeGivesNoRange() {
        let terminal = makeTerminal()
        terminal.feed(text: "one\r\ntwo")
        terminal.clearUpdateRange()

        #expect(terminal.getUpdateRange() == nil)
        #expect(terminal.getScrollInvariantUpdateRange() == nil)
    }

    @Test func printGivesOnlyTheChangedRow() {
        let terminal = makeTerminal()
        terminal.feed(text: "\(esc)[3;1H")
        terminal.clearUpdateRange()

        terminal.feed(text: "hello")

        let yBase = terminal.buffer.yBase
        #expect(range(terminal.getUpdateRange()) == [2, 2])
        #expect(range(terminal.getScrollInvariantUpdateRange()) == [yBase + 2, yBase + 2])
    }

    @Test func scrollIntoScrollbackChangesOnlyTheNewBufferRow() {
        let terminal = makeTerminal()
        terminal.feed(text: "1\r\n2\r\n3\r\n4\r\n5")
        terminal.clearUpdateRange()

        terminal.feed(text: "\r\n6")

        // All screen rows show a different line, but only the new line
        // changed at its buffer row.
        let yBase = terminal.buffer.yBase
        #expect(yBase == 1)
        #expect(range(terminal.getUpdateRange()) == [0, 4])
        #expect(range(terminal.getScrollInvariantUpdateRange()) == [yBase + 4, yBase + 4])
    }

    @Test func scrollWithFullScrollbackChangesAllBufferRows() {
        let terminal = makeTerminal(scrollback: 2)
        for i in 0..<20 {
            terminal.feed(text: "line \(i)\r\n")
        }
        let yBase = terminal.buffer.yBase
        terminal.clearUpdateRange()

        terminal.feed(text: "last\r\n")

        // The scrollback dropped its first line, so each buffer row of the
        // screen now holds the line that was one row below.
        #expect(terminal.buffer.yBase == yBase)
        #expect(range(terminal.getUpdateRange()) == [0, 4])
        #expect(range(terminal.getScrollInvariantUpdateRange()) == [yBase, yBase + 4])
    }

    @Test func regionScrollGivesTheRegionRows() {
        let terminal = makeTerminal(rows: 10)
        for row in 1...10 {
            terminal.feed(text: "\(esc)[\(row);1HROW\(row)")
        }
        terminal.feed(text: "\(esc)[3;6r\(esc)[6;1H")
        terminal.clearUpdateRange()

        terminal.feed(text: "\n")

        let yBase = terminal.buffer.yBase
        #expect(range(terminal.getUpdateRange()) == [2, 5])
        #expect(range(terminal.getScrollInvariantUpdateRange()) == [yBase + 2, yBase + 5])
    }

    @Test func clearUpdateRangeRecordsTheNewState() {
        let terminal = makeTerminal()
        terminal.feed(text: "a\r\nb\r\nc\r\nd\r\ne\r\nf\(esc)[1;1H")
        terminal.clearUpdateRange()
        #expect(terminal.getUpdateRange() == nil)

        terminal.feed(text: "X")
        #expect(range(terminal.getUpdateRange()) == [0, 0])
        terminal.clearUpdateRange()
        #expect(terminal.getUpdateRange() == nil)
    }

    @Test func alternateScreenChangesAllRows() {
        let terminal = makeTerminal()
        terminal.feed(text: "a\r\nb")
        terminal.clearUpdateRange()

        terminal.feed(text: "\(esc)[?1049h")

        #expect(range(terminal.getUpdateRange()) == [0, 4])
    }
}
