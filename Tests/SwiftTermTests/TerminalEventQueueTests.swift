//
//  TerminalEventQueueTests.swift
//  SwiftTermTests
//
//  Covers the coalescing notification channel (io-gaps.md G6).
//

import Foundation
import Testing
@testable import SwiftTerm

#if os(macOS) || os(iOS) || os(visionOS)
@Suite("TerminalEventQueue")
struct TerminalEventQueueTests {
    /// The measured failure this type exists to prevent: thousands of posts
    /// from the parse thread while the main thread is busy must collapse into
    /// a single delivery, not thousands of main-queue blocks.
    ///
    /// Main is deliberately blocked on a semaphore here, so the main queue is
    /// never serviced during the burst. That is the real scenario — a busy
    /// main thread — and it makes the assertion exact instead of a race.
    @Test @MainActor func backgroundPostsCollapseWhileMainIsBusy() {
        let queue = TerminalEventQueue()
        queue.canDeliverInline = { false }
        let box = Box()
        queue.onDrain = { box.append($0) }

        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            for _ in 0..<10_000 {
                queue.post(.bufferActivated)
                queue.post(.mouseModeChanged)
                queue.post(.bell)
            }
            finished.signal()
        }
        thread.start()
        finished.wait()

        #expect(queue.posts == 30_000)
        #expect(queue.drains == 0)
        #expect(box.events.isEmpty)

        queue.drain()

        // One delivery per distinct event, from 30 000 posts.
        #expect(queue.drains == 1)
        #expect(box.events.count == 3)
        #expect(Set(box.events) == Set([.bufferActivated, .mouseModeChanged, .bell]))
    }

    @Test @MainActor func mainThreadPostsDeliverInline() {
        let queue = TerminalEventQueue()
        queue.canDeliverInline = { true }
        var seen: [TerminalEvent] = []
        queue.onDrain = { seen.append($0) }

        queue.post(.bell)
        #expect(seen == [.bell])
        queue.post(.bufferActivated)
        #expect(seen == [.bell, .bufferActivated])
    }

    /// A main-thread post must flush anything a background thread queued
    /// first, in enum order, so an inline delivery cannot jump the queue.
    @Test @MainActor func inlinePostFlushesQueuedEventsFirst() {
        let queue = TerminalEventQueue()
        queue.canDeliverInline = { false }
        var seen: [TerminalEvent] = []
        queue.onDrain = { seen.append($0) }

        queue.post(.bufferActivated)      // queued, drain scheduled
        #expect(seen.isEmpty)

        queue.canDeliverInline = { true }
        queue.post(.bell)
        #expect(seen == [.bufferActivated, .bell])
    }

    /// While the view holds the terminal lock, delivery must defer: view code
    /// must never run under that lock.
    @Test @MainActor func lockedViewDefersDelivery() {
        let queue = TerminalEventQueue()
        queue.canDeliverInline = { false }
        var seen: [TerminalEvent] = []
        queue.onDrain = { seen.append($0) }

        queue.post(.bell)
        #expect(seen.isEmpty)
        #expect(queue.pendingEventsForTesting == [.bell])

        queue.drain()
        #expect(seen == [.bell])
    }

    @Test @MainActor func drainWithNothingPendingIsHarmless() {
        let queue = TerminalEventQueue()
        var count = 0
        queue.onDrain = { _ in count += 1 }
        queue.drain()
        queue.drain()
        #expect(count == 0)
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TerminalEvent] = []
        var events: [TerminalEvent] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func append(_ event: TerminalEvent) {
            lock.lock(); storage.append(event); lock.unlock()
        }
    }
}
#endif
