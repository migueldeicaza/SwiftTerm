//
//  TerminalLock.swift
//  SwiftTerm
//
//  Serializes access to a Terminal and its view-layer services.
//

import Foundation

/// Serializes access to a `Terminal` and its view-layer services.
///
/// This lock is intentionally non-recursive. Callers that enter terminal state
/// must take this lock before reading or mutating `Terminal`, `SelectionService`,
/// or `SearchService` state, and internal helpers that assume the lock is held
/// use the `Locked` suffix and call `preconditionLocked()`.
///
/// Reentry rules:
/// 1. Never call `DispatchQueue.main.sync` from the parse/feed path.
/// 2. Delegate callbacks may fire with the lock held; handlers must not
///    synchronously call APIs that take this lock.
/// 3. Lock order is `terminalLock` before view-local state locks.
/// 4. `send()` replies must not synchronously re-enter `Terminal`.
///
/// Acquisition is FIFO-fair. Fairness is a correctness requirement here, not a
/// nicety: the parse thread runs `lock -> parse batch -> unlock -> lock` with no
/// gap while the pty has data queued. Over a plain mutex it barges back in
/// before the woken main thread is scheduled, and the main thread stalls for
/// seconds even though every individual batch costs a couple of milliseconds.
/// A ticket bounds the main thread's wait at one batch.
public final class TerminalLock {
    // Guards the ticket counters and `owner`. Held only for the handful of
    // instructions around a handoff, never for the caller's critical section.
    private let condition = NSCondition()
    private var nextTicket: UInt64 = 0
    private var nowServing: UInt64 = 0
    private var waiters = 0

    // Owner tracking is unconditional (not DEBUG-only): production code paths
    // branch on `isLockedByCurrentThread` to pick a Locked variant while a
    // delegate callback runs under the lock, so its answer must be correct in
    // every build configuration. The cost is one guarded identifier store per
    // acquisition, which is noise at batch/frame granularity.
    private var owner: ObjectIdentifier?

    // The hold interval of the current owner, ended by `unlock`. Only one
    // thread can hold the lock, so a single field is enough; it is written and
    // read under `condition`. Inert unless SWIFTTERM_PROFILE=1.
    private var holdInterval: ProfilingInterval?

    private var currentOwner: ObjectIdentifier {
        ObjectIdentifier(Thread.current)
    }

    public init () {}

    public func lock ()
    {
        let current = currentOwner
        // Derived before taking `condition` so the tag lookup is never inside
        // the guarded region. Returns .other and does no work when profiling
        // is off.
        let profilingOwner = Profiling.enabled ? ProfilingOwner.current : .other

        condition.lock()
        precondition(owner != current, "TerminalLock is non-recursive")
        let ticket = nextTicket
        nextTicket &+= 1
        if ticket != nowServing {
            let wait = Profiling.begin(.lockWait, owner: profilingOwner)
            waiters += 1
            // Loop over `wait`: the release broadcasts, so every waiter wakes
            // and all but the ticket holder go back to sleep. This also covers
            // spurious wakeups.
            repeat {
                condition.wait()
            } while ticket != nowServing
            waiters -= 1
            wait.end()
        }
        owner = current
        if Profiling.enabled {
            holdInterval = Profiling.begin(.lockHold, owner: profilingOwner)
        }
        condition.unlock()
    }

    public func unlock ()
    {
        let current = currentOwner
        condition.lock()
        precondition(owner == current, "TerminalLock unlocked by a thread that does not own it")
        owner = nil
        let hold = holdInterval
        holdInterval = nil
        nowServing &+= 1
        if waiters > 0 {
            condition.broadcast()
        }
        condition.unlock()
        // Ended outside the guarded region: emitting a signpost is a call into
        // os_log and must not sit inside the handoff window.
        hold?.end()
    }

    public func withLock<T> (_ body: () throws -> T) rethrows -> T
    {
        lock()
        defer { unlock() }
        return try body()
    }

    public func preconditionLocked (file: StaticString = #fileID, line: UInt = #line)
    {
        precondition(isLockedByCurrentThread, "TerminalLock must be held", file: file, line: line)
    }

    /// True when the calling thread currently holds the lock. Used by view
    /// code that can be entered both from a delegate callback (lock already
    /// held) and from a plain main-thread path (lock not held), to choose
    /// between a `Locked` variant and a locking one. Transitional: the WO2
    /// callback marshalling removes most of these dual-entry paths.
    var isLockedByCurrentThread: Bool {
        condition.lock()
        let locked = owner == currentOwner
        condition.unlock()
        return locked
    }
}
