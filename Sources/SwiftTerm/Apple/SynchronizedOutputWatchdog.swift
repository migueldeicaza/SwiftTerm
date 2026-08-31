//
//  SynchronizedOutputWatchdog.swift
//  SwiftTerm
//

#if os(macOS) || os(iOS) || os(visionOS) || os(macCatalyst)
import Foundation

/// One reusable display-freeze watchdog for an Apple terminal view.
final class SynchronizedOutputWatchdog: @unchecked Sendable {
    struct Counters: Sendable {
        var armed = 0
        var rearmed = 0
        var cancelled = 0
        var fired = 0
    }

    final class Target: @unchecked Sendable {
        private struct State {
            var terminal: Terminal?
            var armedGeneration: UInt64?
            var armedDeadline: DispatchTime?
            var invalidated = false
            var callsInFlight = 0
            var counters = Counters()
        }

        private let condition = NSCondition()
        private var state = State()

        var terminal: Terminal? {
            condition.lock()
            defer { condition.unlock() }
            return state.terminal
        }

        var counters: Counters {
            condition.lock()
            defer { condition.unlock() }
            return state.counters
        }

        func attach(terminal: Terminal, disarm: () -> Void) {
            condition.lock()
            defer { condition.unlock() }
            guard !state.invalidated, state.terminal !== terminal else { return }
            if state.armedGeneration != nil {
                state.counters.cancelled += 1
            }
            state.terminal = terminal
            state.armedGeneration = nil
            state.armedDeadline = nil
            disarm()
        }

        func update(
            active: Bool,
            generation: UInt64,
            timeout: TimeInterval,
            arm: (DispatchTime) -> Void,
            disarm: () -> Void
        ) {
            condition.lock()
            defer { condition.unlock() }
            guard !state.invalidated, state.terminal != nil else { return }

            if active {
                if let armedGeneration = state.armedGeneration {
                    // Updates are applied after terminalLock is released, so
                    // two feed callers can apply out of order. Only a newer
                    // generation may rearm; a stale or duplicate arm must not
                    // reset the deadline to an old window's generation.
                    guard Int64(bitPattern: generation &- armedGeneration) > 0 else { return }
                    state.counters.rearmed += 1
                } else {
                    state.counters.armed += 1
                }
                let deadline = DispatchTime.now() + timeout
                state.armedGeneration = generation
                state.armedDeadline = deadline
                arm(deadline)
            } else {
                guard generation == state.armedGeneration else { return }
                state.armedGeneration = nil
                state.armedDeadline = nil
                state.counters.cancelled += 1
                disarm()
            }
        }

        func fire() {
            let terminal: Terminal
            let generation: UInt64

            condition.lock()
            guard !state.invalidated,
                  let currentTerminal = state.terminal,
                  let currentGeneration = state.armedGeneration,
                  let currentDeadline = state.armedDeadline,
                  DispatchTime.now() >= currentDeadline
            else {
                condition.unlock()
                return
            }
            terminal = currentTerminal
            generation = currentGeneration
            state.armedGeneration = nil
            state.armedDeadline = nil
            state.callsInFlight += 1
            state.counters.fired += 1
            condition.unlock()

            terminal.synchronizedOutputWatchdogFired(generation: generation)

            condition.lock()
            state.callsInFlight -= 1
            condition.broadcast()
            condition.unlock()
        }

        func invalidate(cancel: () -> Void) {
            condition.lock()
            guard !state.invalidated else {
                condition.unlock()
                return
            }
            state.invalidated = true
            state.terminal = nil
            state.armedGeneration = nil
            state.armedDeadline = nil
            cancel()
            while state.callsInFlight != 0 {
                condition.wait()
            }
            condition.unlock()
        }
    }

    // Owner graph: owner -> watchdog -> handler -> target -> Terminal.
    // Invalidation clears the target's strong Terminal reference. The handler
    // captures only the target, so it cannot retain the owner or view.
    let target = Target()
    private let source: DispatchSourceTimer

    init() {
        let target = target
        let source = DispatchSource.makeTimerSource(queue: IOTimerQueue.shared)
        self.source = source
        source.setEventHandler {
            target.fire()
        }
        source.schedule(deadline: .distantFuture)
        source.resume()
    }

    deinit {
        invalidate()
    }

    var counters: Counters {
        target.counters
    }

    func attach(terminal: Terminal) {
        target.attach(terminal: terminal) {
            source.schedule(deadline: .distantFuture)
        }
    }

    func update(active: Bool, generation: UInt64, timeout: TimeInterval) {
        target.update(
            active: active,
            generation: generation,
            timeout: timeout,
            arm: { deadline in
                source.schedule(deadline: deadline)
            },
            disarm: {
                source.schedule(deadline: .distantFuture)
            })
    }

    func invalidate() {
        target.invalidate {
            source.schedule(deadline: .distantFuture)
            source.cancel()
        }
    }

    func fireForTesting() {
        target.fire()
    }
}
#endif
