#if !SWIFTTERM_EMBEDDED
import Foundation
#if os(WASI)
import WASILibc

/// The browser reactor runs on one thread. Preserve non-recursive lock checks.
public final class TerminalLock: @unchecked Sendable {
    private var held = false
    public init() {}
    public func lock() { precondition(!held, "TerminalLock is non-recursive"); held = true }
    public func unlock() { precondition(held); held = false }
    var isLockedByCurrentThread: Bool { held }
    public func preconditionLocked(file: StaticString = #fileID, line: UInt = #line) {
        precondition(held, "TerminalLock must be held", file: file, line: line)
    }
    @discardableResult public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}

struct TerminalEventTime {
    let uptimeNanoseconds: UInt64
    static func now() -> Self {
        var time: UInt64 = 0
        _ = __wasi_clock_time_get(1, 1_000_000, &time)
        return .init(uptimeNanoseconds: time)
    }
    static func + (left: Self, seconds: Double) -> Self {
        .init(uptimeNanoseconds: left.uptimeNanoseconds + UInt64(max(0, seconds) * 1_000_000_000))
    }
}

final class TerminalEventWorkItem {
    private var body: (() -> Void)?
    init(block body: @escaping () -> Void) { self.body = body }
    var isCancelled: Bool { body == nil }
    func cancel() { body = nil }
    func perform() { let callback = body; body = nil; callback?() }
}

typealias TerminalCallbackQueue = WasmHostEventQueue
#else
import Dispatch
typealias TerminalEventTime = DispatchTime
typealias TerminalEventWorkItem = DispatchWorkItem
typealias TerminalCallbackQueue = DispatchQueue
#endif

enum TerminalEventTimer: Hashable { case synchronizedOutput, kittyAnimation }

extension Terminal {
    /// Use the host timer slots on WASI and the shared I/O queue elsewhere.
    func scheduleEventTimer(_ timer: TerminalEventTimer, deadline: TerminalEventTime,
                            execute: TerminalEventWorkItem) {
        #if os(WASI)
        hostEventQueue.scheduleTimer(timer, deadline: deadline, execute: execute)
        #else
        IOTimerQueue.shared.asyncAfter(deadline: deadline, execute: execute)
        #endif
    }
}

/// A per-owner queue. Only pollHostEvents executes callbacks, outside feed locks.
/// Timer slots are separate from bounded callbacks. A full callback queue must
/// never discard the synchronized-output watchdog or an animation deadline.
final class WasmHostEventQueue {
    typealias Timer = TerminalEventTimer
    private var pending: [TerminalEventWorkItem] = []
    private var pendingBytes = 0
    private var timers: [Timer: (UInt64, TerminalEventWorkItem)] = [:]
    private let now: () -> UInt64
    private var epoch: UInt64 = 0
    func clear() {
        epoch &+= 1
        overflowed = false
        for item in pending { item.cancel() }
        for (_, item) in timers.values { item.cancel() }
        pending.removeAll()
        pendingBytes = 0
        timers.removeAll()
    }
    private(set) var overflowed = false
    init(label: String, now: @escaping () -> UInt64 = { TerminalEventTime.now().uptimeNanoseconds }) {
        self.now = now
    }
    func takeOverflow() -> Bool { let value = overflowed; overflowed = false; return value }
    private func enqueue(_ item: TerminalEventWorkItem, byteCount: Int = 0) {
        guard byteCount >= 0, pending.count < 4096,
              byteCount <= 8 * 1024 * 1024 - pendingBytes else {
            overflowed = true
            return
        }
        pending.append(item)
        pendingBytes += byteCount
    }
    func async(execute: @escaping () -> Void) { enqueue(TerminalEventWorkItem(block: execute)) }
    func async(byteCount: Int, execute: @escaping () -> Void) { enqueue(TerminalEventWorkItem(block: execute), byteCount: byteCount) }
    func scheduleTimer(_ timer: Timer, deadline: TerminalEventTime, execute: TerminalEventWorkItem) {
        cancelTimer(timer)
        timers[timer] = (deadline.uptimeNanoseconds, execute)
    }
    func cancelTimer(_ timer: Timer) {
        timers.removeValue(forKey: timer)?.1.cancel()
    }
    @discardableResult func poll() -> Bool {
        let now = now()
        let pollEpoch = epoch
        let ready = pending
        pending = []
        pendingBytes = 0
        let dueTimers = timers.filter { $0.value.0 <= now }.sorted { $0.value.0 < $1.value.0 }
        var performed = false
        // Run safety timers first. A callback can queue new work for the next poll.
        for (timer, (_, item)) in dueTimers {
            guard let current = timers[timer], current.1 === item else { continue }
            timers.removeValue(forKey: timer)
            guard !item.isCancelled else { continue }
            performed = true
            item.perform()
        }
        for item in ready {
            guard epoch == pollEpoch, !item.isCancelled else { continue }
            performed = true
            item.perform()
        }
        return performed
    }
}
#endif
