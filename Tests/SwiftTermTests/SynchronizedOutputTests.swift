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
        private var _sentData: [[UInt8]] = []

        var synchronizedOutputChanges: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return _synchronizedOutputChanges
        }

        var sentData: [[UInt8]] {
            lock.lock()
            defer { lock.unlock() }
            return _sentData
        }

        func showCursor(source: Terminal) {}
        func hideCursor(source: Terminal) {}
        func setTerminalTitle(source: Terminal, title: String) {}
        func setTerminalIconTitle(source: Terminal, title: String) {}
        func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { return nil }
        func sizeChanged(source: Terminal) {}
        func send(source: Terminal, data: ArraySlice<UInt8>) {
            lock.lock()
            _sentData.append(Array(data))
            lock.unlock()
        }
        func bufferActivated(source: Terminal) {}
        func synchronizedOutputChanged(source: Terminal, active: Bool) {
            lock.lock()
            _synchronizedOutputChanges.append(active)
            lock.unlock()
            syncChangeHandler?(active)
        }
        func bell(source: Terminal) {}

        func clearSentData() {
            lock.lock()
            _sentData.removeAll()
            lock.unlock()
        }
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

    @Test func balancedWindowInOneFeedDoesNotArmWatchdog() {
        let delegate = TestDelegate()
        let terminal = Terminal(delegate: delegate)
        let esc = "\u{1b}"

        terminal.feed(text: "\(esc)[?2026h\(esc)[?2026l")

        #expect(!terminal.synchronizedOutputActive)
        #expect(terminal.synchronizedOutputGeneration == 1)
        #expect(terminal.synchronizedOutputWatchdogCounters.armed == 0)
        #expect(terminal.synchronizedOutputWatchdogCounters.rearmed == 0)
        #expect(terminal.synchronizedOutputWatchdogCounters.cancelled == 0)
        #expect(terminal.synchronizedOutputWatchdogCounters.fired == 0)
        #expect(delegate.synchronizedOutputChanges == [true, false])
    }

    @Test func unmatchedEnableArmsOnceAfterFeed() {
        let delegate = TestDelegate()
        let terminal = Terminal(delegate: delegate)
        terminal.synchronizedOutputTimeoutSeconds = 60

        terminal.feed(text: "\u{1b}[?2026h")

        #expect(terminal.synchronizedOutputActive)
        #expect(terminal.synchronizedOutputWatchdogCounters.armed == 1)
        #expect(terminal.synchronizedOutputWatchdogCounters.rearmed == 0)
        terminal.feed(text: "\u{1b}[?2026l")
    }

    @Test func twoEnablesInOneFeedArmLatestGenerationOnce() {
        let delegate = TestDelegate()
        let terminal = Terminal(delegate: delegate)
        terminal.synchronizedOutputTimeoutSeconds = 60
        let esc = "\u{1b}"

        terminal.feed(text: "\(esc)[?2026h\(esc)[?2026h")

        #expect(terminal.synchronizedOutputActive)
        #expect(terminal.synchronizedOutputGeneration == 2)
        #expect(terminal.synchronizedOutputWatchdogCounters.armed == 1)
        #expect(terminal.synchronizedOutputWatchdogCounters.rearmed == 0)
        #expect(delegate.synchronizedOutputChanges == [true])
        terminal.feed(text: "\(esc)[?2026l")
    }

    @Test func enableDisableEnableInOneFeedArmsOnce() {
        let delegate = TestDelegate()
        let terminal = Terminal(delegate: delegate)
        terminal.synchronizedOutputTimeoutSeconds = 60
        let esc = "\u{1b}"

        terminal.feed(text: "\(esc)[?2026h\(esc)[?2026l\(esc)[?2026h")

        #expect(terminal.synchronizedOutputActive)
        #expect(terminal.synchronizedOutputGeneration == 2)
        #expect(terminal.synchronizedOutputWatchdogCounters.armed == 1)
        #expect(terminal.synchronizedOutputWatchdogCounters.rearmed == 0)
        #expect(delegate.synchronizedOutputChanges == [true, false, true])
        terminal.feed(text: "\(esc)[?2026l")
    }

    @Test func laterDisableCancelsAndClearsWatchdog() {
        let delegate = TestDelegate()
        let terminal = Terminal(delegate: delegate)
        terminal.synchronizedOutputTimeoutSeconds = 60
        let esc = "\u{1b}"

        terminal.feed(text: "\(esc)[?2026h")
        terminal.feed(text: "\(esc)[?2026l")

        #expect(!terminal.synchronizedOutputActive)
        #expect(terminal.synchronizedOutputWatchdogCounters.armed == 1)
        #expect(terminal.synchronizedOutputWatchdogCounters.cancelled == 1)

        terminal.feed(text: "\(esc)[?2026h")
        #expect(terminal.synchronizedOutputWatchdogCounters.armed == 2)
        #expect(terminal.synchronizedOutputWatchdogCounters.rearmed == 0)
        terminal.feed(text: "\(esc)[?2026l")
    }

    @Test func repeatedEnableInLaterFeedRearmsWatchdog() {
        let delegate = TestDelegate()
        let terminal = Terminal(delegate: delegate)
        terminal.synchronizedOutputTimeoutSeconds = 60
        let esc = "\u{1b}"

        terminal.feed(text: "\(esc)[?2026h")
        terminal.feed(text: "\(esc)[?2026h")

        #expect(terminal.synchronizedOutputActive)
        #expect(terminal.synchronizedOutputGeneration == 2)
        #expect(terminal.synchronizedOutputWatchdogCounters.armed == 1)
        #expect(terminal.synchronizedOutputWatchdogCounters.rearmed == 1)
        #expect(delegate.synchronizedOutputChanges == [true])
        terminal.feed(text: "\(esc)[?2026l")
    }

    @Test func staleGenerationCannotClearNewerWindow() {
        let delegate = TestDelegate()
        let terminal = Terminal(delegate: delegate)
        terminal.synchronizedOutputTimeoutSeconds = 60
        let esc = "\u{1b}"

        terminal.feed(text: "\(esc)[?2026h")
        let oldGeneration = terminal.synchronizedOutputGeneration
        terminal.feed(text: "\(esc)[?2026h")
        terminal.synchronizedOutputWatchdogFired(generation: oldGeneration)

        #expect(terminal.synchronizedOutputActive)
        #expect(terminal.synchronizedOutputGeneration == oldGeneration &+ 1)
        #expect(terminal.synchronizedOutputWatchdogCounters.fired == 0)
        #expect(delegate.synchronizedOutputChanges == [true])
        terminal.feed(text: "\(esc)[?2026l")
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

    @Test func decrqmTracksSetResetAndWatchdogLifecycle() {
        let delegate = TestDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 20, rows: 5, scrollback: 0)
        )
        terminal.synchronizedOutputTimeoutSeconds = 0.1
        let esc = "\u{1b}"

        terminal.feed(text: "\(esc)[?2026$p")
        terminal.feed(text: "\(esc)[?2026h\(esc)[?2026$p")
        terminal.feed(text: "\(esc)[?2026l\(esc)[?2026$p")

        let syncEnded = DispatchSemaphore(value: 0)
        delegate.syncChangeHandler = { active in
            if !active {
                syncEnded.signal()
            }
        }
        terminal.feed(text: "\(esc)[?2026h")
        #expect(syncEnded.wait(timeout: .now() + 2) == .success)
        #expect(delegate.sentData.count == 3)
        terminal.feed(text: "\(esc)[?2026$p")

        let responses = delegate.sentData.map { String(decoding: $0, as: UTF8.self) }
        #expect(responses == [
            "\(esc)[?2026;2$y",
            "\(esc)[?2026;1$y",
            "\(esc)[?2026;2$y",
            "\(esc)[?2026;2$y",
        ])
    }

    @Test func saveResetThenRestoreEndsSynchronizedOutput() {
        let terminal = Terminal(
            delegate: TestDelegate(),
            options: TerminalOptions(cols: 20, rows: 5, scrollback: 0)
        )
        terminal.synchronizedOutputTimeoutSeconds = 60
        let esc = "\u{1b}"

        terminal.feed(text: "\(esc)[?2026s")
        terminal.feed(text: "\(esc)[?2026h\(esc)[?2026r")

        #expect(!terminal.synchronizedOutputActive)
    }

    @Test func restoreSetStartsAndRestartsWatchdog() {
        let terminal = Terminal(
            delegate: TestDelegate(),
            options: TerminalOptions(cols: 20, rows: 5, scrollback: 0)
        )
        terminal.synchronizedOutputTimeoutSeconds = 60
        let esc = "\u{1b}"

        terminal.feed(text: "\(esc)[?2026h\(esc)[?2026s\(esc)[?2026l")
        terminal.feed(text: "\(esc)[?2026r")
        terminal.feed(text: "\(esc)[?2026r")

        #expect(terminal.synchronizedOutputActive)
        #expect(terminal.synchronizedOutputGeneration == 3)
        #expect(terminal.synchronizedOutputWatchdogCounters.armed == 1)
        #expect(terminal.synchronizedOutputWatchdogCounters.rearmed == 1)
        terminal.feed(text: "\(esc)[?2026l")
    }

    @Test func sameGridResizeResetsSynchronizedOutput() {
        let terminal = Terminal(
            delegate: TestDelegate(),
            options: TerminalOptions(cols: 20, rows: 5, scrollback: 0)
        )
        terminal.synchronizedOutputTimeoutSeconds = 60
        terminal.feed(text: "\u{1b}[?2026h")

        terminal.resize(cols: terminal.cols, rows: terminal.rows)

        #expect(!terminal.synchronizedOutputActive)
        #expect(terminal.synchronizedOutputWatchdogCounters.armed == 1)
        #expect(terminal.synchronizedOutputWatchdogCounters.cancelled == 1)
    }

    @Test func risResetsModeAndClearsSavedSlot() {
        let terminal = Terminal(
            delegate: TestDelegate(),
            options: TerminalOptions(cols: 20, rows: 5, scrollback: 0)
        )
        terminal.synchronizedOutputTimeoutSeconds = 60
        let esc = "\u{1b}"

        terminal.feed(text: "\(esc)[?2026h\(esc)[?2026s")
        terminal.feed(text: "\(esc)c")
        #expect(!terminal.synchronizedOutputActive)
        #expect(terminal.synchronizedOutputWatchdogCounters.armed == 1)
        #expect(terminal.synchronizedOutputWatchdogCounters.cancelled == 1)

        terminal.feed(text: "\(esc)[?2026h\(esc)[?2026r")
        #expect(!terminal.synchronizedOutputActive)
    }

