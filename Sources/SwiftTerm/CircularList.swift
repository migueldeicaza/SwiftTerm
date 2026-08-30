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

class CircularList<T> {
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

internal class CircularBufferLineList {
#if DEBUG
    private var array: [BufferLine?]
#else
    @exclusivity(unchecked) private var array: [BufferLine?]
#endif
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

    public var isEmpty: Bool { count == 0 }
    public func getArray() -> [BufferLine?] {
        array
    }

    public func getStartIndex() -> Int {
        startIndex
    }

    private var _count: Int
    var maxLength: Int {
        didSet {
            if maxLength != oldValue {
                let empty : BufferLine? = nil
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
        array = Array.init(repeating: nil, count: Int(maxLength))
        self.maxLength = maxLength
        self._count = 0
        self.startIndex = 0
    }

    /// The private version exists to allow the Swift optimizer to avoid calls to
    /// `swift_beginAccess`
    private func getCyclicIndex(_ index: Int) -> Int {
        return Int(startIndex &+ index) % (array.count)
    }

    /// Public version of the same method
    func debugGetCyclicIndex(_ index: Int) -> Int {
        return getCyclicIndex(index)
    }

    subscript (index: Int) -> BufferLine {
        _read {
            let idx = getCyclicIndex(index)
            if array[idx] == nil {
                array[idx] = owner!.makeEmptyLine(idx)
            }
            yield array[idx]!
        }
        set (newValue){
            array [getCyclicIndex(index)] = newValue
            if isLive { owner?.lineAttached(newValue) }
      }
    }

    func push (_ value: BufferLine)
    {
        if isLive { owner?.lineAttached(value) }
        array [getCyclicIndex(count)] = value
        if count == array.count {
            startIndex = startIndex + 1
            if startIndex == array.count {
                startIndex = 0
            }
        } else {
            count = count + 1
        }
        if isLive { owner?.lineDidPush(hasImages: value.images != nil) }
    }

    /// Recycles a row with state that already belongs to the owner's arena.
    func recycle(clearCell: PackedCell, isWrapped: Bool,
                 bidiState: BidiPresentationState)
    {
        precondition(count == maxLength, "can only recycle when the buffer is full")
        let index = getCyclicIndex(count)
        startIndex += 1
        startIndex = startIndex % maxLength
        // The array owns the line until this function finishes using it.
#if SWIFTTERM_EMBEDDED
        let line = array[index]!
#else
        unowned(unsafe) let line = array[index]!
#endif
        // The line object is being destroyed for reuse. Clear its cells and
        // metadata with one generation change.
        let hadImages = line.recycle(with: clearCell, isWrapped: isWrapped,
                                     bidiState: bidiState)
        if isLive { owner?.lineWillRecycle(hadImages: hadImages) }
    }

    @discardableResult
    func pop () -> BufferLine {
        let v = array [getCyclicIndex(count-1)]!
        count = count - 1
        return v
    }

    func splice (start: Int, deleteCount: Int, items: [BufferLine], change: (Int) -> Void)
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
            if isLive { owner?.lineAttached(items [i]) }
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
        if offset > 0 {
            for i in (0..<count).reversed() {
                array[getCyclicIndex(start + i + offset)] = array[getCyclicIndex(start + i)]
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
                array[getCyclicIndex(start + i + offset)] = array[getCyclicIndex(start + i)]
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
        func dumpState (_ message: String) -> Bool {
            print("Assertion at top=\(top) bottom=\(bottom): \(message)")
            return false
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

        // Keep this reference alive while its array slot is overwritten.
        let recycledLine = self[top]
        let hadImages = recycledLine.images != nil
        let firstPhysicalIndex = startIndex
        let capacity = array.count

        // The local reference must stay alive until its array ownership moves
        // to the last slot.
        withExtendedLifetime(recycledLine) {
            array.withUnsafeMutableBufferPointer { lines in
                lines.withMemoryRebound(to: UnsafeMutableRawPointer?.self) { slots in
                    // Each line keeps one array reference. A raw store moves that
                    // reference to the preceding slot without ARC work.
                    var destination = (firstPhysicalIndex &+ top) % capacity
                    if top < bottom {
                        for _ in top..<bottom {
                            var source = destination + 1
                            if source == capacity {
                                source = 0
                            }
                            slots[destination] = slots[source]
                            destination = source
                        }
                    }
                    // The former last line is already in the preceding slot. Do
                    // not release it when recycledLine moves into this slot.
                    slots[destination] = Unmanaged.passUnretained(recycledLine).toOpaque()
                }
            }
        }

        recycledLine.recycle(with: clearCell, isWrapped: isWrapped,
                             bidiState: bidiState)
        if isLive {
            owner?.lineWillRecycle(hadImages: hadImages)
        }
        return true
    }

    var isFull: Bool {
        get {
            return count == maxLength
        }
    }
}
