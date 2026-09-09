//
//  RenderLoopTests.swift
//  SwiftTermTests
//
//  Covers the render loop's contract: it coalesces, it runs one frame at a
//  time, and it stops cleanly (io-gaps.md G1, WO-F4).
//

#if os(macOS)
import Testing
import Foundation
@testable import SwiftTerm

@Suite(.serialized)
struct RenderLoopTests {

    /// Waits for `condition` to hold, polling. Returns false on timeout.
    private func waitUntil (timeout: TimeInterval = 2.0,
                            _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(2000)
        }
        return condition()
    }

    @Test func signalRunsAFrame () {
        let counter = Counter()
        let loop = RenderLoop { counter.increment() }
        loop.start()
        defer { loop.invalidate() }

        loop.signal()
        #expect(waitUntil { counter.value >= 1 })
        #expect(counter.value == 1)
    }

    @Test func signalsCoalesceWhileAFrameIsRunning () {
        let counter = Counter()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let loop = RenderLoop {
            counter.increment()
            if counter.value == 1 {
                started.signal()
                release.wait()
            }
        }
        loop.start()
        defer {
            release.signal()
            loop.invalidate()
        }

        loop.signal()
        #expect(started.wait(timeout: .now() + 2) == .success)

        // Five signals arrive while the first frame is stuck. They must
        // produce exactly one more frame, not five.
        for _ in 0..<5 { loop.signal() }
        release.signal()

        #expect(waitUntil { counter.value >= 2 })
        // Give a spurious extra frame a chance to show up before asserting.
        usleep(50_000)
        #expect(counter.value == 2)
        #expect(loop.currentCounters.coalesced == 4)
    }

    @Test func noFrameAfterInvalidate () {
        let counter = Counter()
        let loop = RenderLoop { counter.increment() }
        loop.start()

        loop.signal()
        #expect(waitUntil { counter.value >= 1 })
        loop.invalidate()

        let after = counter.value
        for _ in 0..<10 { loop.signal() }
        usleep(50_000)
        #expect(counter.value == after)
        #expect(loop.isRunning == false)
    }

    @Test func startAfterInvalidateDoesNothing () {
        let counter = Counter()
        let loop = RenderLoop { counter.increment() }
        loop.invalidate()
        loop.start()
        loop.signal()
        usleep(50_000)
        #expect(counter.value == 0)
        #expect(loop.isRunning == false)
    }

    @Test func invalidateWaitsForAFrameInFlight () {
        let started = DispatchSemaphore(value: 0)
        let finished = Counter()
        let loop = RenderLoop {
            started.signal()
            usleep(100_000)
            finished.increment()
        }
        loop.start()
        loop.signal()
        #expect(started.wait(timeout: .now() + 2) == .success)

        // The caller is usually about to tear down the surface the frame is
        // drawing into, so invalidate must not return before it completes.
        loop.invalidate()
        #expect(finished.value == 1)
    }

    @Test func frameLockExcludesRendering () {
        let inFrame = Counter()
        let overlaps = Counter()
        let loop = RenderLoop {
            if inFrame.increment() != 1 { overlaps.increment() }
            usleep(5_000)
            _ = inFrame.decrement()
        }
        loop.start()
        defer { loop.invalidate() }

        for _ in 0..<20 {
            loop.signal()
            loop.frameLock.lock()
            // Holding frameLock means no frame is running.
            #expect(inFrame.value == 0)
            loop.frameLock.unlock()
            usleep(1000)
        }
        #expect(overlaps.value == 0)
    }
}

/// A lock-guarded counter; the loop writes it from the render thread while the
/// test reads it.
private final class Counter: Sendable {
    private let count = Locked(0)

    var value: Int {
        count.withLock { $0 }
    }

    @discardableResult
    func increment () -> Int {
        count.withLock {
            $0 += 1
            return $0
        }
    }

    @discardableResult
    func decrement () -> Int {
        count.withLock {
            $0 -= 1
            return $0
        }
    }
}
#endif
