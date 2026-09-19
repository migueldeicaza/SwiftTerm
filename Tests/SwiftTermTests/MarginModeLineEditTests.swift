import Testing
@testable import SwiftTerm

/// Insert Line and Delete Line inside left/right margin mode (DECLRMM).
///
/// Both copy rows starting at the *cursor* row, so the number of rows to move
/// is the distance from the cursor to the bottom of the scroll region. Using
/// the region's full height instead walks past the last line of the buffer,
/// and `CircularList`'s subscript wraps modulo its backing array, so the tail
/// of the walk overwrites rows at the top of the screen.
///
/// tmux enables DECLRMM at startup, so this showed up as garbled output for
/// anything full-screen running inside tmux.
final class MarginModeLineEditTests {

    /// Fills every row with a distinguishable marker, `ROW01`…`ROW<rows>`.
    private func fill(_ terminal: Terminal, rows: Int) {
        for r in 1...rows {
            terminal.feed(text: "\u{1b}[\(r);1H" + String(format: "ROW%02d", r) + "\u{1b}[K")
        }
    }

    private func visible(_ terminal: Terminal, rows: Int) -> [String] {
        (0..<rows).map {
            terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? ""
        }
    }

    @Test func deleteLineInMarginModeLeavesRowsAboveTheCursorAlone() {
        let rows = 24
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 40, rows: rows)
        terminal.feed(text: "\u{1b}[?1049h")      // alternate screen, as tmux uses
        fill(terminal, rows: rows)
        terminal.feed(text: "\u{1b}[?69h")        // DECLRMM
        terminal.feed(text: "\u{1b}[1;22r")       // scroll region rows 1..22
        terminal.feed(text: "\u{1b}[20;1H")       // cursor on row 20
        terminal.feed(text: "\u{1b}[2M")          // delete 2 lines

        let screen = visible(terminal, rows: rows)
        // Everything above the cursor is untouched.
        for r in 0..<18 {
            #expect(screen[r] == String(format: "ROW%02d", r + 1), "row \(r)")
        }
        // Row 22 moves up into the cursor row, the rest of the region blanks.
        #expect(screen[18] == "ROW19")
        #expect(screen[19] == "ROW22")
        #expect(screen[20] == "")
        #expect(screen[21] == "")
        // Rows outside the scroll region are untouched.
        #expect(screen[22] == "ROW23")
        #expect(screen[23] == "ROW24")
    }

    @Test func insertLineInMarginModeLeavesRowsAboveTheCursorAlone() {
        let rows = 24
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 40, rows: rows)
        terminal.feed(text: "\u{1b}[?1049h")
        fill(terminal, rows: rows)
        terminal.feed(text: "\u{1b}[?69h")
        terminal.feed(text: "\u{1b}[1;22r")
        terminal.feed(text: "\u{1b}[20;1H")
        terminal.feed(text: "\u{1b}[2L")          // insert 2 lines

        let screen = visible(terminal, rows: rows)
        for r in 0..<18 {
            #expect(screen[r] == String(format: "ROW%02d", r + 1), "row \(r)")
        }
        #expect(screen[18] == "ROW19")
        #expect(screen[19] == "")                 // two blanks pushed in
        #expect(screen[20] == "")
        #expect(screen[21] == "ROW20")            // ROW21/22 pushed off the region
        #expect(screen[22] == "ROW23")
        #expect(screen[23] == "ROW24")
    }

    /// The margin and non-margin paths must agree: enabling DECLRMM with the
    /// margins left at the full width should not change what DL does.
    @Test func marginModeMatchesTheNonMarginPathAtFullWidth() {
        let rows = 24
        func run(marginMode: Bool) -> [String] {
            let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 40, rows: rows)
            terminal.feed(text: "\u{1b}[?1049h")
            fill(terminal, rows: rows)
            if marginMode { terminal.feed(text: "\u{1b}[?69h") }
            terminal.feed(text: "\u{1b}[1;22r\u{1b}[20;1H\u{1b}[2M")
            return visible(terminal, rows: rows)
        }
        #expect(run(marginMode: true) == run(marginMode: false))
    }

    /// DL does nothing when the cursor sits outside the vertical scroll region,
    /// which the non-margin path already enforced.
    @Test func deleteLineOutsideTheScrollRegionIsIgnoredInMarginMode() {
        let rows = 24
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 40, rows: rows)
        terminal.feed(text: "\u{1b}[?1049h")
        fill(terminal, rows: rows)
        terminal.feed(text: "\u{1b}[?69h")
        terminal.feed(text: "\u{1b}[1;10r")       // region rows 1..10
        terminal.feed(text: "\u{1b}[20;1H")       // cursor below it
        terminal.feed(text: "\u{1b}[2M")

        let screen = visible(terminal, rows: rows)
        for r in 0..<rows {
            #expect(screen[r] == String(format: "ROW%02d", r + 1), "row \(r)")
        }
    }
}
