import Testing
@testable import SwiftTerm

final class SynchronizedOutputTests {
    private class TestDelegate: TerminalDelegate {
        func showCursor(source: Terminal) {}
        func hideCursor(source: Terminal) {}
        func setTerminalTitle(source: Terminal, title: String) {}
        func setTerminalIconTitle(source: Terminal, title: String) {}
        func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { return nil }
        func sizeChanged(source: Terminal) {}
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func scrolled(source: Terminal, yDisp: Int) {}
        func linefeed(source: Terminal) {}
        func bufferActivated(source: Terminal) {}
        func bell(source: Terminal) {}
    }

    private func topLineText(from buffer: Buffer) -> String {
        buffer.translateBufferLineToString(
            lineIndex: buffer.yDisp,
            trimRight: true,
            startCol: 0,
            endCol: -1,
            skipNullCellsFollowingWide: true
        ).replacingOccurrences(of: "\u{0}", with: " ")
    }

    @Test func testSynchronizedOutputBlocksDisplayUntilReset() {
        let terminal = Terminal(
            delegate: TestDelegate(),
            options: TerminalOptions(cols: 20, rows: 5, scrollback: 0)
        )
        let esc = "\u{1b}"

        terminal.feed(text: "\(esc)[2J\(esc)[HOLD")
        #expect(topLineText(from: terminal.displayBuffer).hasPrefix("OLD"))

        terminal.feed(text: "\(esc)[?2026h")
        terminal.feed(text: "\(esc)[2J\(esc)[HNEW")

        #expect(topLineText(from: terminal.displayBuffer).hasPrefix("OLD"))
        #expect(topLineText(from: terminal.buffer).hasPrefix("NEW"))

        terminal.feed(text: "\(esc)[?2026l")
        #expect(topLineText(from: terminal.displayBuffer).hasPrefix("NEW"))
    }
}
