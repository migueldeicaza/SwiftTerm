import Testing
@testable import SwiftTerm

struct LockedVoidCallbackTests {
    @Test func repeatedCallsDoNotGrowTheCallbackStack() {
        let addresses = Locked<[UInt]>([])
        let callback = LockedVoidCallback {
            var marker = 0
            let address = withUnsafePointer(to: &marker) {
                UInt(bitPattern: $0)
            }
            addresses.withLock { $0.append(address) }
        }

        for _ in 0..<1_000 {
            callback.call()
        }

        let samples = addresses.withLock { $0 }
        let first = samples.first ?? 0
        let last = samples.last ?? 0
        let stackGrowth = first > last ? first - last : last - first

        #expect(samples.count == 1_000)
        #expect(
            stackGrowth < 4_096,
            "callback stack grew by \(stackGrowth) bytes")
    }

    @Test func callbackCanReplaceItself() {
        let callback = LockedVoidCallback()
        let calls = Locked(0)
        callback.replace {
            calls.withLock { $0 += 1 }
            callback.replace(with: nil)
        }

        callback.call()
        callback.call()

        #expect(calls.withLock { $0 } == 1)
    }

    @Test func currentCallbackDoesNotChangeStoredRepresentation() {
        let callback = LockedVoidCallback()
        let addresses = Locked<[UInt]>([])
        callback.replace {
            var marker = 0
            let address = withUnsafePointer(to: &marker) {
                UInt(bitPattern: $0)
            }
            addresses.withLock { $0.append(address) }
        }

        for _ in 0..<1_000 {
            callback.current?()
        }

        let samples = addresses.withLock { $0 }
        let first = samples.first ?? 0
        let last = samples.last ?? 0
        let stackGrowth = first > last ? first - last : last - first

        #expect(samples.count == 1_000)
        #expect(
            stackGrowth < 4_096,
            "callback stack grew by \(stackGrowth) bytes")
    }
}
