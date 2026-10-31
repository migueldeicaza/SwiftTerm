//
//  CircularList.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/25/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

#if !SWIFTTERM_EMBEDDED
import Foundation
#endif

enum ArgumentError : Error {
    case invalidArgument(String)
}

final class CircularList<T> {
    private var array: [T?]
    private var startIndex: Int
    var count: Int {
        get {
            return _count
        }
        set {
            precondition(newValue <= maxLength)

            if newValue > array.count {
                let start = array.count
                for _ in start..<newValue {
                    array.append (nil)
                }
            }
            _count = newValue
        }
    }

    private var _count: Int
    var maxLength: Int {
        didSet {
            if maxLength != oldValue {
                let empty : T? = nil
                var newArray = Array(repeating: empty, count:Int(maxLength))
                let top = min (maxLength, array.count)
                for i in 0..<top {
                    newArray [i] = array [getCyclicIndex(i)]
                }
                startIndex = 0
                array = newArray
                return
            }
        }
    }

    ///
    /// This method is called to fill a slot that might be empty on demand, gets a -1 for a row that
    /// does not exist, or the index requested otherwise
    //
    var makeEmpty: ((_ idx: Int) -> T)? = nil

    public init (maxLength: Int)
    {
        array = Array.init(repeating: nil, count: Int(maxLength))
        self.maxLength = maxLength
        self._count = 0
        self.startIndex = 0
    }

    private func getCyclicIndex(_ index: Int) -> Int {
        return Int(startIndex + index) % (array.count)
    }

    func debugGetCyclicIndex(_ index: Int) -> Int {
        getCyclicIndex(index)
    }

    subscript (index: Int) -> T {
        get {
            let idx = getCyclicIndex(index)
            if let p = array [idx] {
                return p
            } else {
                guard let makeEmpty = makeEmpty else {
                    preconditionFailure("makeEmpty closure must be configured for CircularList when slot is nil")
                }
                let new = makeEmpty (idx)
                array [idx] = new
                return new
            }
        }
        set (newValue){
            array [getCyclicIndex(index)] = newValue
      }
    }

    func push (_ value: T)
    {
        array [getCyclicIndex(count)] = value
        if count == array.count {
            startIndex = startIndex + 1
            if startIndex == array.count {
                startIndex = 0
            }
        } else {
            count = count + 1
        }
    }

    func recycle ()
    {
        precondition(count == maxLength, "can only recycle when the buffer is full")
        guard let makeEmpty = makeEmpty else {
            preconditionFailure("makeEmpty closure must be configured for CircularList")
        }
        let index = getCyclicIndex(count)
        startIndex += 1
        startIndex = startIndex % maxLength
        array [index] = makeEmpty (-1)
    }

    @discardableResult
    func pop () -> T {
        let v = array [getCyclicIndex(count-1)]!
        count = count - 1
        return v
    }

    func splice (start: Int, deleteCount: Int, items: [T], change: (Int) -> Void)
    {
        if deleteCount > 0 {
            var i = start
            let limit = count-deleteCount
            while i < limit {
                array [getCyclicIndex(i)] = array [getCyclicIndex(i+deleteCount)]
                change(i)
                i += 1
            }
            count = count - deleteCount
        }
        // add items
        var i = count-1
        let ic = items.count
        while i >= start {
#if DEBUG
            // print("Moving line \(i) to \(i + ic): \(array[getCyclicIndex(i)].debugDescription)")
#endif
            array [getCyclicIndex(i + ic)] = array [getCyclicIndex(i)]
            change(i + ic)
            i -= 1
        }
        for i in 0..<ic {
            change(start + i)
            array [getCyclicIndex(start + i)] = items [i]
        }

        // Adjust length as needed
        if Int(count) + ic > array.count {
            let countToTrim = count + items.count - array.count
            startIndex = startIndex + countToTrim
            count = array.count
        } else {
            count = count + items.count
        }
     }

