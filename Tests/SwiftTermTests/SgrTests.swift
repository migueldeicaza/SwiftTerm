import Testing
@testable import SwiftTerm

final class SgrTests {
    private let esc = "\u{1b}"

    @Test func testBoldItalicUnderline() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[1;3;4mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        #expect(cell.attribute.style.contains(.bold))
        #expect(cell.attribute.style.contains(.italic))
        #expect(cell.attribute.style.contains(.underline))
    }

    @Test func testResetBold() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[1mX\(esc)[22mY")

        let boldCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        let resetCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 1)
        #expect(boldCell != nil)
        #expect(resetCell != nil)
        guard let boldCell, let resetCell else { return }
        #expect(boldCell.attribute.style.contains(.bold))
        #expect(!resetCell.attribute.style.contains(.bold))
    }

    @Test func testEightColorFgBg() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[31;44mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        #expect(cell.attribute.fg == .ansi256(code: 1))
        #expect(cell.attribute.bg == .ansi256(code: 4))
    }

    @Test func test256ColorFgBg() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[38;5;200;48;5;100mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        #expect(cell.attribute.fg == .ansi256(code: 200))
        #expect(cell.attribute.bg == .ansi256(code: 100))
    }

    @Test func testTrueColorFgBgSemicolon() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[38;2;1;2;3;48;2;4;5;6mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        #expect(cell.attribute.fg == .trueColor(red: 1, green: 2, blue: 3))
        #expect(cell.attribute.bg == .trueColor(red: 4, green: 5, blue: 6))
    }

    @Test func testTrueColorFgColon() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[38:2:0:10:20:30mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        #expect(cell.attribute.fg == .trueColor(red: 10, green: 20, blue: 30))
    }

    @Test func testUnderlineColorSetAndReset() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[4;58;2;9;8;7mX\(esc)[59mY")

        let setCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        let resetCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 1)
        #expect(setCell != nil)
        #expect(resetCell != nil)
        guard let setCell, let resetCell else { return }
        #expect(setCell.attribute.underlineColor == .trueColor(red: 9, green: 8, blue: 7))
        #expect(resetCell.attribute.underlineColor == nil)
    }
}
