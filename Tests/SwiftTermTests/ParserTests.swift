import Testing
@testable import SwiftTerm

final class ParserTests {
    private let esc = "\u{1b}"

    @Test func borrowedFeedMatchesOwnedParserSemantics() {
        let (owned, ownedDelegate) = TerminalTestHarness.makeTerminal(cols: 20, rows: 4)
        let (borrowed, borrowedDelegate) = TerminalTestHarness.makeTerminal(cols: 20, rows: 4)
        let bytes = Array((
            "\u{1b}]2;borrowed-title\u{07}" +
            "\u{1b}]4;1;rgb:11/22/33\u{07}" +
            "\u{1b}[?2026h" +
            "normal" +
            "\u{1b}[?1003h" +
            "\u{1b}[?1049h" +
            "\u{1b}[38;2;12;34;56mALT"
        ).utf8)
        let chunkEnds = [1, 7, 19, 32, 48, 63, bytes.count]
        var start = 0
        for end in chunkEnds {
            let slice = bytes[start..<end]
            owned.feed(buffer: slice)
            borrowed.feedBorrowed(slice.span)
            start = end
        }

        #expect(ownedDelegate.terminalTitles.last == "borrowed-title")
        #expect(borrowedDelegate.terminalTitles == ownedDelegate.terminalTitles)
        #expect(owned.ansiColors[1] == Color(red8: 0x11, green8: 0x22, blue8: 0x33))
        #expect(borrowed.ansiColors[1] == owned.ansiColors[1])
        #expect(borrowed.synchronizedOutputActive == owned.synchronizedOutputActive)
        #expect(borrowed.mouseMode == owned.mouseMode)
        #expect(borrowed.isCurrentBufferAlternate == owned.isCurrentBufferAlternate)
        #expect(TerminalTestHarness.visibleLinesText(
            buffer: borrowed.buffer,
            terminal: borrowed) == TerminalTestHarness.visibleLinesText(
                buffer: owned.buffer,
                terminal: owned))
        #expect(TerminalTestHarness.cursorPosition(buffer: borrowed.buffer)
            == TerminalTestHarness.cursorPosition(buffer: owned.buffer))
    }

    @Test func testSgrMixedColonSemicolonWithBlank() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[;4:3;38;2;175;175;215;58:2::190:80:70mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        #expect(cell.attribute.style.contains(.underline))
        #expect(cell.attribute.fg == .trueColor(red: 175, green: 175, blue: 215))
        #expect(cell.attribute.underlineColor == .trueColor(red: 190, green: 80, blue: 70))
    }

    @Test func testSgrMixedColonSemicolonUnderlineBgFg() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[4:3;38;2;51;51;51;48;2;170;170;170;58;2;255;97;136mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        #expect(cell.attribute.style.contains(.underline))
        #expect(cell.attribute.fg == .trueColor(red: 51, green: 51, blue: 51))
        #expect(cell.attribute.bg == .trueColor(red: 170, green: 170, blue: 170))
        #expect(cell.attribute.underlineColor == .trueColor(red: 255, green: 97, blue: 136))
    }

    @Test func testUnderlineColorColonWithoutColorspace() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[58:2:1:2:3mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        #expect(cell.attribute.underlineColor == .trueColor(red: 1, green: 2, blue: 3))
    }

    @Test func testTrueColorFgColonWithColorspaceAndBold() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[38:2:0:1:2:3;1mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        #expect(cell.attribute.fg == .trueColor(red: 1, green: 2, blue: 3))
        #expect(cell.attribute.style.contains(.bold))
    }

    @Test func testTrueColorFgColonNoColorspaceAndBold() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[38:2:1:2:3;1mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        #expect(cell.attribute.fg == .trueColor(red: 1, green: 2, blue: 3))
        #expect(cell.attribute.style.contains(.bold))
    }

    @Test func test256ColorFgColon() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[38:5:200mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        #expect(cell.attribute.fg == .ansi256(code: 200))
    }

    @Test func testTrueColorBgColonWithColorspace() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[48:2:0:4:5:6mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        #expect(cell.attribute.bg == .trueColor(red: 4, green: 5, blue: 6))
    }

    // MARK: - CSI Parser Edge Cases (Ported from Ghostty)

    /// Test that too many CSI parameters are handled gracefully
    /// From Ghostty: "csi: too many params"
    @Test func testCsiTooManyParams() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        // Send a CSI with 100 parameters - should not crash
        var seq = "\(esc)["
        for _ in 0..<100 {
            seq += "1;"
        }
        seq += "1C"
        terminal.feed(text: seq)
        // Should complete without crashing - cursor might move or not depending on implementation
        // The main test is that we don't crash
    }

    /// Test CSI with max allowed parameters
    /// From Ghostty: "csi: sgr with up to our max parameters"
    @Test func testCsiMaxParams() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        // CSI with reasonable number of params should work
        terminal.feed(text: "\(esc)[1;2;3;4;5;6;7;8;9;10H")
        // Should position cursor - exact behavior depends on implementation
        // Main test is no crash with many params
    }

    /// Test colon separator is only allowed for 'm' (SGR) final
    /// From Ghostty: "csi: colon for non-m final"
    @Test func testCsiColonOnlyForSgr() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        // Colon separator with 'h' final should be ignored/invalid
        terminal.feed(text: "\(esc)[38:2h")
        // Should not crash, sequence may be ignored
    }

    /// Test DECRQM (Request Mode) parsing with intermediates
    /// From Ghostty: "csi: request mode decrqm"
    @Test func testCsiDecrqm() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        defer { withExtendedLifetime(delegate) {} }
        terminal.feed(text: "\(esc)[?2026$p")
        // Terminal should respond with mode status
        // Check that parsing didn't crash - response depends on implementation
    }

    /// Test cursor shape change with space intermediate
    /// From Ghostty: "csi: change cursor"
    @Test func testCsiCursorShape() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[3 q")  // Blinking underline
        // Should not crash, cursor shape handling depends on implementation
    }

    /// Test ESC sequence with intermediate
    /// From Ghostty: "esc: ESC ( B"
    @Test func testEscWithIntermediate() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)(B")  // Designate G0 character set as ASCII
        terminal.feed(text: "A")
        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell?.getCharacter() == "A")
    }

    /// Test CSI H (cursor position) without parameters
    /// From Ghostty: "csi: ESC [ H"
    @Test func testCsiCursorPositionNoParams() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        // Move cursor somewhere first
        terminal.feed(text: "\(esc)[5;10H")
        // Then reset with no params (should go to 1,1)
        terminal.feed(text: "\(esc)[H")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 0, row: 0)
    }

    /// Test CSI H with parameters
    /// From Ghostty: "csi: ESC [ 1 ; 4 H"
    @Test func testCsiCursorPositionWithParams() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[5;10H")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 9, row: 4)  // 1-based to 0-based
    }

    /// Test mixed colon/semicolon with 256-color
    /// From Ghostty: "csi: SGR mixed colon and semicolon"
    @Test func testSgrMixed256Color() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[38:5:1;48:5:0mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        #expect(cell.attribute.fg == .ansi256(code: 1))
        #expect(cell.attribute.bg == .ansi256(code: 0))
    }

    /// Test SGR sequence followed by another CSI
    /// From Ghostty: "csi: SGR colon followed by semicolon"
    @Test func testSgrFollowedByCsi() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[48:2m")  // Incomplete true color (should use defaults)
        terminal.feed(text: "\(esc)[H")      // Cursor home
        TerminalTestHarness.assertCursor(terminal.buffer, col: 0, row: 0)
    }

    @Test func testParserStateDoesNotLeakAcrossClearedSequences() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        defer { withExtendedLifetime(delegate) {} }
        let parser = EscapeSequenceParser()
        var oscPayload: String?
        parser.oscHandlers[777] = { data in
            oscPayload = String(bytes: data, encoding: .utf8)
        }

        func parse(_ text: String) {
            let bytes = Array(text.utf8)
            parser.parse(data: bytes[...], terminal)
        }

        parse("\(esc)[?25h")
        #expect(parser._collect == [UInt8(ascii: "?")])

        parse("\(esc)[H")
        #expect(parser._collect.isEmpty)

        parse("\(esc)]777;payload\u{7}")
        #expect(parser._osc.isEmpty)

        parse("\(esc)[H")

        #expect(oscPayload == "payload")
        #expect(parser._osc.isEmpty)
        #expect(parser._apc.isEmpty)
        #expect(parser._collect.isEmpty)
        #expect(parser._parsTxt.isEmpty)
        TerminalTestHarness.assertCursor(terminal.buffer, col: 0, row: 0)
    }
}