    func trimStart (count: Int)
    {
        let c = count > self.count ? self.count : count
        startIndex = startIndex + c
        self.count -= count
    }

    func shiftElements (start: Int, count: Int, offset: Int) -> Bool
    {
        func dumpState (_ msg: String) -> Bool {
            print ("Assertion at start=\(start) count=\(count) offset=\(offset): \(msg)")
            return false
        }

        if count < 0 {
            return dumpState ("count < 0")
        }
        if start < 0 {
            return dumpState ("start < 0")
        }
        if start >= self.count {
            return dumpState ("start >= self.count")
        }
        if start+offset <= 0 {
            return dumpState ("start+offset <= 0")
        }
//        precondition (count > 0)
//        precondition (start >= 0)
//        precondition (start < self.count)
//        precondition (start+offset > 0)
        if offset > 0 {
            for i in (0..<count).reversed() {
                self [start + i + offset] = self [start + i]
            }
            let expandListBy = start + count + offset - self.count
            if expandListBy > 0 {
                self._count += expandListBy
                while self._count > maxLength {
                    self._count -= 1
                    startIndex += 1
                    // trimmed callback invoke
                }
            }
        } else {
            for i in 0..<count {
                self [start + i + offset] = self [start + i]
            }
        }
        return true
    }

    var isFull: Bool {
        get {
            return count == maxLength
        }
    }
}

internal final class CircularBufferLineList {
    // The ring slots. The list owns this memory. `init` allocates it and
    // `deinit` releases it. A Swift array in a class property does a
    // uniqueness check (copy on write) on each mutable access. This pointer
    // does not. `capacity` is the number of slots, and it is always equal to
    // `maxLength`. All slots are initialized at all times.
#if DEBUG
    private var storage: UnsafeMutablePointer<BufferLine?>
    private var capacity: Int
#else
    @exclusivity(unchecked) private var storage: UnsafeMutablePointer<BufferLine?>
    @exclusivity(unchecked) private var capacity: Int
#endif
    private var startIndex: Int
    var count: Int {
        get {
            return _count
        }
        set {
            precondition(newValue <= maxLength)
            // The slot count is always `maxLength`. Thus the ring does not
            // grow here. (The array version appended nil slots here, but
            // that code did not run.)
            assert(newValue <= capacity)
            _count = newValue
        }
    }

    public var isEmpty: Bool { count == 0 }
    /// Returns a copy of the slots in physical order.
    public func getArray() -> [BufferLine?] {
        Array(UnsafeBufferPointer(start: storage, count: capacity))
    }

    public func getStartIndex() -> Int {
        startIndex
    }

    private var _count: Int
    var maxLength: Int {
        didSet {
            if maxLength != oldValue {
                // Move the first `top` lines in logical order to the start of
                // the new slots. Release the old slots that do not move. Set
                // the other new slots to nil. `getCyclicIndex` must use the
                // old `startIndex` and the old `capacity`, so change them last.
                let oldStorage = storage
                let oldCapacity = capacity
                let newCapacity = Int(maxLength)
                let newStorage = UnsafeMutablePointer<BufferLine?>.allocate(capacity: newCapacity)
                let top = min (newCapacity, oldCapacity)
                var moved = 0
                while moved < top {
                    (newStorage + moved).initialize(to: (oldStorage + getCyclicIndex(moved)).move())
                    moved += 1
                }
                (newStorage + top).initialize(repeating: nil, count: newCapacity - top)
                // Release the old lines that did not move. The moved slots
                // are not initialized now, so do not touch them.
                var dropped = top
                while dropped < oldCapacity {
                    (oldStorage + getCyclicIndex(dropped)).deinitialize(count: 1)
                    dropped += 1
                }
                oldStorage.deallocate()
                storage = newStorage
                capacity = newCapacity
                startIndex = 0
                return
            }
        }
    }

