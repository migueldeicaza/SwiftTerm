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
public final class TerminalLock {
    private let lockImpl = NSLock()

    // Owner tracking is unconditional (not DEBUG-only): production code paths
    // branch on `isLockedByCurrentThread` to pick a Locked variant while a
    // delegate callback runs under the lock, so its answer must be correct in
    // every build configuration. The cost is one guarded identifier store per
    // acquisition, which is noise at batch/frame granularity.
    private let ownerLock = NSLock()
    private var owner: ObjectIdentifier?

    private var currentOwner: ObjectIdentifier {
        ObjectIdentifier(Thread.current)
    }

    public init () {}

    public func lock ()
    {
        let current = currentOwner
        ownerLock.lock()
        precondition(owner != current, "TerminalLock is non-recursive")
        ownerLock.unlock()
        lockImpl.lock()
        ownerLock.lock()
        owner = current
        ownerLock.unlock()
    }

    public func unlock ()
    {
        let current = currentOwner
        ownerLock.lock()
        precondition(owner == current, "TerminalLock unlocked by a thread that does not own it")
        owner = nil
        ownerLock.unlock()
        lockImpl.unlock()
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
        ownerLock.lock()
        let locked = owner == currentOwner
        ownerLock.unlock()
        return locked
    }
}