#if !os(iOS) && !os(Windows)
    @Test func headlessTerminalKeepsSafetyWatchdog() {
        let headless = HeadlessTerminal { _ in }
        headless.terminal.terminalLock.withLock {
            headless.terminal.synchronizedOutputTimeoutSeconds = 60
            headless.terminal.feed(text: "\u{1b}[?2026h")
        }
        #expect(headless.terminal.synchronizedOutputActive)
        #expect(headless.terminal.synchronizedOutputGeneration == 1)
        #expect(headless.terminal.synchronizedOutputWatchdogCounters.armed == 1)

        headless.terminal.terminalLock.withLock {
            headless.terminal.feed(text: "\u{1b}[?2026l")
        }
        #expect(!headless.terminal.synchronizedOutputActive)
        #expect(headless.terminal.synchronizedOutputWatchdogCounters.cancelled == 1)
        #expect(headless.terminal.synchronizedOutputWatchdogCounters.fired == 0)
    }
#endif

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
        let terminal = ViewTerminal(
            delegate: delegate,
            options: TerminalOptions(cols: 40, rows: 5, scrollback: 20),
            synchronizedOutputWatchdogHandler: { _, _ in }
        ) { terminal in
            delegate.scrolledPositions.append(terminal.buffer.yDisp)
        }
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
        let access = LockedTerminalTestAccess(terminal)
        delegate.syncChangeHandler = { active in
            if !active {
                syncEnded.signal()
            }
        }

        DispatchQueue.global().async {
            access.withLock { terminal in
                terminal.feed(text: "\(esc)[?2026h")
            }
            finished.signal()
        }

        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(terminal.terminalLock.withLock { terminal.synchronizedOutputActive })

        // The timeout no longer runs on the main queue (io-gaps.md G5c), but
        // keep the generous bound: under TSan everything is slower.
        #expect(syncEnded.wait(timeout: .now() + 10) == .success)

        #expect(!terminal.terminalLock.withLock { terminal.synchronizedOutputActive })
        #expect(delegate.synchronizedOutputChanges.contains(true))
        #expect(delegate.synchronizedOutputChanges.contains(false))
        #expect(terminal.synchronizedOutputWatchdogCounters.fired == 1)
        #expect(terminal.synchronizedOutputWatchdogCounters.cancelled == 0)
    }

    /// io-gaps.md G5c: the reset is the safety valve for an application that
    /// sets DECSET 2026 and never clears it. Blocking the main thread is
    /// exactly the situation it exists for, so it must not be scheduled there.
    ///
    /// This test failed before the move, which is the only reason it is worth
    /// keeping: with the timeout on the main queue it did not fire until the
    /// block released.
    @Test func testSynchronizedOutputTimeoutFiresWhileMainThreadIsBlocked() {
        let delegate = TestDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 40, rows: 5, scrollback: 20)
        )
        // Short, so the main queue is blocked for a fraction of a second
        // rather than seconds: other suites run in parallel and every
        // @MainActor test among them shares this queue. The first version used
        // the production 1 s and starved an unrelated FrameDriver test past
        // its own sync-output deadline.
        terminal.synchronizedOutputTimeoutSeconds = 0.2
        let esc = "\u{1b}"
        let syncEnded = DispatchSemaphore(value: 0)
        delegate.syncChangeHandler = { active in
            if !active {
                syncEnded.signal()
            }
        }

        terminal.terminalLock.withLock {
            terminal.feed(text: "\(esc)[?2026h")
        }
        #expect(terminal.terminalLock.withLock { terminal.synchronizedOutputActive })

        // Block the main queue for longer than the 1 s timeout. The reset has
        // to fire from somewhere else, while this block is still sitting on
        // main, or the display an application froze stays frozen.
        let blockReleased = DispatchSemaphore(value: 0)
        let mainIsBlocked = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            mainIsBlocked.signal()
            // Not a sleep on the test's own thread: the point is that the
            // *main queue* cannot run anything for this long.
            _ = blockReleased.wait(timeout: .now() + 2)
        }
        #expect(mainIsBlocked.wait(timeout: .now() + 5) == .success)

        let firedWhileBlocked = syncEnded.wait(timeout: .now() + 1.0) == .success
        blockReleased.signal()

        #expect(firedWhileBlocked)
        #expect(!terminal.terminalLock.withLock { terminal.synchronizedOutputActive })
    }

    // MARK: - View-level regression tests

