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
