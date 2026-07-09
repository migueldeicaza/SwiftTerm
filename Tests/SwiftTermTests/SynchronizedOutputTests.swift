import Foundation
import Testing
@testable import SwiftTerm

@Suite(.serialized)
final class SynchronizedOutputTests {
    private class TestDelegate: TerminalDelegate {
        var scrolledPositions: [Int] = []
        var syncChangeHandler: ((Bool) -> Void)?
        private let lock = NSLock()
        private var _synchronizedOutputChanges: [Bool] = []

        var synchronizedOutputChanges: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return _synchronizedOutputChanges
        }

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
        func synchronizedOutputChanged(source: Terminal, active: Bool) {
            lock.lock()
            _synchronizedOutputChanges.append(active)
            lock.unlock()
            syncChangeHandler?(active)
        }
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

    /// Synchronized output (DEC mode 2026) no longer snapshots the buffer in
    /// the core: `displayBuffer === buffer` and the live buffer is mutated
    /// immediately. Display blocking is enforced at the view layer instead
    /// (`AppleTerminalView.updateDisplay` early-returns while the flag is set,
    /// covered by the view-level tests below). This test pins the core
    /// contract: the active flag toggles on `?2026h`/`?2026l`, and the live
    /// buffer always reflects the most recent content.
    @Test func testSynchronizedOutputTracksLiveBufferAndTogglesFlag() {
        let terminal = Terminal(
            delegate: TestDelegate(),
            options: TerminalOptions(cols: 20, rows: 5, scrollback: 0)
        )
        let esc = "\u{1b}"

        terminal.feed(text: "\(esc)[2J\(esc)[HOLD")
        #expect(topLineText(from: terminal.displayBuffer).hasPrefix("OLD"))
        #expect(!terminal.synchronizedOutputActive)

        terminal.feed(text: "\(esc)[?2026h")
        #expect(terminal.synchronizedOutputActive)

        terminal.feed(text: "\(esc)[2J\(esc)[HNEW")
        // Core does not freeze the buffer during sync; the new content is live
        // immediately and displayBuffer mirrors it.
        #expect(topLineText(from: terminal.buffer).hasPrefix("NEW"))
        #expect(topLineText(from: terminal.displayBuffer).hasPrefix("NEW"))

        terminal.feed(text: "\(esc)[?2026l")
        #expect(!terminal.synchronizedOutputActive)
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

    @Test func testSynchronizedOutputTimeoutFromBackgroundFeedClearsFlagAndNotifiesDelegate() {
        let delegate = TestDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 40, rows: 5, scrollback: 20)
        )
        let esc = "\u{1b}"
        let finished = DispatchSemaphore(value: 0)
        let syncEnded = DispatchSemaphore(value: 0)
        delegate.syncChangeHandler = { active in
            if !active {
                syncEnded.signal()
            }
        }

        DispatchQueue.global().async {
            terminal.terminalLock.withLock {
                terminal.feed(text: "\(esc)[?2026h")
            }
            finished.signal()
        }

        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(terminal.terminalLock.withLock { terminal.synchronizedOutputActive })

        #expect(syncEnded.wait(timeout: .now() + 2) == .success)

        #expect(!terminal.terminalLock.withLock { terminal.synchronizedOutputActive })
        #expect(delegate.synchronizedOutputChanges.contains(true))
        #expect(delegate.synchronizedOutputChanges.contains(false))
    }

    // MARK: - View-level regression tests

#if os(macOS)
    /// Regression: scrollTo must not be blocked during synchronized output.
    @MainActor
    @Test func testViewScrollToDuringSyncIsNotBlocked() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 400, height: 100)))
        let esc = "\u{1b}"

        for i in 0..<30 {
            view.feed(text: "line \(i)\r\n")
        }

        let yDispBefore = view.withTerminal { $0.displayBuffer.yDisp }
        #expect(yDispBefore > 0)

        view.feed(text: "\(esc)[?2026h")
        #expect(view.withTerminal { $0.synchronizedOutputActive })

        let target = max(0, yDispBefore - 5)
        view.scrollTo(row: target)

        #expect(view.withTerminal { $0.displayBuffer.yDisp } == target)

        view.feed(text: "\(esc)[?2026l")
    }

    /// Regression: after the sync-end debounce fires, the view must emit
    /// terminalDelegate?.scrolled so host scroll indicators update.
    @MainActor
    @Test func testViewEmitsScrollDelegateAfterSyncEnd() async {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 400, height: 100)))
        let esc = "\u{1b}"

        for i in 0..<30 {
            view.feed(text: "line \(i)\r\n")
        }

        view.feed(text: "\(esc)[?2026h")
        view.feed(text: "output during sync\r\n")
        view.feed(text: "\(esc)[?2026l")

        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(!view.withTerminal { $0.synchronizedOutputActive })
        #expect(view.scrollPosition >= 0)
    }

    private final class ReentrantScrollDelegate: TerminalViewDelegate {
        private let lock = NSLock()
        private var _scrolledCount = 0

        var scrolledCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _scrolledCount
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled(source: TerminalView, position: Double) {
            _ = source.scrollPosition
            lock.lock()
            _scrolledCount += 1
            lock.unlock()
        }
        func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    @MainActor
    @Test func testViewScrolledCallbackCanUseLockingApiAfterMultiScrollFeed() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 400, height: 100)))
        let delegate = ReentrantScrollDelegate()
        view.terminalDelegate = delegate

        for i in 0..<120 {
            view.feed(text: "line \(i)\r\n")
        }

        view.updateDisplay()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))

        #expect(delegate.scrolledCount > 0)
    }
#endif
}
