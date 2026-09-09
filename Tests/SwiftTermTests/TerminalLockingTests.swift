import Foundation
import Testing
@testable import SwiftTerm

#if os(iOS) || os(visionOS)
@MainActor
private final class ContentSizeAdjustingTerminalView: TerminalView {
    var adjustsContentOffset = false
    var didAdjustContentOffset = false

    override var contentSize: CGSize {
        didSet {
            guard adjustsContentOffset else { return }
            didAdjustContentOffset = true
            contentOffset = CGPoint(
                x: 0,
                y: max(0, contentSize.height - bounds.height + adjustedContentInset.bottom)
            )
        }
    }
}
#endif

final class TerminalLockingTests {
    private final class TestDelegate: TerminalDelegate {
        func showCursor(source: Terminal) {}
        func hideCursor(source: Terminal) {}
        func setTerminalTitle(source: Terminal, title: String) {}
        func setTerminalIconTitle(source: Terminal, title: String) {}
        func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { nil }
        func sizeChanged(source: Terminal) {}
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func bufferActivated(source: Terminal) {}
        func synchronizedOutputChanged(source: Terminal, active: Bool) {}
        func bell(source: Terminal) {}
        func selectionChanged(source: Terminal) {}
        func isProcessTrusted(source: Terminal) -> Bool { true }
        func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? { nil }
        func mouseModeChanged(source: Terminal) {}
        func setForegroundColor(source: Terminal, color: Color) {}
        func setBackgroundColor(source: Terminal, color: Color) {}
        func setCursorColor(source: Terminal, color: Color?, textColor: Color?) {}
        func colorChanged(source: Terminal, idx: Int?) {}
        func hostCurrentDirectoryUpdated(source: Terminal) {}
        func iTermContent(source: Terminal, content: ArraySlice<UInt8>) {}
        func clipboardCopy(source: Terminal, content: Data) {}
        func clipboardRead(source: Terminal) -> Data? { nil }
        func progressReport(source: Terminal, report: Terminal.ProgressReport) {}
        func getColors(source: Terminal) -> (foreground: Color, background: Color) {
            (Color.defaultForeground, Color.defaultBackground)
        }
    }

    /// All mutable state is protected by `lock`.
    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false