    /// The buffer this list belongs to.
    ///
    /// This used to be four separate `[weak self]` / `[unowned self]` closures
    /// (`makeEmpty`, `onLineRecycled`, `onLinePushed`, `onLineAttached`), every
    /// one of which called straight back into the owning ``Buffer``. The `weak`
    /// captures among them put `Buffer` on the runtime's side-table refcount
    /// path for good, which costs about 9x on every retain and release of the
    /// buffer — and `onLineRecycled` fired on each scrolled line, paying a weak
    /// load on top. A plain back-pointer removes the side table, the weak load,
    /// and the closure indirection at once.
    ///
    /// `unowned(unsafe)` is sound here because the list is a private stored
    /// property of the buffer: it cannot outlive its owner, and no path hands a
    /// list to anyone else. See `Docs/io-cpu-profile.md` §3.1.
#if SWIFTTERM_EMBEDDED
    var owner: Buffer? = nil
#else
    unowned(unsafe) var owner: Buffer! = nil
#endif

    // Embedded needs a breakable optional owner to release its object graph.
    // Normal builds use the non-optional `unowned(unsafe)` owner above. Keep
    // the callbacks below direct in that configuration: they run for every
    // attached or recycled row, and using `owner?.` for both builds caused a
    // measurable scrolling regression.

    /// True only for a buffer's live line list.
    ///
    /// Reflow builds scratch lists to stage a rearrangement. Those need `owner`
    /// so an empty slot can still be filled, but they must not stamp line
    /// ownership or move the buffer's image counter — the lines they hold are
    /// already counted, and staging them again would double-count. Back when
    /// these were four independent optional closures, scratch lists got that for
    /// free by installing only `makeEmpty` and leaving the notification hooks
    /// nil. This flag preserves that split now that one back-pointer serves all
    /// four roles.
    var isLive: Bool = false

    public init (maxLength: Int)
    {
        capacity = Int(maxLength)
        storage = UnsafeMutablePointer<BufferLine?>.allocate(capacity: Int(maxLength))
        storage.initialize(repeating: nil, count: Int(maxLength))
        self.maxLength = maxLength
        self._count = 0
        self.startIndex = 0
    }

    // The class is final and no other object holds `storage`. Thus this
    // deinit can release the lines and free the slots.
    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// The private version exists to allow the Swift optimizer to avoid calls to
    /// `swift_beginAccess`
    private func getCyclicIndex(_ index: Int) -> Int {
        return Int(startIndex &+ index) % (capacity)
    }

    /// Public version of the same method
    func debugGetCyclicIndex(_ index: Int) -> Int {
        return getCyclicIndex(index)
    }

    subscript (index: Int) -> BufferLine {
        _read {
            let idx = getCyclicIndex(index)
            if storage[idx] == nil {
#if SWIFTTERM_EMBEDDED
                storage[idx] = owner!.makeEmptyLine(idx)
#else
                storage[idx] = owner.makeEmptyLine(idx)
#endif
            }
            yield storage[idx]!
        }
        set (newValue){
            storage [getCyclicIndex(index)] = newValue
#if SWIFTTERM_EMBEDDED
            if isLive { owner?.lineAttached(newValue) }
#else
            if isLive { owner.lineAttached(newValue) }
#endif
      }
    }

    func push (_ value: BufferLine)
    {
#if SWIFTTERM_EMBEDDED
        if isLive { owner?.lineAttached(value) }
#else
        if isLive { owner.lineAttached(value) }
#endif
        storage [getCyclicIndex(count)] = value
        if count == capacity {
            startIndex = startIndex + 1
            if startIndex == capacity {
                startIndex = 0
            }
        } else {
            count = count + 1
        }
#if SWIFTTERM_EMBEDDED
        if isLive { owner?.lineDidPush(hasImages: value.images != nil) }
#else
        if isLive { owner.lineDidPush(hasImages: value.images != nil) }
#endif
    }

