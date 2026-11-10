import Testing
@testable import SwiftTerm

/// SL (CSI Ps SP @) and SR (CSI Ps SP A), ECMA-48 scroll left and right.
final class ScrollColumnsTests {
    let esc = "\u{1b}"

    private func row(_ terminal: Terminal, _ y: Int, _ count: Int) -> String {
        String((0..<count).map { x -> Character in
            let c = terminal.getCharacter(col: x, row: y) ?? " "
            return c == "\u{0}" ? " " : c
        })
    }

    private func makeTerminal() -> Terminal {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 4)
        terminal.feed(text: "0123456789\(esc)[2;1Habcdefghij\(esc)[3;1HABCDEFGHIJ\(esc)[4;1Hklmnopqrst")
        return terminal
    }

    @Test func scrollLeftMovesEveryRowAndKeepsTheCursor() {
        let terminal = makeTerminal()
        terminal.feed(text: "\(esc)[2;3H\(esc)[2 @")
        #expect(row(terminal, 0, 10) == "23456789  ")
        #expect(row(terminal, 1, 10) == "cdefghij  ")
        #expect(row(terminal, 3, 10) == "mnopqrst  ")
        #expect(terminal.buffer.x == 2)
        #expect(terminal.buffer.y == 1)
    }

    @Test func scrollRightDefaultsToOneColumn() {
        let terminal = makeTerminal()
        terminal.feed(text: "\(esc)[ A")
        #expect(row(terminal, 0, 10) == " 012345678")
        #expect(row(terminal, 2, 10) == " ABCDEFGHI")
        // The setup text ends in the pending-wrap position; SR keeps it.
        #expect(terminal.buffer.x == 9)
        #expect(terminal.buffer.pendingWrap)
    }

    @Test func scrollStaysInsideTheMargins() {
        let terminal = makeTerminal()
        // Left and right margins at columns 3 to 7, top and bottom at rows 2 to 3.
        // DECSLRM and DECSTBM home the cursor, so move it into the margins.
        terminal.feed(text: "\(esc)[?69h\(esc)[3;7s\(esc)[2;3r\(esc)[2;3H")
        terminal.feed(text: "\(esc)[1 @")
        #expect(row(terminal, 0, 10) == "0123456789")
        #expect(row(terminal, 1, 10) == "abdefg hij")
        #expect(row(terminal, 2, 10) == "ABDEFG HIJ")
        #expect(row(terminal, 3, 10) == "klmnopqrst")
        terminal.feed(text: "\(esc)[2 A")
        #expect(row(terminal, 1, 10) == "ab  defhij")
    }

    @Test func countLargerThanTheMarginsClearsThem() {
        let terminal = makeTerminal()
        terminal.feed(text: "\(esc)[?69h\(esc)[3;7s\(esc)[1;3H\(esc)[99 A")
        #expect(row(terminal, 0, 10) == "01     789")
        terminal.feed(text: "\(esc)[?69l\(esc)[999 @")
        #expect(row(terminal, 3, 10) == "          ")
    }

    @Test func otherIntermediatesDoNothing() {
        let terminal = makeTerminal()
        terminal.feed(text: "\(esc)[3;5H\(esc)[2!@\(esc)[2!A")
        #expect(row(terminal, 2, 10) == "ABCDEFGHIJ")
        #expect(terminal.buffer.y == 2)
        // ICH and CUU still work.
        terminal.feed(text: "\(esc)[@\(esc)[A")
        #expect(row(terminal, 2, 10) == "ABCD EFGHI")
        #expect(terminal.buffer.y == 1)
    }

    @Test func wideCharacterAtTheMarginIsRepaired() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 6, rows: 2)
        terminal.feed(text: "\u{4e2d}abcd\(esc)[ @")
        // Half of the wide character leaves the screen: the rest is blank.
        #expect(row(terminal, 0, 6) == " abcd ")
    }

    /// xterm `xtermColScroll` does nothing if the cursor is outside the margins.
    @Test(arguments: [("below the region", "5;4H"), ("above the region", "1;4H"),
                      ("left of the margin", "3;2H"), ("right of the margin", "3;8H")])
    func cursorOutsideTheMarginsDoesNothing(name: String, position: String) {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 5)
        terminal.feed(text: "0123456789\(esc)[2;1Habcdefghij\(esc)[3;1HABCDEFGHIJ")
        terminal.feed(text: "\(esc)[?69h\(esc)[3;7s\(esc)[2;3r\(esc)[\(position)")
        terminal.feed(text: "\(esc)[2 @\(esc)[2 A\(esc)[2 @")
        #expect(row(terminal, 0, 10) == "0123456789", "\(name)")
        #expect(row(terminal, 1, 10) == "abcdefghij", "\(name)")
        #expect(row(terminal, 2, 10) == "ABCDEFGHIJ", "\(name)")
    }

    @Test func rowBelowTheRegionStopsBeingAContinuation() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 4)
        terminal.feed(text: "x\r\n0123456789abc")
        #expect(terminal.buffer.lines[2].isWrapped)
        terminal.feed(text: "\(esc)[1;2r\(esc)[2 @")
        #expect(row(terminal, 1, 10) == "23456789  ")
        #expect(row(terminal, 2, 10) == "abc       ")
        #expect(!terminal.buffer.lines[1].isWrapped)
        #expect(!terminal.buffer.lines[2].isWrapped)
    }

    @Test func nextCharacterDoesNotJoinACellThatMoved() {
        let terminal = TerminalTestHarness.makeTerminal(cols: 10, rows: 2).0
        // SR moves the first regional indicator to the cells before the cursor.
        terminal.feed(text: "\u{1F1FA}x\(esc)[ A\u{1F1F8}")
        #expect(terminal.getCharacter(col: 1, row: 0) == "\u{1F1FA}")
        #expect(terminal.getCharacter(col: 3, row: 0) == "\u{1F1F8}")
    }
}
