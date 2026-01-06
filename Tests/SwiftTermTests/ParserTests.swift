import Testing
@testable import SwiftTerm

final class ParserTests {
    private let esc = "\u{1b}"

    private final class DcsCapture: DcsHandler {
        private(set) var collected: cstring = []
        private(set) var parameters: [Int] = []
        private(set) var flag: UInt8 = 0
        private(set) var hookCount = 0

        func hook(collect: cstring, parameters: [Int], flag: UInt8) {
            hookCount += 1
            self.collected = collect
            self.parameters = parameters
            self.flag = flag
        }

        func put(data: ArraySlice<UInt8>) {}
        func unhook() {}
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

    @Test func testDcsXtgetTcapHook() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        let capture = DcsCapture()
        terminal.parser.setDcsHandler("+q", capture)

        terminal.feed(text: "\(esc)P+q\(esc)\\")

        #expect(capture.hookCount == 1)
        #expect(capture.collected == [UInt8(ascii: "+")])
        #expect(capture.flag == UInt8(ascii: "q"))
        #expect(capture.parameters.isEmpty || (capture.parameters.count == 1 && capture.parameters[0] == 0))
    }

    @Test func testDcsParamsHook() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        let capture = DcsCapture()
        terminal.parser.setDcsHandler("p", capture)

        terminal.feed(text: "\(esc)P1000p\(esc)\\")

        #expect(capture.hookCount == 1)
        #expect(capture.collected.isEmpty)
        #expect(capture.flag == UInt8(ascii: "p"))
        #expect(capture.parameters == [1000])
    }
}
