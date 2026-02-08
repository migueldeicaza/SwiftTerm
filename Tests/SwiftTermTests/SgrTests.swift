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

    // MARK: - SGR Tests Ported from Ghostty

    /// Test SGR 0 resets all attributes
    /// From Ghostty: comprehensive attribute reset
    @Test func testSgrResetAll() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[1;3;4;31mX\(esc)[0mY")

        let styledCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        let resetCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 1)
        #expect(styledCell != nil)
        #expect(resetCell != nil)
        guard let styledCell, let resetCell else { return }

        // X should have bold, italic, underline, red fg
        #expect(styledCell.attribute.style.contains(.bold))
        #expect(styledCell.attribute.style.contains(.italic))
        #expect(styledCell.attribute.style.contains(.underline))

        // Y should have all attributes reset
        #expect(!resetCell.attribute.style.contains(.bold))
        #expect(!resetCell.attribute.style.contains(.italic))
        #expect(!resetCell.attribute.style.contains(.underline))
    }

    /// Test SGR 21 double underline is recognized (currently a no-op in SwiftTerm)
    /// From Ghostty: "sgr: underline styles"
    /// Note: SGR 21 is double underline per ECMA-48, but SwiftTerm doesn't currently
    /// support distinct underline styles. This test just verifies it doesn't crash.
    @Test func testSgrDoubleUnderline() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        // SGR 21 = double underline (currently no-op in SwiftTerm)
        terminal.feed(text: "\(esc)[21mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        // Test passes if no crash - double underline not yet implemented
        // TODO: When double underline is implemented, verify it's set here
    }

    /// Test SGR 24 removes underline
    /// From Ghostty: "sgr: underline styles"
    @Test func testSgrRemoveUnderline() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[4mX\(esc)[24mY")

        let underlinedCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        let noUnderlineCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 1)
        #expect(underlinedCell != nil)
        #expect(noUnderlineCell != nil)
        guard let underlinedCell, let noUnderlineCell else { return }
        #expect(underlinedCell.attribute.style.contains(.underline))
        #expect(!noUnderlineCell.attribute.style.contains(.underline))
    }

    /// Test blink attribute (SGR 5)
    @Test func testSgrBlink() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[5mX\(esc)[25mY")

        let blinkCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        let noBlinkCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 1)
        #expect(blinkCell != nil)
        #expect(noBlinkCell != nil)
        guard let blinkCell, let noBlinkCell else { return }
        #expect(blinkCell.attribute.style.contains(.blink))
        #expect(!noBlinkCell.attribute.style.contains(.blink))
    }

    /// Test inverse attribute (SGR 7)
    @Test func testSgrInverse() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[7mX\(esc)[27mY")

        let inverseCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        let normalCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 1)
        #expect(inverseCell != nil)
        #expect(normalCell != nil)
        guard let inverseCell, let normalCell else { return }
        #expect(inverseCell.attribute.style.contains(.inverse))
        #expect(!normalCell.attribute.style.contains(.inverse))
    }

    /// Test invisible/hidden attribute (SGR 8)
    @Test func testSgrInvisible() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[8mX\(esc)[28mY")

        let hiddenCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        let visibleCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 1)
        #expect(hiddenCell != nil)
        #expect(visibleCell != nil)
        guard let hiddenCell, let visibleCell else { return }
        #expect(hiddenCell.attribute.style.contains(.invisible))
        #expect(!visibleCell.attribute.style.contains(.invisible))
    }

    /// Test strikethrough/crossed-out attribute (SGR 9)
    @Test func testSgrStrikethrough() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[9mX\(esc)[29mY")

        let strikeCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        let normalCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 1)
        #expect(strikeCell != nil)
        #expect(normalCell != nil)
        guard let strikeCell, let normalCell else { return }
        #expect(strikeCell.attribute.style.contains(.crossedOut))
        #expect(!normalCell.attribute.style.contains(.crossedOut))
    }

    /// Test dim attribute (SGR 2)
    @Test func testSgrDim() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[2mX\(esc)[22mY")

        let dimCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        let normalCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 1)
        #expect(dimCell != nil)
        #expect(normalCell != nil)
        guard let dimCell, let normalCell else { return }
        #expect(dimCell.attribute.style.contains(.dim))
        #expect(!normalCell.attribute.style.contains(.dim))
    }

    /// Test bright/high-intensity foreground colors (SGR 90-97)
    @Test func testSgrBrightForeground() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[91mX")  // Bright red

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        // Bright red is index 9 in 256-color palette
        #expect(cell.attribute.fg == .ansi256(code: 9))
    }

    /// Test bright/high-intensity background colors (SGR 100-107)
    @Test func testSgrBrightBackground() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[104mX")  // Bright blue background

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        // Bright blue background is index 12 in 256-color palette
        #expect(cell.attribute.bg == .ansi256(code: 12))
    }

    /// Test default foreground color (SGR 39)
    @Test func testSgrDefaultForeground() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[31mX\(esc)[39mY")

        let redCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        let defaultCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 1)
        #expect(redCell != nil)
        #expect(defaultCell != nil)
        guard let redCell, let defaultCell else { return }
        #expect(redCell.attribute.fg == .ansi256(code: 1))
        #expect(defaultCell.attribute.fg == .defaultColor)
    }

    /// Test default background color (SGR 49)
    @Test func testSgrDefaultBackground() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[44mX\(esc)[49mY")

        let blueCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        let defaultCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 1)
        #expect(blueCell != nil)
        #expect(defaultCell != nil)
        guard let blueCell, let defaultCell else { return }
        #expect(blueCell.attribute.bg == .ansi256(code: 4))
        // SGR 49 resets to default background - SwiftTerm uses .defaultColor for this
        #expect(defaultCell.attribute.bg == .defaultColor)
    }

    /// Test underline color with colon syntax and colorspace
    /// From Ghostty: "sgr: SGR with many blank and colon"
    @Test func testUnderlineColorColonWithColorspace() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        // 58:2::R:G:B - underline color with empty colorspace
        terminal.feed(text: "\(esc)[58:2::240:143:104mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        #expect(cell.attribute.underlineColor == .trueColor(red: 240, green: 143, blue: 104))
    }

    /// Test 256-color underline
    /// From Ghostty: "256_underline_color"
    @Test func testUnderlineColor256() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[4;58:5:200mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        #expect(cell.attribute.style.contains(.underline))
        #expect(cell.attribute.underlineColor == .ansi256(code: 200))
    }

    /// Test combining multiple SGR attributes in one sequence
    /// From Ghostty: comprehensive attribute testing
    @Test func testSgrMultipleCombined() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[1;2;3;4;5;7;9;38;5;196;48;5;21mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        #expect(cell.attribute.style.contains(.bold))
        #expect(cell.attribute.style.contains(.dim))
        #expect(cell.attribute.style.contains(.italic))
        #expect(cell.attribute.style.contains(.underline))
        #expect(cell.attribute.style.contains(.blink))
        #expect(cell.attribute.style.contains(.inverse))
        #expect(cell.attribute.style.contains(.crossedOut))
        #expect(cell.attribute.fg == .ansi256(code: 196))
        #expect(cell.attribute.bg == .ansi256(code: 21))
    }
}
