#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
struct FrameDriverTests {
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func snapshotText(_ row: TerminalSnapshot.Row, cols: Int) -> String {
        var result = ""
        var column = 0
        while column < min(cols, row.line.count) {
            let cell = row.line[column]
            result.append(row.character(at: column, cell: cell))
            column += max(1, Int(cell.width))
        }
        return result
    }

    @Test func markDirtyFloodConsumesOnePendingTick() async {
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        var tickCount = 0
        driver.onTick = { tickCount += 1 }

        for _ in 0..<1_000 {
            driver.markDirty()
        }
        await drainMainQueue()

        #expect(source.isRunning)
        #expect(source.startCount == 1)
        source.tick()
        source.tick()
        #expect(tickCount == 1)
        driver.invalidate()
    }

    @Test func idlePauseAndDirtyResume() async {
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        var tickCount = 0
        driver.onTick = { tickCount += 1 }

        driver.markDirty()
        await drainMainQueue()
        source.tick()
        for _ in 0..<FrameDriver.idleTickLimit {
            source.tick()
        }

        #expect(!source.isRunning)
        #expect(source.stopCount == 1)
        driver.markDirty()
        await drainMainQueue()
        #expect(source.isRunning)
        #expect(source.startCount == 2)
        source.tick()
        #expect(tickCount == 2)
        driver.invalidate()
    }

    @Test func immediateTickRequestsCoalesce() async {
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        var tickCount = 0
        driver.onTick = { tickCount += 1 }

        for _ in 0..<100 {
            driver.requestImmediateTick()
        }
        #expect(tickCount == 0)
        await drainMainQueue()

        #expect(tickCount == 1)
        #expect(source.startCount == 1)
        driver.invalidate()
    }

    /// io-gaps.md G4, WO-C6: the first frame after idle must not wait for the
    /// next vsync. Marking dirty while paused starts the link *and* ticks.
    @Test func markDirtyWhilePausedTicksImmediately() async {
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        var tickCount = 0
        driver.onTick = { tickCount += 1 }

        driver.markDirty()
        await drainMainQueue()

        // The tick came from the resume block, not from the tick source: no
        // one has called source.tick() yet.
        #expect(tickCount == 1)
        #expect(source.isRunning)

        // And the link is then driven normally.
        driver.markDirty()
        source.tick()
        #expect(tickCount == 2)
        driver.invalidate()
    }

    /// The resume tick is rate limited, so a producer that pauses and wakes the
    /// link repeatedly cannot drive frames faster than the display.
    @Test func resumeTicksAreRateLimited() async {
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        var tickCount = 0
        driver.onTick = { tickCount += 1 }
        // Frozen clock: the limit is what is under test, not the machine's
        // ability to run two statements inside 16 ms.
        driver.nowUptimeNs = { 1_000_000_000 }

        driver.markDirty()
        await drainMainQueue()
        #expect(tickCount == 1)

        // Idle the link out, then wake it again inside one frame period. The
        // resume runs, but the tick it would carry is suppressed.
        for _ in 0..<FrameDriver.idleTickLimit { source.tick() }
        #expect(!source.isRunning)

        driver.markDirty()
        await drainMainQueue()
        #expect(source.isRunning)
        #expect(tickCount == 1)

        // The frame still happens, at the display's cadence.
        source.tick()
        #expect(tickCount == 2)
        driver.invalidate()
    }

    @Test func noTickAfterInvalidate() async {
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        var tickCount = 0
        driver.onTick = { tickCount += 1 }

        driver.invalidate()
        driver.markDirty()
        driver.requestImmediateTick()
        await drainMainQueue()
        source.tick()

        #expect(tickCount == 0)
        #expect(!source.isRunning)
    }

    @Test func synchronizedOutputTickLeavesSnapshotUntouched() async throws {
        let view = TerminalView(
            frame: .zero,
            font: nil,
            options: TerminalOptions(cols: 20, rows: 4, scrollback: 20))
        view.frameDriver.invalidate()

        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        driver.onTick = { [weak view] in
            view?.frameTick()
        }
        view.frameDriver = driver

        view.feed(text: "stable")
        await drainMainQueue()
        source.tick()
        let row = try #require(view.currentSnapshot.rows.first)
        let captured = snapshotText(row, cols: view.currentSnapshot.cols)
        let revision = row.revision

        view.feed(text: "\u{1b}[?2026h-mutated")
        await drainMainQueue()
        source.tick()

        #expect(snapshotText(row, cols: view.currentSnapshot.cols) == captured)
        #expect(row.revision == revision)
        view.feed(text: "\u{1b}[?2026l")
        driver.invalidate()
    }
}
#endif
