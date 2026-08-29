#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
struct FrameDriverTests {
    private func requireSendable<T: Sendable>(_ type: T.Type) {}

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    @Test func producerSignalIsCheckedSendable() {
        requireSendable(FrameDriverSignal.self)
    }

    @Test func eventsPublishedBeforeConfigurationAreDelivered() async {
        let dirtySignal = FrameDriverSignal()
        let shutdownSignal = FrameDriverSignal()
        let dirtyDeliveries = Locked(0)
        let shutdownDeliveries = Locked(0)

        dirtySignal.markDirty()
        shutdownSignal.requestShutdown()
        dirtySignal.configure { dirtyDeliveries.withLock { $0 += 1 } }
        shutdownSignal.configure { shutdownDeliveries.withLock { $0 += 1 } }
        await drainMainQueue()

        #expect(dirtyDeliveries.withLock { $0 } == 1)
        #expect(shutdownDeliveries.withLock { $0 } == 1)
    }

    @Test func backgroundDirtyFloodPublishesOneFrame() async {
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        let signal = driver.signal
        var tickCount = 0
        driver.onTick = { tickCount += 1 }

        await Task.detached {
            for _ in 0..<1_000 {
                signal.markDirty()
            }
        }.value
        await drainMainQueue()

        #expect(tickCount == 1)
        #expect(source.startCount == 1)
        driver.shutdown()
    }

    @Test func backgroundImmediateRequestsCoalesce() async {
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        let signal = driver.signal
        var tickCount = 0
        driver.onTick = { tickCount += 1 }

        // Keep the main actor occupied until the producer queue publishes the
        // full burst. Awaiting a producer task lets the main actor consume
        // events during the burst, so the result depends on scheduler timing.
        let producerQueue = DispatchQueue(
            label: "swiftterm-frame-driver-immediate-producer-test")
        producerQueue.sync {
            for _ in 0..<100 {
                signal.requestImmediateTick()
            }
        }
        #expect(tickCount == 0)
        await drainMainQueue()

        #expect(tickCount == 1)
        #expect(source.startCount == 1)
        driver.shutdown()
    }

