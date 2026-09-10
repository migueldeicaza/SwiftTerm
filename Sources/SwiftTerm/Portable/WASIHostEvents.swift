#if os(WASI) && !SWIFTTERM_EMBEDDED
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

struct DispatchTime {
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

final class DispatchWorkItem {
    private var body: (() -> Void)?
    init(_ body: @escaping () -> Void) { self.body = body }
    var isCancelled: Bool { body == nil }
    func cancel() { body = nil }
    func perform() { let callback = body; body = nil; callback?() }
}

/// A per-owner queue. Only pollHostEvents executes callbacks, outside feed locks.
final class DispatchQueue {
    private var pending: [(UInt64, DispatchWorkItem, Int)] = []
    func clear() { pending.removeAll() }
    private(set) var overflowed = false
    init(label: String) {}
    func takeOverflow() -> Bool { let value = overflowed; overflowed = false; return value }
    private func enqueue(_ deadline: UInt64, _ item: DispatchWorkItem, byteCount: Int = 0) {
        pending.removeAll { $0.1.isCancelled }
        guard pending.count < 4096, byteCount <= 8 * 1024 * 1024 - pending.reduce(0, { $0 + $1.2 }) else { overflowed = true; return }
        pending.append((deadline, item, byteCount))
    }
    func async(execute: @escaping () -> Void) { enqueue(0, DispatchWorkItem(execute)) }
    func async(byteCount: Int, execute: @escaping () -> Void) { enqueue(0, DispatchWorkItem(execute), byteCount: byteCount) }
    func asyncAfter(deadline: DispatchTime, execute: DispatchWorkItem) {
        enqueue(deadline.uptimeNanoseconds, execute)
    }
    @discardableResult func poll() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let ready = pending.filter { $0.0 <= now }.sorted { $0.0 < $1.0 }
        pending.removeAll { $0.0 <= now }
        for (_, item, _) in ready { item.perform() }
        return !ready.isEmpty
    }
}
#endif
