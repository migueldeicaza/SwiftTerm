/// Queues never discard an accepted item. Copy and consume are separate operations.
struct ByteQueue {
    private(set) var storage: [UInt8] = []
    private var head = 0
    var count: Int { storage.count - head }
    var bytes: ArraySlice<UInt8> { storage[head...] }
    mutating func append(_ data: ArraySlice<UInt8>, limit: Int = ABI.maximumQueue) -> Bool {
        guard data.count <= limit - count else { return false }
        if head > 0 && storage.count > limit - data.count {
            storage.removeFirst(head)
            head = 0
        }
        storage.append(contentsOf: data)
        return true
    }
    mutating func consume(_ count: Int) -> Bool {
        guard count >= 0 && count <= self.count else { return false }
        head += count
        if head == storage.count { storage.removeAll(keepingCapacity: true); head = 0 }
        return true
    }
}

struct HostEventQueue {
    private var events: [[UInt8]] = []
    private var head = 0
    private(set) var byteCount = 0
    private(set) var nextID: UInt32 = 1
    var first: [UInt8] { head < events.count ? events[head] : [] }
    mutating func append(type: UInt16, payload: [UInt8], flags: UInt16 = 0) -> Bool {
        guard nextID < UInt32.max, payload.count <= ABI.maximumQueue - 16 - byteCount else { return false }
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes.put16(type, at: 0)
        bytes.put16(flags, at: 2)
        bytes.put32(nextID, at: 4)
        bytes.put32(UInt32(payload.count), at: 8)
        bytes.append(contentsOf: payload)
        nextID += 1
        byteCount += bytes.count
        events.append(bytes)
        return true
    }
    mutating func consume() {
        guard head < events.count else { return }
        byteCount -= events[head].count
        events[head] = []
        head += 1
        if head == events.count { events.removeAll(keepingCapacity: true); head = 0 }
        else if head > 1024 { events.removeFirst(head); head = 0 }
    }
}
