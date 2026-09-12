import Foundation
import Testing
@testable import SwiftTerm

struct WasmHostEventQueueTests {
    @Test func byteCapacityIsReleasedBeforeCallbacksAndOnClear() {
        let queue = WasmHostEventQueue(label: "test", now: { 1000 })
        let limit = 8 * 1024 * 1024
        var calls = 0
        queue.async(byteCount: limit) {
            calls += 1
            queue.async(byteCount: limit) { calls += 1 }
        }
        queue.async(byteCount: 1) { calls += 100 }
        #expect(queue.takeOverflow())
        #expect(queue.poll())
        #expect(calls == 1)
        #expect(!queue.takeOverflow())
        #expect(queue.poll())
        #expect(calls == 2)
        queue.async(byteCount: limit) { calls += 100 }
        queue.clear()
        queue.async(byteCount: limit) { calls += 1 }
        #expect(!queue.takeOverflow())
        #expect(queue.poll())
        #expect(calls == 3)
    }

    @Test func invalidByteCountsDoNotChangeCapacity() {
        let queue = WasmHostEventQueue(label: "test", now: { 1000 })
        var calls = 0
        queue.async(byteCount: -1) { calls += 100 }
        queue.async(byteCount: Int.max) { calls += 100 }
        #expect(queue.takeOverflow())
        queue.async(byteCount: 8 * 1024 * 1024) { calls += 1 }
        #expect(!queue.takeOverflow())
        #expect(queue.poll())
        #expect(calls == 1)
    }

    @Test func fullCallbackQueueCannotDropWatchdog() {
        let queue = WasmHostEventQueue(label: "test", now: { 1000 })
        var callbacks = 0
        for _ in 0..<4097 { queue.async { callbacks += 1 } }
        var watchdog = false
        queue.scheduleTimer(.synchronizedOutput, deadline: .init(uptimeNanoseconds: 100),
                            execute: TerminalEventWorkItem { watchdog = true })
        #expect(queue.takeOverflow())
        #expect(queue.poll())
        #expect(watchdog)
        #expect(callbacks == 4096)
    }

    @Test func repeatedAnimationSchedulingKeepsOnlyLatestDeadline() {
        var now: UInt64 = 0
        let queue = WasmHostEventQueue(label: "test", now: { now })
        var calls = 0
        for deadline in 1...5000 {
            queue.scheduleTimer(.kittyAnimation, deadline: .init(uptimeNanoseconds: UInt64(deadline)),
                                execute: TerminalEventWorkItem { calls += 1 })
        }
        #expect(!queue.takeOverflow())
        now = 4999
        #expect(!queue.poll())
        now = 5000
        #expect(queue.poll())
        #expect(calls == 1)
        queue.scheduleTimer(.kittyAnimation, deadline: .init(uptimeNanoseconds: now),
                            execute: TerminalEventWorkItem { calls += 1 })
        queue.cancelTimer(.kittyAnimation)
        #expect(!queue.poll())
        #expect(calls == 1)
    }

    @Test func timerCanRearmForNextPollAndClearCancelsIt() {
        let queue = WasmHostEventQueue(label: "test", now: { 1000 })
        var calls = 0
        queue.scheduleTimer(.kittyAnimation, deadline: .init(uptimeNanoseconds: 100), execute: TerminalEventWorkItem {
            calls += 1
            queue.scheduleTimer(.kittyAnimation, deadline: .init(uptimeNanoseconds: 100),
                                execute: TerminalEventWorkItem { calls += 1 })
        })
        #expect(queue.poll())
        #expect(calls == 1)
        queue.clear()
        #expect(!queue.poll())
        #expect(calls == 1)
    }

    @Test func clearDuringCallbackCancelsAlreadyReadyCallbacksAndOverflow() {
        let queue = WasmHostEventQueue(label: "test", now: { 1000 })
        var calls = 0
        queue.async { queue.clear() }
        for _ in 0..<4096 { queue.async { calls += 1 } }
        #expect(queue.poll())
        #expect(calls == 0)
        #expect(!queue.takeOverflow())
    }

    @Test func dueTimerCanCancelOrReplaceAnotherDueTimer() {
        let queue = WasmHostEventQueue(label: "test", now: { 1000 })
        var calls = 0
        queue.scheduleTimer(.synchronizedOutput, deadline: .init(uptimeNanoseconds: 100), execute: TerminalEventWorkItem {
            queue.cancelTimer(.kittyAnimation)
            queue.scheduleTimer(.kittyAnimation, deadline: .init(uptimeNanoseconds: 200),
                                execute: TerminalEventWorkItem { calls += 10 })
        })
        queue.scheduleTimer(.kittyAnimation, deadline: .init(uptimeNanoseconds: 200),
                            execute: TerminalEventWorkItem { calls += 1 })
        #expect(queue.poll())
        #expect(calls == 0)
        #expect(queue.poll())
        #expect(calls == 10)
    }

    @Test func clearDuringTimerCancelsOtherDueTimersAndCallbacks() {
        let queue = WasmHostEventQueue(label: "test", now: { 1000 })
        var calls = 0
        queue.scheduleTimer(.synchronizedOutput, deadline: .init(uptimeNanoseconds: 100),
                            execute: TerminalEventWorkItem { queue.clear() })
        queue.scheduleTimer(.kittyAnimation, deadline: .init(uptimeNanoseconds: 200),
                            execute: TerminalEventWorkItem { calls += 1 })
        queue.async { calls += 1 }
        #expect(queue.poll())
        #expect(calls == 0)
        #expect(!queue.poll())
    }
}