    /// Calls `body` with the line at `index` without a retain.
    ///
    /// The subscript getter copies the line out of the slot. An inout access
    /// to the slot is exclusive, so the line can be lent from the slot.
    /// `body` must not access this list. Debug builds check this.
    @inline(__always)
    func withLine<R>(_ index: Int, _ body: (BufferLine) -> R) -> R
    {
        let idx = getCyclicIndex(index)
        if storage[idx] == nil {
#if SWIFTTERM_EMBEDDED
            storage[idx] = owner!.makeEmptyLine(idx)
#else
            storage[idx] = owner.makeEmptyLine(idx)
#endif
        }
        return Self.borrowSlot(&storage[idx], body)
    }

    @inline(__always)
    private static func borrowSlot<R>(_ slot: inout BufferLine?,
                                      _ body: (BufferLine) -> R) -> R
    {
        body(slot!)
    }

    /// Recycles a row with state that already belongs to the owner's arena.
    func recycle(clearCell: PackedCell, isWrapped: Bool,
                 bidiState: BidiPresentationState)
    {
        let hadImages = recycleOldestLine(clearCell: clearCell, isWrapped: isWrapped,
                                          bidiState: bidiState)
#if SWIFTTERM_EMBEDDED
        if isLive { owner?.lineWillRecycle(hadImages: hadImages) }
#else
        if isLive { owner.lineWillRecycle(hadImages: hadImages) }
#endif
    }

    /// Recycles a row and notifies `owner`, which must be this list's owner.
    ///
    /// The scroll path already borrows its buffer. Passing it here avoids the
    /// retain that a load of the stored `owner` property needs.
    @inline(__always)
    func recycle(owner: borrowing Buffer, clearCell: PackedCell, isWrapped: Bool,
                 bidiState: BidiPresentationState)
    {
        let hadImages = recycleOldestLine(clearCell: clearCell, isWrapped: isWrapped,
                                          bidiState: bidiState)
        if isLive { owner.lineWillRecycle(hadImages: hadImages) }
    }

    /// Moves the start of the full ring forward and clears the former first
    /// row. Returns `true` when that row had images.
    @inline(__always)
    private func recycleOldestLine(clearCell: PackedCell, isWrapped: Bool,
                                   bidiState: BidiPresentationState) -> Bool
    {
        assert(startIndex < capacity)
        precondition(count == maxLength, "can only recycle when the buffer is full")
        // A full ring makes getCyclicIndex(count) equal to startIndex.
        let index = startIndex
        let next = startIndex &+ 1
        startIndex = next == maxLength ? 0 : next
        // Borrow the line through its slot. A local binding or `storage[index]!`
        // copies the line and costs a retain and a release.
        // The line object is being destroyed for reuse. Clear its cells and
        // metadata with one generation change.
        return Self.borrowSlot(&storage[index]) { line in
            line.recycle(with: clearCell, isWrapped: isWrapped, bidiState: bidiState)
        }
    }

    @discardableResult
    func pop () -> BufferLine {
        let v = storage [getCyclicIndex(count-1)]!
        count = count - 1
        return v
    }

    func splice (start: Int, deleteCount: Int, items: [BufferLine], change: (Int) -> Void)
    {
        if deleteCount > 0 {
            var i = start
            let limit = count-deleteCount
            while i < limit {
                storage [getCyclicIndex(i)] = storage [getCyclicIndex(i+deleteCount)]
                change(i)
                i += 1
            }
            count = count - deleteCount
        }
        // add items
        var i = count-1
        let ic = items.count
        while i >= start {
#if DEBUG
            // print("Moving line \(i) to \(i + ic): \(storage[getCyclicIndex(i)].debugDescription)")
#endif
            storage [getCyclicIndex(i + ic)] = storage [getCyclicIndex(i)]
            change(i + ic)
            i -= 1
        }
        for i in 0..<ic {
            change(start + i)
#if SWIFTTERM_EMBEDDED
            if isLive { owner?.lineAttached(items [i]) }
#else
            if isLive { owner.lineAttached(items [i]) }
#endif
            storage [getCyclicIndex(start + i)] = items [i]
        }

        // Adjust length as needed
        if Int(count) + ic > capacity {
            let countToTrim = count + items.count - capacity
            startIndex = startIndex + countToTrim
            if capacity != 0 {
                startIndex %= capacity
            }
            count = capacity
        } else {
            count = count + items.count
        }
     }

