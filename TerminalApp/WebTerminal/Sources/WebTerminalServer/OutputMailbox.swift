import Foundation

enum TerminalOutput: Sendable, Equatable {
    case bytes([UInt8])
    case exit(Int32?)
}

/// One PTY thread produces data. One async WebSocket task consumes it.
/// Only the PTY thread waits on the condition; a Swift executor never blocks.
final class OutputMailbox: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private var chunks: [[UInt8]] = []
    private var byteCount = 0
    private var waiter: CheckedContinuation<TerminalOutput?, Never>?
    private var finalEvent: TerminalOutput?
    private var finished = false
    private var closed = false

    init(capacity: Int = 256 * 1024) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        // Split oversized callbacks so the capacity is a strict byte limit.
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = min(start + capacity, bytes.endIndex)
            condition.lock()
            while !closed && !finished && byteCount + end - start > capacity && waiter == nil {
                condition.wait()
            }
            guard !closed && !finished else { condition.unlock(); return }
            let chunk = Array(bytes[start..<end])
            let pending = waiter
            waiter = nil
            if pending == nil { chunks.append(chunk); byteCount += chunk.count }
            condition.unlock()
            pending?.resume(returning: .bytes(chunk))
            start = end
        }
    }

    func finish(exitCode: Int32?) {
        condition.lock()
        guard !closed && !finished else { condition.unlock(); return }
        finished = true
        finalEvent = .exit(exitCode)
        let pending = waiter
        waiter = nil
        if pending != nil { finalEvent = nil }
        condition.broadcast()
        condition.unlock()
        pending?.resume(returning: .exit(exitCode))
    }

    func close() {
        condition.lock()
        closed = true
        chunks.removeAll()
        byteCount = 0
        finalEvent = nil
        let pending = waiter
        waiter = nil
        condition.broadcast()
        condition.unlock()
        pending?.resume(returning: nil)
    }

    func next() async -> TerminalOutput? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { register($0) }
        } onCancel: {
            self.close()
        }
    }

    private func register(_ continuation: CheckedContinuation<TerminalOutput?, Never>) {
        condition.lock()
        if closed {
            condition.unlock()
            continuation.resume(returning: nil)
        } else if !chunks.isEmpty {
            let bytes = chunks.removeFirst()
            byteCount -= bytes.count
            condition.broadcast()
            condition.unlock()
            continuation.resume(returning: .bytes(bytes))
        } else if finished {
            let event = finalEvent
            finalEvent = nil
            condition.unlock()
            continuation.resume(returning: event)
        } else {
            precondition(waiter == nil, "Only one output consumer is permitted")
            waiter = continuation
            condition.unlock()
        }
    }
}
