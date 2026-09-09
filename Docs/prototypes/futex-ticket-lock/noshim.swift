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

// Current implementation: ticket lock over NSCondition, broadcast on release.
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

// Option A, pure Swift: ticket lock with a ring of per-waiter semaphores.
// Guard is an NSLock held only for the counter update. Exactly one waiter is
// woken per release.
final class SemaphoreTicketLock {
    private let guardLock = NSLock()
    private static let slotCount = 64
    private let slots: [DispatchSemaphore]
    private var nextTicket: UInt64 = 0
    private var nowServing: UInt64 = 0
    private var parked = [Bool](repeating: false, count: SemaphoreTicketLock.slotCount)
    private var owner: ObjectIdentifier?

    init() { slots = (0..<Self.slotCount).map { _ in DispatchSemaphore(value: 0) } }

    func lock() {
        let current = ObjectIdentifier(Thread.current)
        guardLock.lock()
        let ticket = nextTicket; nextTicket &+= 1
        if ticket != nowServing {
            parked[Int(ticket) % Self.slotCount] = true
            guardLock.unlock()
            slots[Int(ticket) % Self.slotCount].wait()
            guardLock.lock()
        }
        owner = current
        guardLock.unlock()
    }

    func unlock() {
        guardLock.lock()
        owner = nil
        nowServing &+= 1
        let next = nowServing
        let slot = Int(next) % Self.slotCount
        let wake = parked[slot]
        if wake { parked[slot] = false }
        guardLock.unlock()
        if wake { slots[Int(next) % Self.slotCount].signal() }
    }
}

func benchUncontended<L>(_ name: String, _ make: () -> L, _ lk: (L) -> () -> Void, _ ul: (L) -> () -> Void) {
    let l = make()
    let iters = 2_000_000
    let lockFn = lk(l), unlockFn = ul(l)
    let t0 = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iters { lockFn(); unlockFn() }
    let t1 = DispatchTime.now().uptimeNanoseconds
    print(String(format: "%@ uncontended: %.1f ns/acquire", name, Double(t1-t0)/Double(iters)))
}

func benchContended<L: AnyObject>(_ name: String, _ l: L, _ lk: @escaping () -> Void, _ ul: @escaping () -> Void) {
    let control = BenchmarkWorkerControl()
    let hog = Thread {
        var checksum = 0
        defer { control.finish(checksum: checksum) }
        while !control.shouldStop() {
            lk()
            checksum = benchmarkWork(seed: checksum)
            ul()
        }
    }
    hog.qualityOfService = .userInitiated
    hog.start()
    Thread.sleep(forTimeInterval: 0.05)
    var worst: UInt64 = 0, total: UInt64 = 0
    let samples = 2000
    for _ in 0..<samples {
        let t0 = DispatchTime.now().uptimeNanoseconds
        lk()
        let t1 = DispatchTime.now().uptimeNanoseconds
        ul()
        worst = max(worst, t1-t0); total += t1-t0
    }
    let checksum = control.stopAndWait()
    print(String(format: "%@ contended: mean %.1f us, worst %.1f us, checksum %ld", name, Double(total)/Double(samples)/1000.0, Double(worst)/1000.0, checksum))
}

benchUncontended("NSCondition ticket", { ConditionTicketLock() }, { l in l.lock }, { l in l.unlock })
benchUncontended("Semaphore ticket ", { SemaphoreTicketLock() }, { l in l.lock }, { l in l.unlock })

let c = ConditionTicketLock()
benchContended("NSCondition ticket", c, { c.lock() }, { c.unlock() })
let s = SemaphoreTicketLock()
benchContended("Semaphore ticket ", s, { s.lock() }, { s.unlock() })

// Correctness of the semaphore variant.
let lk = SemaphoreTicketLock()
var counter = 0
let g = DispatchGroup()
for _ in 0..<8 {
    DispatchQueue.global().async(group: g) { for _ in 0..<50_000 { lk.lock(); counter += 1; lk.unlock() } }
}
g.wait()
print("semaphore ticket counter = \(counter) (expect 400000)")