    func trimStart (count: Int)
    {
        let c = count > self.count ? self.count : count
        startIndex = startIndex + c
        if capacity != 0 {
            startIndex %= capacity
        }
        self.count -= count
    }

    func shiftElements (start: Int, count: Int, offset: Int) -> Bool
    {
        func dumpState (_ msg: String) -> Bool {
            print ("Assertion at start=\(start) count=\(count) offset=\(offset): \(msg)")
            return false
        }

        if count < 0 {
            return dumpState ("count < 0")
        }
        if start < 0 {
            return dumpState ("start < 0")
        }
        if start >= self.count {
            return dumpState ("start >= self.count")
        }
        if start+offset <= 0 {
            return dumpState ("start+offset <= 0")
        }
        if offset > 0 {
            for i in (0..<count).reversed() {
                storage[getCyclicIndex(start + i + offset)] = storage[getCyclicIndex(start + i)]
            }
            let expandListBy = start + count + offset - self.count
            if expandListBy > 0 {
                self._count += expandListBy
                while self._count > maxLength {
                    self._count -= 1
                    startIndex += 1
                    if capacity != 0 {
                        startIndex %= capacity
                    }
                    // trimmed callback invoke
                }
            }
        } else {
            for i in 0..<count {
                storage[getCyclicIndex(start + i + offset)] = storage[getCyclicIndex(start + i)]
            }
        }
        return true
    }

    /// Moves a full-width region up by one row and reuses its former top row.
    /// The logical count and the circular start index do not change.
    func shiftUpAndRecycle(top: Int, bottom: Int, clearCell: PackedCell,
                           isWrapped: Bool,
                           bidiState: BidiPresentationState) -> Bool
    {
        guard let hadImages = shiftUpAndRecycleLines(top: top, bottom: bottom,
                                                     clearCell: clearCell,
                                                     isWrapped: isWrapped,
                                                     bidiState: bidiState) else {
            return false
        }
        if isLive {
#if SWIFTTERM_EMBEDDED
            owner?.lineWillRecycle(hadImages: hadImages)
#else
            owner.lineWillRecycle(hadImages: hadImages)
#endif
        }
        return true
    }

    /// Shifts a region and notifies `owner`, which must be this list's owner.
    /// See `recycle(owner:clearCell:isWrapped:bidiState:)`.
    @inline(__always)
    func shiftUpAndRecycle(owner: borrowing Buffer, top: Int, bottom: Int,
                           clearCell: PackedCell, isWrapped: Bool,
                           bidiState: BidiPresentationState) -> Bool
    {
        guard let hadImages = shiftUpAndRecycleLines(top: top, bottom: bottom,
                                                     clearCell: clearCell,
                                                     isWrapped: isWrapped,
                                                     bidiState: bidiState) else {
            return false
        }
        if isLive { owner.lineWillRecycle(hadImages: hadImages) }
        return true
    }

