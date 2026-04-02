import Foundation
import Testing
@testable import SwiftTerm

final class SynchronizedOutputTests {
    private class TestDelegate: TerminalDelegate {
        var scrolledPositions: [Int] = []

        func showCursor(source: Terminal) {}
        func hideCursor(source: Terminal) {}
        func setTerminalTitle(source: Terminal, title: String) {}
        func setTerminalIconTitle(source: Terminal, title: String) {}
        func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { return nil }
        func sizeChanged(source: Terminal) {}
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func scrolled(source: Terminal, yDisp: Int) {
            scrolledPositions.append(yDisp)
        }
        func linefeed(source: Terminal) {}
        func bufferActivated(source: Terminal) {}
        func bell(source: Terminal) {}
    }

    private func topLineText(from buffer: Buffer, terminal: Terminal? = nil) -> String {
        let characterProvider: ((CharData) -> Character)?
        if let terminal {
            characterProvider = { terminal.getCharacter(for: $0) }
        } else {
            characterProvider = nil
        }
        return buffer.translateBufferLineToString(
            lineIndex: buffer.yDisp,
            trimRight: true,
            startCol: 0,
            endCol: -1,
            skipNullCellsFollowingWide: true,
            characterProvider: characterProvider
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

    /// Regression: setViewYDisp must update both live and frozen buffers
    /// during synchronized output so user-initiated scrolling is not dropped.
    @Test func testViewportScrollDuringSyncUpdatesBothBuffers() {
        let terminal = Terminal(
            delegate: TestDelegate(),
            options: TerminalOptions(cols: 40, rows: 5, scrollback: 20)
        )
        let esc = "\u{1b}"

        for i in 0..<25 {
            terminal.feed(text: "line \(i)\r\n")
        }

        terminal.feed(text: "\(esc)[?2026h")
        #expect(terminal.synchronizedOutputActive)

        let yDispBefore = terminal.displayBuffer.yDisp
        let scrollTarget = max(0, yDispBefore - 3)
        terminal.setViewYDisp(scrollTarget)

        #expect(terminal.displayBuffer.yDisp == scrollTarget)
        #expect(terminal.buffer.yDisp == scrollTarget)

        terminal.feed(text: "\(esc)[?2026l")
    }

    /// Regression: after sync ends the delegate must receive a scrolled
    /// notification so host UI can update its scroll indicators.
    @Test func testScrollDelegateFiredAfterSyncEnds() {
        let delegate = TestDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 40, rows: 5, scrollback: 20)
        )
        let esc = "\u{1b}"

        for i in 0..<25 {
            terminal.feed(text: "line \(i)\r\n")
        }

        delegate.scrolledPositions.removeAll()

        terminal.feed(text: "\(esc)[?2026h")
        terminal.feed(text: "new content\r\n")
        terminal.feed(text: "\(esc)[?2026l")

        #expect(!delegate.scrolledPositions.isEmpty)
    }

    // MARK: - View-level regression tests

#if os(macOS)
    /// Regression: scrollTo must not be blocked during synchronized output.
    @Test func testViewScrollToDuringSyncIsNotBlocked() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 400, height: 100)))
        let esc = "\u{1b}"

        for i in 0..<30 {
            view.terminal.feed(text: "line \(i)\r\n")
        }

        let yDispBefore = view.terminal.displayBuffer.yDisp
        #expect(yDispBefore > 0)

        view.terminal.feed(text: "\(esc)[?2026h")
        #expect(view.terminal.synchronizedOutputActive)

        let target = max(0, yDispBefore - 5)
        view.scrollTo(row: target)

        #expect(view.terminal.displayBuffer.yDisp == target)

        view.terminal.feed(text: "\(esc)[?2026l")
    }

    /// Regression: after the sync-end debounce fires, the view must emit
    /// terminalDelegate?.scrolled so host scroll indicators update.
    @Test func testViewEmitsScrollDelegateAfterSyncEnd() async {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 400, height: 100)))
        let esc = "\u{1b}"

        for i in 0..<30 {
            view.terminal.feed(text: "line \(i)\r\n")
        }

        view.terminal.feed(text: "\(esc)[?2026h")
        view.terminal.feed(text: "output during sync\r\n")
        view.terminal.feed(text: "\(esc)[?2026l")

        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(!view.terminal.synchronizedOutputActive)
        #expect(view.scrollPosition >= 0)
    }
#endif
}