    @Test func backgroundShutdownRejectsLaterDirtyWork() async {
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        let signal = driver.signal
        var tickCount = 0
        driver.onTick = { tickCount += 1 }

        signal.markDirty()
        await drainMainQueue()
        #expect(tickCount == 1)

        await Task.detached {
            signal.requestShutdown()
            signal.markDirty()
            signal.requestImmediateTick()
        }.value
        await drainMainQueue()
        source.tick()

        #expect(tickCount == 1)
        #expect(!source.isRunning)
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

    @Test func markDirtyWhileRunningWaitsForDisplayTick() async {
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        var tickCount = 0
        var now: UInt64 = 1_000_000_000
        driver.nowUptimeNs = { now }
        driver.onTick = { tickCount += 1 }

        driver.markDirty()
        await drainMainQueue()
        #expect(tickCount == 1)
        #expect(source.isRunning)

        now += 20_000_000
        driver.markDirty()
        await drainMainQueue()
        #expect(tickCount == 1)

        source.tick()
        #expect(tickCount == 2)
        driver.shutdown()
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

    /// io-gaps.md G8b: a terminal nobody can see produces no ticks. Covers
    /// occlusion, miniaturisation and application hiding alike — each of those
    /// notifications lands on the same decision.
    @Test func suspendedVisibilityStopsTicking() async {
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        var tickCount = 0
        driver.onTick = { tickCount += 1 }

        driver.markDirty()
        await drainMainQueue()
        #expect(tickCount == 1)
        #expect(source.isRunning)

        driver.setVisibilityOnMain(visible: false)
        #expect(driver.isVisibilitySuspended)
        #expect(!source.isRunning)

        // A flood while hidden must not restart the link.
        for _ in 0..<100 { driver.markDirty() }
        await drainMainQueue()
        #expect(!source.isRunning)
        #expect(tickCount == 1)

        driver.invalidate()
    }

    @Test func visibilitySuspensionCanBeDisabled() async {
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        var tickCount = 0
        driver.onTick = { tickCount += 1 }

        driver.setVisibilitySuspensionEnabledOnMain(false)
        driver.setVisibilityOnMain(visible: false)
        #expect(!driver.isVisibilitySuspended)

        driver.markDirty()
        await drainMainQueue()
        #expect(source.isRunning)
        #expect(tickCount == 1)

        driver.setVisibilitySuspensionEnabledOnMain(true)
        #expect(driver.isVisibilitySuspended)
        #expect(!source.isRunning)
        driver.invalidate()
    }

    /// Becoming visible again resumes, and the first tick draws the state that
    /// accumulated while hidden.
    @Test func becomingVisibleResumesAndDrawsCurrentState() async {
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        var tickCount = 0
        driver.onTick = { tickCount += 1 }

        driver.setVisibilityOnMain(visible: false)
        driver.markDirty()
        await drainMainQueue()
        #expect(tickCount == 0)

        driver.setVisibilityOnMain(visible: true)
        await drainMainQueue()
        #expect(source.isRunning)
        // One frame covers everything that changed while hidden: the driver
        // coalesces to a dirty flag, not a queue of pending frames.
        #expect(tickCount == 1)

        driver.invalidate()
    }

    /// Visible-again with nothing pending must not draw. Resume goes through
    /// the dirty flag rather than forcing a frame.
    @Test func becomingVisibleWithNothingDirtyDoesNotDraw() async {
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        var tickCount = 0
        driver.onTick = { tickCount += 1 }

        driver.setVisibilityOnMain(visible: false)
        driver.setVisibilityOnMain(visible: true)
        await drainMainQueue()

        #expect(tickCount == 0)
        #expect(!source.isRunning)
        driver.invalidate()
    }

    /// Window removal is reversible and combines with application visibility.
    /// Neither input can resume the driver while the other remains hidden.
    @Test func windowAttachmentCombinesWithApplicationVisibility() async {
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        var tickCount = 0
        driver.onTick = { tickCount += 1 }

        driver.setWindowAttachedOnMain(false)
        driver.markDirty()
        await drainMainQueue()
        #expect(driver.isVisibilitySuspended)
        #expect(!source.isRunning)
        #expect(tickCount == 0)

        driver.setVisibilityOnMain(visible: false)
        driver.setWindowAttachedOnMain(true)
        #expect(driver.isVisibilitySuspended)
        #expect(tickCount == 0)

        driver.setVisibilityOnMain(visible: true)
        #expect(!driver.isVisibilitySuspended)
        #expect(source.isRunning)
        #expect(tickCount == 1)

        driver.setWindowAttachedOnMain(false)
        #expect(!source.isRunning)
        driver.markDirty()
        await drainMainQueue()
        #expect(!source.isRunning)
        driver.setWindowAttachedOnMain(true)
        #expect(source.isRunning)
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

        // The sync-output valve must not open in the middle of this test: it
        // asserts the snapshot stays frozen *while* 2026 is set, and a 1 s
        // default is easily reached when suites run in parallel.
        view.withTerminal { $0.synchronizedOutputTimeoutSeconds = 60 }
        view.feed(text: "stable")
        await drainMainQueue()
        source.tick()
        let captured = view.renderOwner.inspection()
        let capturedText = try #require(captured.rowTexts.first)
        let revision = try #require(captured.rowRevisions.first)

        view.feed(text: "\u{1b}[?2026h-mutated")
        await drainMainQueue()
        source.tick()

        let frozen = view.renderOwner.inspection()
        #expect(frozen.rowTexts.first == capturedText)
        #expect(frozen.rowRevisions.first == revision)
        view.feed(text: "\u{1b}[?2026l")
        driver.invalidate()
    }
}
#endif
