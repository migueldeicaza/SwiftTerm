import Testing
@testable import SwiftTerm

final class ColorQueryTests {
    private final class TestDelegate: TerminalDelegate {
        var sent: [[UInt8]] = []

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            sent.append(Array(data))
        }
    }

    private final class ColorDelegate: TerminalDelegate {
        private(set) var colorChanges: [Int?] = []
        private(set) var cursorColors: [Color?] = []

        func send(source: Terminal, data: ArraySlice<UInt8>) {}

        func colorChanged(source: Terminal, idx: Int?) {
            colorChanges.append(idx)
        }

        func setCursorColor(source: Terminal, color: Color?) {
            cursorColors.append(color)
            source.cursorColor = color
        }
    }

    private func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    @Test func testOsc10And11ColorQueriesReply() {
        let delegate = TestDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        terminal.foregroundColor = Color(red: 0x1111, green: 0x2222, blue: 0x3333)
        terminal.backgroundColor = Color(red: 0x4444, green: 0x5555, blue: 0x6666)

        terminal.feed(text: "\u{1b}]10;?\u{07}")
        terminal.feed(text: "\u{1b}]11;?\u{07}")

        #expect(delegate.sent.count == 2)
        #expect(delegate.sent[0] == bytes("\u{1b}]10;rgb:1111/2222/3333\u{1b}\\"))
        #expect(delegate.sent[1] == bytes("\u{1b}]11;rgb:4444/5555/6666\u{1b}\\"))
    }

    @Test func testOsc104EmptyResetsAllColors() {
        let delegate = ColorDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        terminal.feed(text: "\u{1b}]104\u{07}")

        #expect(delegate.colorChanges.last != nil)
        #expect(delegate.colorChanges.last! == nil)
    }

    @Test func testOsc112ResetsCursorColor() {
        let delegate = ColorDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        terminal.cursorColor = Color(red: 0x1111, green: 0x2222, blue: 0x3333)
        terminal.feed(text: "\u{1b}]112\u{07}")

        #expect(delegate.cursorColors.last != nil)
        #expect(delegate.cursorColors.last! == nil)
        #expect(terminal.cursorColor == nil)
    }
}
