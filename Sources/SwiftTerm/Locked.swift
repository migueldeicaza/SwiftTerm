//
//  Locked.swift
//  SwiftTerm
//
//  A small synchronized state container for state that does not require the
//  FIFO fairness guarantee of TerminalLock.
//

import Foundation

/// Owns one value behind a non-recursive lock.
///
/// The unchecked conformance is limited to this synchronization primitive.
/// Callers must not expose mutable value storage from `withLock`. They can copy
/// a stable reference when that reference has separate synchronization and
/// does not escape the owning API.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init (_ value: Value) {
        self.value = value
    }

    @discardableResult
    func withLock<Result> (_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// Stores a replaceable callback without passing the function value itself
/// through a generic container.
///
/// A function value can get a new reabstraction thunk each time it moves out
/// of generic mutable storage. If that value is written back, those thunks
/// form an unbounded call chain. This type stores a stable object reference in
/// `Locked` and keeps the function at a concrete field type.
final class LockedVoidCallback: Sendable {
    private final class Callback: Sendable {
        let body: @Sendable () -> Void

        init(_ body: @escaping @Sendable () -> Void) {
            self.body = body
        }

        func call() {
            body()
        }
    }

    private let callback: Locked<Callback?>

    init(_ body: (@Sendable () -> Void)? = nil) {
        callback = Locked(body.map(Callback.init))
    }

    func replace(with body: (@Sendable () -> Void)?) {
        let next = body.map(Callback.init)
        callback.withLock { $0 = next }
    }

    /// Returns the callback for APIs that must expose a stored function.
    var current: (@Sendable () -> Void)? {
        callback.withLock { $0 }?.body
    }

    func call() {
        callback.withLock { $0 }?.call()
    }
}