    /// Returns whether the recycled row had images, or `nil` when the region
    /// is not valid.
    private func shiftUpAndRecycleLines(top: Int, bottom: Int, clearCell: PackedCell,
                                        isWrapped: Bool,
                                        bidiState: BidiPresentationState) -> Bool?
    {
        func dumpState (_ message: String) -> Bool? {
            print("Assertion at top=\(top) bottom=\(bottom): \(message)")
            return nil
        }

        if top < 0 {
            return dumpState("top < 0")
        }
        if bottom < top {
            return dumpState("bottom < top")
        }
        if bottom >= count {
            return dumpState("bottom >= count")
        }

        let firstPhysicalIndex = startIndex
        let capacity = capacity

        let lines = storage
        let bottomSlot = lines.withMemoryRebound(to: UnsafeMutableRawPointer?.self,
                                                 capacity: capacity) {
            slots -> Int in
            // Each line keeps one slot reference. A raw store moves that
            // reference to the preceding slot without ARC work.
            var destination = (firstPhysicalIndex &+ top) % capacity
            // Take the top slot's reference. It moves to the
            // last slot below, so no retain or release is needed.
            let recycledSlot = slots[destination]
            if top < bottom {
                let moveCount = bottom - top
                if destination + moveCount < capacity {
                    // The existing raw-pointer binding transfers the
                    // slots' strong references without ARC operations.
                    // This range is contiguous and overlaps by one slot,
                    // so memmove preserves that ownership transfer.
#if SWIFTTERM_EMBEDDED
                    for offset in 0..<moveCount {
                        slots[destination + offset] = slots[destination + offset + 1]
                    }
#else
                    let byteCount = moveCount *
                        MemoryLayout<UnsafeMutableRawPointer?>.stride
                    memmove(slots.advanced(by: destination),
                            slots.advanced(by: destination + 1),
                            byteCount)
#endif
                    destination += moveCount
                } else {
                    // Keep the element loop when the circular range wraps.
                    for _ in top..<bottom {
                        var source = destination + 1
                        if source == capacity {
                            source = 0
                        }
                        slots[destination] = slots[source]
                        destination = source
                    }
                }
            }
            // The former last line is already in the preceding slot. Do
            // not release it when the recycled line moves into this slot.
            slots[destination] = recycledSlot
            return destination
        }
        // The former top row is now the bottom row. Clear it after the
        // move, as before: clearing it first put its cell stores in front
        // of the slot moves, and cycles then changed from run to run.
        //
        // Borrow the slot through the pointer. This does not retain
        // the line.
        if lines[bottomSlot] != nil {
            return Self.borrowSlot(&lines[bottomSlot]) { line in
                line.recycle(with: clearCell, isWrapped: isWrapped, bidiState: bidiState)
            }
        }

        // The recycled row was never created. `withLine` creates it.
        return withLine(bottom) { line in
            line.recycle(with: clearCell, isWrapped: isWrapped, bidiState: bidiState)
        }
    }

    /// Empties the ring in place and gives it `newMaxLength` slots.
    ///
    /// `Buffer.clear` uses this instead of replacing its list object. That
    /// keeps `Buffer._lines` a `let`, which lets the optimizer borrow the list
    /// at +0 on every ring access instead of retaining it around each load in
    /// case the property is reassigned underneath the access.
    ///
    /// Like `push`, `recycle`, and `shiftUpAndRecycle`, a live list keeps the
    /// owner's image accounting correct itself: every dropped line that
    /// carried images is reported before it goes.
    func reset(maxLength newMaxLength: Int) {
        if isLive {
            for index in 0..<capacity where storage[index]?.images != nil {
#if SWIFTTERM_EMBEDDED
                owner?.lineWillRecycle(hadImages: true)
#else
                owner.lineWillRecycle(hadImages: true)
#endif
            }
        }
        _count = 0
        startIndex = 0
        // Changing the length is the one allocation; the didSet builds the
        // new slots and moves the old references into it. Clearing the
        // slots afterwards releases them without a second allocation, and an
        // unchanged length allocates nothing.
        if maxLength != newMaxLength {
            maxLength = newMaxLength
        }
        for index in 0..<capacity {
            storage[index] = nil
        }
    }

    var isFull: Bool {
        get {
            return count == maxLength
        }
    }
}