#if os(macOS)
    @MainActor
    private func makeViewTerminalPipeline(delegate: TestDelegate)
        -> (owner: TerminalRenderOwner, terminal: ViewTerminal)
    {
        let owner = TerminalRenderOwner()
        let terminal = ViewTerminal(
            delegate: delegate,
            options: TerminalOptions(cols: 40, rows: 5, scrollback: 20),
            synchronizedOutputWatchdogHandler:
                owner.synchronizedOutputWatchdogHandler()
        ) { _ in }
        let selection = terminal.terminalLock.withLock {
            SelectionService(terminal: terminal)
        }
        let search = SearchService(terminal: terminal)
        owner.attach(terminal: terminal, selection: selection, search: search)
        return (owner, terminal)
    }

    @Test func staleDisarmDoesNotClearNewerArmedGeneration() {
        let target = SynchronizedOutputWatchdog.Target()
        let terminal = Terminal(delegate: TestDelegate())
        var disarmCount = 0
        target.attach(terminal: terminal) {}

        target.update(
            active: true,
            generation: 2,
            timeout: 60,
            arm: { _ in },
            disarm: {})
        target.update(
            active: false,
            generation: 1,
            timeout: 60,
            arm: { _ in },
            disarm: { disarmCount += 1 })

        #expect(target.counters.armed == 1)
        #expect(target.counters.cancelled == 0)
        #expect(disarmCount == 0)

        target.update(
            active: false,
            generation: 2,
            timeout: 60,
            arm: { _ in },
            disarm: { disarmCount += 1 })

        #expect(target.counters.cancelled == 1)
        #expect(disarmCount == 1)
    }

    @Test func staleArmDoesNotRearmWithOlderGeneration() {
        let target = SynchronizedOutputWatchdog.Target()
        let terminal = Terminal(delegate: TestDelegate())
        var armCount = 0
        target.attach(terminal: terminal) {}

        target.update(
            active: true,
            generation: 6,
            timeout: 60,
            arm: { _ in armCount += 1 },
            disarm: {})
        target.update(
            active: true,
            generation: 5,
            timeout: 60,
            arm: { _ in armCount += 1 },
            disarm: {})

        #expect(target.counters.armed == 1)
        #expect(target.counters.rearmed == 0)
        #expect(armCount == 1)

        target.update(
            active: true,
            generation: 7,
            timeout: 60,
            arm: { _ in armCount += 1 },
            disarm: {})

        #expect(target.counters.rearmed == 1)
        #expect(armCount == 2)
    }

    @MainActor
    @Test func earlyWatchdogFireDoesNotEndRearmedWindow() async throws {
        let delegate = TestDelegate()
        let (owner, terminal) = makeViewTerminalPipeline(delegate: delegate)
        terminal.terminalLock.withLock {
            terminal.synchronizedOutputTimeoutSeconds = 60
        }

        _ = owner.feed(text: "\u{1b}[?2026h")
        owner.synchronizedOutputWatchdog.fireForTesting()

        #expect(terminal.terminalLock.withLock { terminal.synchronizedOutputActive })
        #expect(owner.synchronizedOutputWatchdog.counters.fired == 0)

        terminal.terminalLock.withLock {
            terminal.synchronizedOutputTimeoutSeconds = 0.05
        }
        _ = owner.feed(text: "\u{1b}[?2026h")

        // Poll instead of a semaphore wait: a blocked main thread starves
        // other suites' main-queue work and makes them time out.
        try await waitForSynchronizedOutputEnd(terminal)
        #expect(!terminal.terminalLock.withLock { terminal.synchronizedOutputActive })
        #expect(owner.synchronizedOutputWatchdog.counters.fired == 1)
    }

    @MainActor
    private func waitForSynchronizedOutputEnd(_ terminal: Terminal) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while terminal.terminalLock.withLock({ terminal.synchronizedOutputActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    @Test func viewPipelineTracksOneArmedWatchdogAcrossRearms() {
        let delegate = TestDelegate()
        let (owner, terminal) = makeViewTerminalPipeline(delegate: delegate)
        terminal.terminalLock.withLock {
            terminal.synchronizedOutputTimeoutSeconds = 60
        }
        let esc = "\u{1b}"

        _ = owner.feed(text: "\(esc)[?2026h")
        _ = owner.feed(text: "\(esc)[?2026h")
        _ = owner.feed(text: "\(esc)[?2026h")
        _ = owner.feed(text: "\(esc)[?2026l")

        let compatibilityCounters = terminal.terminalLock.withLock {
            terminal.synchronizedOutputWatchdogCounters
        }
        #expect(compatibilityCounters.armed == 0)
        #expect(compatibilityCounters.rearmed == 0)
        #expect(compatibilityCounters.cancelled == 0)
        #expect(compatibilityCounters.fired == 0)

        let counters = owner.synchronizedOutputWatchdog.counters
        #expect(counters.armed == 1)
        #expect(counters.rearmed == 2)
        #expect(counters.cancelled == 1)
        #expect(counters.fired == 0)
    }

    @MainActor
    @Test func renderOwnerTeardownInvalidatesWatchdogTarget() {
        let delegate = TestDelegate()
        var pipeline: (owner: TerminalRenderOwner, terminal: ViewTerminal)? =
            makeViewTerminalPipeline(delegate: delegate)
        pipeline!.terminal.terminalLock.withLock {
            pipeline!.terminal.synchronizedOutputTimeoutSeconds = 60
        }
        _ = pipeline!.owner.feed(text: "\u{1b}[?2026h")

        let watchdog = pipeline!.owner.synchronizedOutputWatchdog
        pipeline = nil

        #expect(watchdog.target.terminal == nil)
    }

    @MainActor
    @Test func lateWatchdogFireAfterInvalidationDoesNotTouchTerminal() {
        let delegate = TestDelegate()
        let (owner, terminal) = makeViewTerminalPipeline(delegate: delegate)
        terminal.terminalLock.withLock {
            terminal.synchronizedOutputTimeoutSeconds = 60
        }
        _ = owner.feed(text: "\u{1b}[?2026h")

        owner.synchronizedOutputWatchdog.invalidate()
        let firedBefore = owner.synchronizedOutputWatchdog.counters.fired
        owner.synchronizedOutputWatchdog.fireForTesting()

        #expect(terminal.terminalLock.withLock { terminal.synchronizedOutputActive })
        #expect(delegate.synchronizedOutputChanges == [true])
        #expect(owner.synchronizedOutputWatchdog.counters.fired == firedBefore)
        _ = owner.feed(text: "\u{1b}[?2026l")
    }

    @MainActor
    @Test func invalidatedWatchdogDoesNotRetainTerminal() {
        let delegate = TestDelegate()
        weak var weakTerminal: Terminal?
        var watchdog: SynchronizedOutputWatchdog?

        autoreleasepool {
            var pipeline: (owner: TerminalRenderOwner, terminal: ViewTerminal)? =
                makeViewTerminalPipeline(delegate: delegate)
            pipeline!.terminal.terminalLock.withLock {
                pipeline!.terminal.synchronizedOutputTimeoutSeconds = 60
            }
            _ = pipeline!.owner.feed(text: "\u{1b}[?2026h")
            weakTerminal = pipeline!.terminal
            watchdog = pipeline!.owner.synchronizedOutputWatchdog
            pipeline = nil
        }

        #expect(watchdog?.target.terminal == nil)
        #expect(weakTerminal == nil)
    }

    @MainActor
    @Test func viewPipelineTimeoutEndsSynchronizedOutputWithoutAnotherFeed() async throws {
        let delegate = TestDelegate()
        let (owner, terminal) = makeViewTerminalPipeline(delegate: delegate)
        terminal.terminalLock.withLock {
            terminal.synchronizedOutputTimeoutSeconds = 0.05
        }

        _ = owner.feed(text: "\u{1b}[?2026h")

        // Poll instead of a semaphore wait: a blocked main thread starves
        // other suites' main-queue work and makes them time out.
        try await waitForSynchronizedOutputEnd(terminal)
        #expect(!terminal.terminalLock.withLock { terminal.synchronizedOutputActive })
        #expect(delegate.synchronizedOutputChanges == [true, false])
        #expect(terminal.synchronizedOutputWatchdogCounters.armed == 0)
        #expect(terminal.synchronizedOutputWatchdogCounters.rearmed == 0)
        #expect(terminal.synchronizedOutputWatchdogCounters.cancelled == 0)
        #expect(terminal.synchronizedOutputWatchdogCounters.fired == 1)
        #expect(owner.synchronizedOutputWatchdog.counters.fired == 1)
    }

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

        view.frameTick()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))

        #expect(delegate.scrolledCount > 0)
    }
#endif
}
