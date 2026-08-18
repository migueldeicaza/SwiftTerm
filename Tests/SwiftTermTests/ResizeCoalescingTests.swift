//
//  ResizeCoalescingTests.swift
//  SwiftTermTests
//
//  A live window drag calls `setFrameSize` on every step. Each one used to
//  resize the terminal synchronously and notify the delegate, which does the
//  pty ioctl. They now coalesce to one per frame (io-gaps.md G5b).
//

#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct ResizeCoalescingTests {

    private final class SizeRecordingDelegate: TerminalViewDelegate {
        var sizes: [(cols: Int, rows: Int)] = []

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            sizes.append((cols: newCols, rows: newRows))
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// A clock the tests advance by hand, so the resume tick's 16 ms rate limit
    /// is not a hidden participant in every assertion.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var now: UInt64 = 1_000_000_000

        func read() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return now
        }

        func advance(seconds: Double) {
            lock.lock()
            now &+= UInt64(seconds * 1_000_000_000)
            lock.unlock()
        }
    }

    /// Reports itself as mid-drag, which is the only condition under which
    /// resizes coalesce — see `queueSizeChange`. AppKit sets `inLiveResize`
    /// during a real drag and there is no way to ask for it, so a test has to
    /// say so itself.
    private final class LiveResizingTerminalView: TerminalView {
        override var inLiveResize: Bool { true }
    }

    /// Builds a view driven by a manual tick source, so "one frame" is an
    /// explicit call rather than a wait on a display link.
    ///
    /// The terminal starts at `TerminalOptions`' 80x24 while the frame implies
    /// something smaller, so the first coalesced resize would be that settle
    /// rather than anything a test did. `processSizeChange` — the synchronous
    /// API, which still exists for exactly this — gets it out of the way first.
    private func makeView(delegate: TerminalViewDelegate)
        -> (TerminalView, ManualTickSource, TestClock)
    {
        let view = LiveResizingTerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 200),
            font: nil,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 100))
        view.frameDriver.invalidate()
        view.processSizeChange(newSize: view.frame.size)

        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        let clock = TestClock()
        driver.nowUptimeNs = { clock.read() }
        driver.onTick = { [weak view] in view?.frameTick() }
        view.frameDriver = driver
        view.terminalDelegate = delegate
        return (view, source, clock)
    }

    @Test func tenSizesBetweenTicksProduceOneResize() async {
        let delegate = SizeRecordingDelegate()
        let (view, source, clock) = makeView(delegate: delegate)
        _ = clock
        await drainMainQueue()
        delegate.sizes.removeAll()

        // Ten steps of a drag, no frame in between.
        var lastSize = CGSize.zero
        for step in 1...10 {
            lastSize = CGSize(width: 400 + CGFloat(step) * 17,
                              height: 200 + CGFloat(step) * 11)
            view.setFrameSize(lastSize)
        }
        #expect(delegate.sizes.isEmpty)

        await drainMainQueue()
        source.tick()
        await drainMainQueue()

        // One notification, carrying the last size, not the ten intermediates.
        #expect(delegate.sizes.count == 1)
        let expectedRows = Int(lastSize.height / view.cellDimension.height)
        let expectedCols = Int(view.getEffectiveWidth(size: lastSize) / view.cellDimension.width)
        #expect(delegate.sizes.first?.cols == expectedCols)
        #expect(delegate.sizes.first?.rows == expectedRows)

        // And the terminal agrees with what the host was told.
        let actual = view.withTerminal { ($0.cols, $0.rows) }
        #expect(actual.0 == expectedCols)
        #expect(actual.1 == expectedRows)
    }

    /// A resize with nothing else happening still reaches the host: the queue
    /// is useless if nothing comes to drain it.
    @Test func resizeAloneIsDelivered() async {
        let delegate = SizeRecordingDelegate()
        let (view, source, clock) = makeView(delegate: delegate)
        _ = clock
        await drainMainQueue()
        delegate.sizes.removeAll()

        view.setFrameSize(CGSize(width: 640, height: 480))
        await drainMainQueue()
        source.tick()
        await drainMainQueue()

        #expect(delegate.sizes.count == 1)
        let actual = view.withTerminal { ($0.cols, $0.rows) }
        #expect(delegate.sizes.first?.cols == actual.0)
        #expect(delegate.sizes.first?.rows == actual.1)
    }

    /// Re-applying a size the terminal already has notifies nobody. Written as
    /// "resize, then resize to the same thing" rather than as a sub-cell
    /// wobble: a wobble depends on the cell size and on whether the scroller is
    /// showing, and the first version of this test failed for that reason
    /// rather than for the behaviour it meant to check.
    /// Outside a live resize the old synchronous path is still in force, and
    /// deliberately so: deferring `sizeChanged` breaks host re-entrancy guards
    /// (see `queueSizeChange`). This pins that, because the failure it prevents
    /// showed up only as a stall number in a load case.
    @Test func outsideALiveResizeTheChangeIsSynchronous() async {
        let delegate = SizeRecordingDelegate()
        let view = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 200),
            font: nil,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 100))
        view.frameDriver.invalidate()
        view.processSizeChange(newSize: view.frame.size)
        view.terminalDelegate = delegate
        delegate.sizes.removeAll()

        // No frame tick anywhere in here.
        view.setFrameSize(CGSize(width: 640, height: 480))

        #expect(delegate.sizes.count == 1)
        let actual = view.withTerminal { ($0.cols, $0.rows) }
        #expect(delegate.sizes.first?.cols == actual.0)
    }

    @Test func repeatingTheSameSizeReportsOnce() async {
        let delegate = SizeRecordingDelegate()
        let (view, source, clock) = makeView(delegate: delegate)
        _ = clock
        await drainMainQueue()
        delegate.sizes.removeAll()

        let target = CGSize(width: 640, height: 480)
        view.setFrameSize(target)
        await drainMainQueue()
        source.tick()
        await drainMainQueue()
        #expect(delegate.sizes.count == 1)

        view.setFrameSize(target)
        await drainMainQueue()
        source.tick()
        await drainMainQueue()

        #expect(delegate.sizes.count == 1)
    }
}
#endif
