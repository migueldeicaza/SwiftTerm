import Testing
@testable import SwiftTerm

struct TerminalUpdateRangeTests {
    @Test func testSingleLineUpdateMarksExactRow() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 5)
        terminal.clearUpdateRange()

        terminal.updateRange(2)

        guard let range = terminal.getUpdateRange() else {
            Issue.record("Expected update range after calling updateRange")
            return
        }

        #expect(range.startY == 2)
        #expect(range.endY == 2)
    }

    @Test func testMultipleDiscreteUpdatesMergeBounds() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)
        terminal.clearUpdateRange()

        terminal.updateRange(1)
        terminal.updateRange(8)

        guard let range = terminal.getUpdateRange() else {
            Issue.record("Expected merged update range")
            return
        }

        #expect(range.startY == 1)
        #expect(range.endY == 8)
    }

    @Test func testRangeClearsAfterRead() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 5)
        terminal.clearUpdateRange()

        terminal.updateRange(3)

        guard terminal.getUpdateRange() != nil else {
            Issue.record("Expected range before clearing")
            return
        }

        // Fetching the range should not clear it automatically.
        #expect(terminal.getUpdateRange() != nil)

        terminal.clearUpdateRange()
        #expect(terminal.getUpdateRange() == nil)
    }

    @Test func testScrollingSeparatesInvariantRange() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 10)
        terminal.clearUpdateRange()

        terminal.buffer.yDisp = 12
        terminal.updateRange(1)

        guard let viewportRange = terminal.getUpdateRange(),
              let invariantRange = terminal.getScrollInvariantUpdateRange() else {
            Issue.record("Expected both viewport and invariant ranges")
            return
        }

        #expect(viewportRange.startY == 1)
        #expect(viewportRange.endY == 1)
        #expect(invariantRange.startY == 13)
        #expect(invariantRange.endY == 13)
    }

    @Test func testScrollingUpdatesDoNotAffectInvariantRange() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 5)
        terminal.clearUpdateRange()

        terminal.updateRange(0, scrolling: true)

        #expect(terminal.getUpdateRange() != nil)
        #expect(terminal.getScrollInvariantUpdateRange() == nil)
    }

    @Test func testFeedingTextMarksDirtyViewportRows() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 3)
        terminal.clearUpdateRange()

        terminal.feed(text: "abc")

        guard let range = terminal.getUpdateRange() else {
            Issue.record("Expected dirty range after feeding text")
            return
        }

        #expect(range.startY == 0)
        #expect(range.endY == 0)
    }

    @Test func testFeedingScrollProducesScrollInvariantRange() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 2, scrollback: 10)
        terminal.clearUpdateRange()

        for i in 0..<10 {
            terminal.feed(text: "line\(i)\r\n")
        }

        guard let viewportRange = terminal.getUpdateRange() else {
            Issue.record("Expected viewport range after scroll-producing feed")
            return
        }
        #expect(viewportRange.startY == 0)
        #expect(viewportRange.endY == terminal.rows - 1)

        guard let invariant = terminal.getScrollInvariantUpdateRange() else {
            Issue.record("Expected scroll-invariant range after scroll-producing feed")
            return
        }

        #expect(terminal.buffer.yBase > 0)
        #expect(invariant.endY >= terminal.buffer.yDisp)
    }
}