        func stop () {
            lock.lock()
            stopped = true
            lock.unlock()
        }

        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }
    }

    /// A batch producer that reacquires the lock the instant it releases it —
    /// the shape of `parseMain` while the pty has data queued. Over an unfair
    /// mutex the producer barges back in before the woken consumer is
    /// scheduled, and waits of several seconds were measured on a consumer that
    /// only wanted the lock 60 times a second. The ticket in `TerminalLock`
    /// bounds each consumer wait at one batch.
    @Test func backToBackBatchesDoNotStarveAPeriodicWaiter() {
        let lock = TerminalLock()
        let stop = StopFlag()
        let group = DispatchGroup()
        let batchNs: UInt64 = 2_000_000    // one 64 KiB parse batch, roughly
        let iterations = 60

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            while !stop.isStopped {
                lock.withLock {
                    let deadline = DispatchTime.now().uptimeNanoseconds + batchNs
                    while DispatchTime.now().uptimeNanoseconds < deadline {}
                }
            }
            group.leave()
        }

        var worstWaitNs: UInt64 = 0
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            lock.withLock {}
            worstWaitNs = max(worstWaitNs, DispatchTime.now().uptimeNanoseconds - start)
            Thread.sleep(forTimeInterval: 1.0 / 60)
        }

        stop.stop()
        #expect(group.wait(timeout: .now() + 5) == .success)

        // A fair handoff keeps this near one batch. The bound is loose so a
        // loaded machine does not fail it, and still far below the multi-second
        // waits an unfair mutex produces here.
        let worstWaitMs = Double(worstWaitNs) / 1_000_000
        #expect(worstWaitMs < 500, "worst acquisition wait \(worstWaitMs) ms")
    }

    @Test func hammerBackgroundFeedAndReadersUnderTerminalLock() {
        let terminal = Terminal(delegate: TestDelegate(), options: TerminalOptions(cols: 40, rows: 12, scrollback: 80))
        let access = LockedTerminalTestAccess(terminal)
        let stop = StopFlag()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var i = 0
            while !stop.isStopped {
                access.withLock { terminal in
                    terminal.feed(text: "feed \(i) abcdefghijklmnopqrstuvwxyz\r\n")
                }
                i += 1
            }
            group.leave()
        }

        for reader in 0..<2 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var toggled = false
                while !stop.isStopped {
                    access.withLock { terminal in
                        let buffer = terminal.displayBuffer
                        let rows = min(buffer.lines.count, max(buffer.rows, 1))
                        for row in 0..<rows {
                            let line = buffer.lines[row]
                            if line.count > 0 {
                                _ = line[min(line.count - 1, reader)]
                            }
                        }
                        _ = terminal.getUpdateRange()
                        terminal.clearUpdateRange()
                        terminal.resize(cols: toggled ? 40 : 42, rows: toggled ? 12 : 13)
                        toggled.toggle()
                        let maxScroll = max(0, terminal.displayBuffer.lines.count - terminal.displayBuffer.rows)
                        terminal.setViewYDisp(min(maxScroll, reader))
                    }
                }
                group.leave()
            }
        }

        Thread.sleep(forTimeInterval: 2.0)
        stop.stop()
        #expect(group.wait(timeout: .now() + 5) == .success)

        terminal.terminalLock.withLock {
            terminal.resize(cols: 40, rows: 12)
            terminal.feed(text: "\u{1b}[2J\u{1b}[HLOCK-FINAL")
            let row = terminal.displayBuffer.yBase
            let text = terminal.getDisplayText(start: Position(col: 0, row: row), end: Position(col: 10, row: row))
            #expect(text.hasPrefix("LOCK-FINAL"))
        }
    }

    @Test func synchronizedOutputTimeoutClearsUnderBackgroundFeedLock() {
        let terminal = Terminal(delegate: TestDelegate(), options: TerminalOptions(cols: 40, rows: 10, scrollback: 20))
        let access = LockedTerminalTestAccess(terminal)
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            access.withLock { terminal in
                terminal.feed(text: "\u{1b}[?2026h")
            }
            group.leave()
        }

        #expect(group.wait(timeout: .now() + 2) == .success)

        // The 1s timeout fires on the main queue, which parallel @MainActor
        // suites can starve for seconds on a loaded machine — give it a wide
        // margin; the loop exits early as soon as the flag clears.
        let until = Date().addingTimeInterval(10)
        while Date() < until {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            let active = terminal.terminalLock.withLock {
                terminal.synchronizedOutputActive
            }
            if !active {
                break
            }
        }

        let active = terminal.terminalLock.withLock {
            terminal.synchronizedOutputActive
        }
        #expect(!active)
    }

#if os(macOS)
    @MainActor
    @Test func windowlessTerminalViewToleratesBackgroundFeedDuringMainThreadWork() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 640, height: 320)))
        let feedSender = view.feedSender
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            for i in 0..<700 {
                let color = 31 + (i % 6)
                feedSender.feed(text: "\u{1b}[\(color)mview background feed \(i)\u{1b}[0m\r\n")
            }
            feedSender.feed(text: "\u{1b}[2J\u{1b}[HVIEW-FINAL")
            group.leave()
        }

        for i in 0..<600 {
            view.updateDisplay()
            _ = view.getSelection()
            _ = view.withTerminal { terminal in
                terminal.displayBuffer.translateBufferLineToString(
                    lineIndex: terminal.displayBuffer.yDisp,
                    trimRight: true,
                    characterProvider: { terminal.getCharacter(for: $0) }
                )
            }
            if i % 3 == 0 {
                let target = view.withTerminal { terminal in
                    max(0, min(terminal.displayBuffer.yDisp, terminal.displayBuffer.lines.count - terminal.displayBuffer.rows))
                }
                view.scrollTo(row: target, notifyAccessibility: false)
            }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }

        #expect(group.wait(timeout: .now() + 5) == .success)
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        view.updateDisplay()

        let finalText = view.withTerminal { terminal in
            let row = terminal.displayBuffer.yBase
            return terminal.getDisplayText(start: Position(col: 0, row: row), end: Position(col: 10, row: row))
        }
        #expect(finalText.hasPrefix("VIEW-FINAL"))
    }
#endif

#if os(iOS) || os(visionOS)
    @MainActor
    @Test func contentSizeAdjustmentDoesNotReenterTerminalLock() {
        let view = ContentSizeAdjustingTerminalView(
            frame: CGRect(origin: .zero, size: .init(width: 640, height: 320))
        )
        view.adjustsContentOffset = true

        view.updateScroller()

        #expect(view.didAdjustContentOffset)
        #expect(!view.terminal.terminalLock.isLockedByCurrentThread)
    }
#endif
}
