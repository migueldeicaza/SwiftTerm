import Foundation

final class BenchmarkWorkerControl: @unchecked Sendable {
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var stopRequested = false
    private var checksum = 0

    func shouldStop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    func finish(checksum: Int) {
        lock.lock()
        self.checksum = checksum
        lock.unlock()
        finished.signal()
    }

    func stopAndWait() -> Int {
        lock.lock()
        stopRequested = true
        lock.unlock()
        finished.wait()

        lock.lock()
        defer { lock.unlock() }
        return checksum
    }
}

@inline(never)
func benchmarkWork(seed: Int) -> Int {
    var result = seed
    for value in 0..<2_000 {
        result &+= value
    }
    return result
}

final class FutexTicketLock {
    private let storage = UnsafeMutablePointer<UInt32>.allocate(capacity: 3)
    private var next: UnsafeMutablePointer<UInt32> { storage }
    private var serving: UnsafeMutablePointer<UInt32> { storage + 1 }
    private var waiters: UnsafeMutablePointer<UInt32> { storage + 2 }
    private var owner: ObjectIdentifier?

    init() { storage[0] = 0; storage[1] = 0; storage[2] = 0 }
    deinit { storage.deallocate() }

    func lock() {
        let ticket = swiftterm_atomic_fetch_add(next, 1)
        while true {
            let now = swiftterm_atomic_load_acquire(serving)
            if now == ticket { break }
            _ = swiftterm_atomic_fetch_add(waiters, 1)
            let r = swiftterm_sync_wait(serving, now)
            _ = swiftterm_atomic_fetch_add(waiters, UInt32(bitPattern: -1))
            if r < 0 && errno != EINTR && errno != EFAULT && errno != EAGAIN && errno != ENOMEM {
                // Unexpected: spin rather than deadlock (fallback latch in real code)
            }
        }
        owner = ObjectIdentifier(Thread.current)
    }

    func unlock() {
        owner = nil
        let now = swiftterm_atomic_load_acquire(serving)
        swiftterm_atomic_store_release(serving, now &+ 1)
        if swiftterm_atomic_load_acquire(waiters) > 0 {
            _ = swiftterm_sync_wake_all(serving)
        }
    }
}

print("os_sync available: \(swiftterm_sync_available())")

// 1. Correctness: N threads incrementing a shared counter under the lock.
let lk = FutexTicketLock()
var counter = 0
let group = DispatchGroup()
for _ in 0..<8 {
    DispatchQueue.global().async(group: group) {
        for _ in 0..<50_000 { lk.lock(); counter += 1; lk.unlock() }
    }
}
group.wait()
print("counter = \(counter) (expect 400000)")

// 2. Starvation: one thread in a tight lock loop, another measuring worst-case wait.
let lk2 = FutexTicketLock()
let hogControl = BenchmarkWorkerControl()
let hog = Thread {
    var checksum = 0
    defer { hogControl.finish(checksum: checksum) }
    while !hogControl.shouldStop() {
        lk2.lock()
        checksum = benchmarkWork(seed: checksum)
        lk2.unlock()
    }
}
hog.qualityOfService = .userInitiated
hog.start()
Thread.sleep(forTimeInterval: 0.05)
var worstNs: UInt64 = 0
var totalNs: UInt64 = 0
let samples = 2000
for _ in 0..<samples {
    let t0 = DispatchTime.now().uptimeNanoseconds
    lk2.lock()
    let t1 = DispatchTime.now().uptimeNanoseconds
    lk2.unlock()
    worstNs = max(worstNs, t1 - t0)
    totalNs += t1 - t0
}
let hogChecksum = hogControl.stopAndWait()
print(String(format: "contended wait: mean %.1f us, worst %.1f us, checksum %ld", Double(totalNs)/Double(samples)/1000.0, Double(worstNs)/1000.0, hogChecksum))

// 3. Uncontended cost.
let lk3 = FutexTicketLock()
let iters = 2_000_000
let s0 = DispatchTime.now().uptimeNanoseconds
for _ in 0..<iters { lk3.lock(); lk3.unlock() }
let s1 = DispatchTime.now().uptimeNanoseconds
print(String(format: "futex uncontended: %.1f ns/acquire", Double(s1-s0)/Double(iters)))

// 4. Compare with the current NSCondition ticket lock.
final class ConditionTicketLock {
    private let condition = NSCondition()
    private var nextTicket: UInt64 = 0
    private var nowServing: UInt64 = 0
    private var waiters = 0
    private var owner: ObjectIdentifier?
    func lock() {
        let current = ObjectIdentifier(Thread.current)
        condition.lock()
        let ticket = nextTicket; nextTicket &+= 1
        if ticket != nowServing {
            waiters += 1
            repeat { condition.wait() } while ticket != nowServing
            waiters -= 1
        }
        owner = current
        condition.unlock()
    }
    func unlock() {
        condition.lock()
        owner = nil
        nowServing &+= 1
        if waiters > 0 { condition.broadcast() }
        condition.unlock()
    }
}
let nc = ConditionTicketLock()
let n0 = DispatchTime.now().uptimeNanoseconds
for _ in 0..<iters { nc.lock(); nc.unlock() }
let n1 = DispatchTime.now().uptimeNanoseconds
print(String(format: "NSCondition uncontended: %.1f ns/acquire", Double(n1-n0)/Double(iters)))


// 5. Contended comparison for the NSCondition lock (same shape as case 2).
let nc2 = ConditionTicketLock()
let hog2Control = BenchmarkWorkerControl()
let hog2 = Thread {
    var checksum = 0
    defer { hog2Control.finish(checksum: checksum) }
    while !hog2Control.shouldStop() {
        nc2.lock()
        checksum = benchmarkWork(seed: checksum)
        nc2.unlock()
    }
}
hog2.qualityOfService = .userInitiated
hog2.start()
Thread.sleep(forTimeInterval: 0.05)
var worst2: UInt64 = 0
var total2: UInt64 = 0
for _ in 0..<samples {
    let t0 = DispatchTime.now().uptimeNanoseconds
    nc2.lock()
    let t1 = DispatchTime.now().uptimeNanoseconds
    nc2.unlock()
    worst2 = max(worst2, t1 - t0)
    total2 += t1 - t0
}
let hog2Checksum = hog2Control.stopAndWait()
print(String(format: "NSCondition contended wait: mean %.1f us, worst %.1f us, checksum %ld", Double(total2)/Double(samples)/1000.0, Double(worst2)/1000.0, hog2Checksum))

// 6. Put it in context: cost per 64 KiB batch at realistic rates.
print(String(format: "at 1000 acquisitions/sec, 9 ns saved per acquire = %.1f us/sec", 1000.0 * 9.0 / 1000.0))
