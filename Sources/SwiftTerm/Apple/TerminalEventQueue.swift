//
//  TerminalEventQueue.swift
//  SwiftTerm
//
//  Coalescing channel for idempotent terminal notifications (io-gaps.md G6).
//
//  The problem it solves, measured on `cat` of 256 MB of random bytes:
//  `bufferActivated` and `mouseModeChanged` each fired 4 708 times, and every
//  one posted its own `DispatchQueue.main.async` block that then took the
//  terminal lock. The main thread's lock *holds* totalled 69 ms while its
//  *waits* totalled 12.4 seconds, because each of ~600 acquisitions per frame
//  queued behind a 3 ms parse batch.
//
//  These notifications are state edges, not history: the view only needs to
//  know the buffer changed, never how many times. So the parse thread sets a
//  bit and, only when no drain is already scheduled, posts a single main-queue
//  block. While that block is pending, every further notification is a lock and
//  a bitwise or.
//
//  This is Ghostty's `surfaceMessageWriter(.ring_bell)` shape — push a
//  payloadless value and forget — with collapsing added, which its 64-slot
//  mailbox does not do.
//

import Foundation

/// A notification that can be collapsed: repeated occurrences within one
/// delivery window are indistinguishable from a single one.
///
/// Only add cases here that are genuinely idempotent. Anything carrying a
/// payload that the view must see every time (bytes to send, a resize) does not
/// belong in this queue.
enum TerminalEvent: Int, CaseIterable {
    /// The active buffer changed (normal <-> alternate).
    case bufferActivated = 0
    /// Mouse reporting mode changed.
    case mouseModeChanged = 1
    /// A BEL was received. Collapsing matches the debounce that follows it.
    case bell = 2

    fileprivate var mask: UInt32 { 1 << UInt32(rawValue) }
}

/// Thread-safe, allocation-free coalescing queue.
final class TerminalEventQueue {
    private let lock = NSLock()
    private var pending: UInt32 = 0
    private var drainScheduled = false

    /// The view installs a handler that applies one event on the main thread.
    var onDrain: ((TerminalEvent) -> Void)?

    /// Answers whether a main-thread post may be delivered inline.
    ///
    /// The view returns false while it holds the terminal lock, because a
    /// delegate callback can fire under the lock even on the main thread and
    /// view code must never run there. Same rule `onMain` applies.
    var canDeliverInline: (() -> Bool)?

    /// Diagnostics: how many posts arrived, and how many main-queue drains they
    /// turned into. The ratio is the whole point of this type.
    private(set) var posts = 0
    private(set) var drains = 0

    /// Records an event. Safe on any thread, and cheap enough for the parse
    /// path: one lock, one bitwise or, and at most one dispatch per drain
    /// window.
    func post(_ event: TerminalEvent) {
        // Deliver inline when the caller is already on the main thread, nothing
        // is queued ahead of this event, and the view says it is safe. This
        // keeps the long-standing synchronous behaviour for hosts that call
        // into the view directly, and costs nothing: the amplification this
        // type exists to fix comes from the parse thread, never from main.
        //
        // The "nothing queued ahead" test matters — delivering inline past
        // pending events would reorder them.
        if Thread.isMainThread, canDeliverInline?() == true {
            // Apply anything already queued together with this event, in
            // order, and clear the schedule flag. Any main-queue block still
            // outstanding then finds an empty queue and does nothing.
            //
            // Deferring instead would make delivery depend on the run loop
            // being serviced, which is not true in tests and not a contract
            // this type should impose on hosts.
            lock.lock()
            posts += 1
            let events = pending | event.mask
            pending = 0
            drainScheduled = false
            drains += 1
            lock.unlock()
            deliver(events)
            return
        }

        var needsSchedule = false
        lock.lock()
        posts += 1
        pending |= event.mask
        if !drainScheduled {
            drainScheduled = true
            needsSchedule = true
        }
        lock.unlock()

        guard needsSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.drain()
        }
    }

    /// Applies every pending event once. Main thread only.
    func drain() {
        precondition(Thread.isMainThread)
        lock.lock()
        let events = pending
        pending = 0
        drainScheduled = false
        drains += 1
        lock.unlock()

        deliver(events)
    }

    private func deliver(_ events: UInt32) {
        guard events != 0, let onDrain else { return }
        for event in TerminalEvent.allCases where events & event.mask != 0 {
            onDrain(event)
        }
    }

    func resetCounters() {
        lock.lock()
        posts = 0
        drains = 0
        lock.unlock()
    }

    /// Test hook: pending events without touching the schedule flag.
    var pendingEventsForTesting: [TerminalEvent] {
        lock.lock()
        let events = pending
        lock.unlock()
        return TerminalEvent.allCases.filter { events & $0.mask != 0 }
    }
}
