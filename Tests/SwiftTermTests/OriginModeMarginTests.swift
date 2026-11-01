import Testing
@testable import SwiftTerm

/// Cursor commands with origin mode and margins, as xterm does them.
final class OriginModeMarginTests {

    private func cursor(_ terminal: Terminal) -> (x: Int, y: Int) {
        (terminal.buffer.x, terminal.buffer.y)
    }

    @Test func hpaAndVpaAreRelativeToTheMarginsInOriginMode() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 12)
        terminal.feed(text: "\u{1b}[6;11r\u{1b}[?69h\u{1b}[5;10s\u{1b}[?6h")
        terminal.feed(text: "\u{1b}[2`")
        #expect(terminal.buffer.x == 5)
        terminal.feed(text: "\u{1b}[2d")
        #expect(terminal.buffer.y == 6)

        // They stop at the right and bottom margins.
        terminal.feed(text: "\u{1b}[99`\u{1b}[99d")
        #expect(cursor(terminal) == (9, 10))
    }

    @Test func hpaAndVpaAreAbsoluteWithoutOriginMode() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 12)
        terminal.feed(text: "\u{1b}[6;11r\u{1b}[?69h\u{1b}[5;10s")
        terminal.feed(text: "\u{1b}[2`\u{1b}[2d")
        #expect(cursor(terminal) == (1, 1))
        terminal.feed(text: "\u{1b}[99`\u{1b}[99d")
        #expect(cursor(terminal) == (19, 11))
    }

    @Test func indexBelowTheScrollRegionStopsAtTheLastRowWithoutScrolling() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 12)
        terminal.feed(text: "\u{1b}[4;5r\u{1b}[4;1Hkeep\u{1b}[6;1Hx")
        for _ in 0..<20 {
            terminal.feed(text: "\u{1b}D")
        }
        #expect(terminal.buffer.y == 11)
        #expect(terminal.getLine(row: 3)?.translateToString(trimRight: true) == "keep")
    }

    @Test func nextLineOutsideTheLeftRightMarginsDoesNotScroll() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 12)
        terminal.feed(text: "\u{1b}[2;5r\u{1b}[?69h\u{1b}[2;5s\u{1b}[5;3Hx")
        terminal.feed(text: "\u{1b}[5;6H\u{1b}E")
        // The cursor goes to the left margin, and the region does not scroll.
        #expect(cursor(terminal) == (1, 4))
        #expect(terminal.getCharacter(col: 2, row: 4) == "x")
    }

    @Test func screenAlignmentResetsTheMargins() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 12)
        terminal.feed(text: "\u{1b}[?69h\u{1b}[2;3s\u{1b}[4;5r\u{1b}#8")
        #expect(terminal.buffer.scrollTop == 0)
        #expect(terminal.buffer.scrollBottom == 11)
        #expect(terminal.buffer.marginLeft == 0)
        #expect(terminal.buffer.marginRight == 19)
    }

    @Test func resettingLeftRightMarginModeResetsTheMargins() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 12)
        terminal.feed(text: "\u{1b}[?69h\u{1b}[5;7s\u{1b}[?69l")
        #expect(terminal.buffer.marginLeft == 0)
        #expect(terminal.buffer.marginRight == 19)
    }
}
