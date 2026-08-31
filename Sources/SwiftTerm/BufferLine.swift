//
//  BufferLine.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/26/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation

/// BufferLines represents a single line of text displayed on the terminal

public final class BufferLine: CustomDebugStringConvertible {
    /// An immutable identity object that render snapshots can retain without
    /// retaining the mutable line itself. Retention prevents address reuse
    /// while a renderer cache can still refer to the identity.
    final class RenderIdentity: Sendable {}

    let renderIdentity = RenderIdentity()

    public enum RenderLineMode {
        /// Render each character using a single cell
        case single
        /// Render character using two cells
        case doubleWidth
        /// Render the top of a character using two cells
        case doubledTop
        /// Renders the bottom of a character, using two cells
        case doubledDown
    }
    private var isWrappedValue: Bool
    /// True when this line is a continuation of the previous line: the text
    /// soft-wrapped onto it rather than starting after an explicit newline.
    public internal(set) var isWrapped: Bool {
        get { isWrappedValue }
        set {
            guard newValue != isWrappedValue else { return }
            isWrappedValue = newValue
            bump()
        }
    }
    private var bidiStateValue: BidiPresentationState
    /// BiDi state for the paragraph that contains this row.
    public internal(set) var bidiState: BidiPresentationState {
        get { bidiStateValue }
        set {
            guard newValue != bidiStateValue else { return }
            bidiStateValue = newValue
            bump()
        }
    }
    private var renderModeValue: RenderLineMode = .single
    var renderMode: RenderLineMode {
        get { renderModeValue }
        set {
            guard newValue != renderModeValue else { return }
            renderModeValue = newValue
            bump()
        }
    }
#if DEBUG
    private var semanticMarksValue: [SemanticMark] = []
#else
    @exclusivity(unchecked) private var semanticMarksValue: [SemanticMark] = []
#endif
    /// Shell-authored OSC 133 marks on this line, at most one per kind.
    /// A line can carry both a left prompt and a right prompt mark.
    private(set) var semanticMarks: [SemanticMark] {
        get { semanticMarksValue }
        set {
            guard newValue != semanticMarksValue else { return }
            semanticMarksValue = newValue
            bump()
        }
    }
    /// The prompt-group epoch of a line created by a hard line feed inside a
    /// prompt group: the active group ID at stamp time, or nil for a line that
    /// is not a hard continuation. Together with `isWrapped` this is what makes
    /// a row derivable as a continuation, and the group ID is what keeps an old
    /// group's stranded rows from joining a new prompt (R1/R5). Exactly one
    /// function assigns it: `Terminal.finishSemanticLineAdvance`.
    ///
    /// It is structural, not content: cell erasure (EL/ED) never touches it.
    /// Derivation-only metadata, not drawn, so it bumps the render generation
    /// only on an actual change.
    private var semanticHardContinuationGroupValue: UInt64? = nil
    var semanticHardContinuationGroup: UInt64? {
        get { semanticHardContinuationGroupValue }
        set {
            guard newValue != semanticHardContinuationGroupValue else { return }
            semanticHardContinuationGroupValue = newValue
            bump()
        }
    }
    /// Link to the owning buffer, used only so `copyFrom` can ask which of two
    /// colliding same-kind marks is the live origin. Lines that never carry
    /// marks (bare templates) leave this nil.
    ///
    /// This deliberately goes through ``BufferRef`` instead of being a `weak
    /// var`. Forming even one `weak` reference to a `Buffer` moves it onto the
    /// runtime's side-table refcount path permanently, and measured on an M-series
    /// Mac that costs 9.3x on *every* retain and release of the buffer
    /// (3.5 ns -> 32.4 ns) — a bill the parse loop pays constantly while the
    /// reference below is read only on rows that carry semantic marks. The box
    /// is held strongly from both ends and cleared in `Buffer.deinit`, so the
    /// pointer inside it is never dangling. See `Docs/io-cpu-profile.md` §3.1.
    var owningBufferRef: BufferRef? = nil

    /// The owning buffer, or nil after the buffer is torn down.
    var owningBuffer: Buffer? {
        get { owningBufferRef?.buffer }
        set { owningBufferRef = newValue?.selfRef }
    }
    /// Bumped each time this line object is reused for different content
    /// (recycle, reset). A deferred pointer click captures this alongside the
    /// line identity; a mismatch at fire time means the object was recycled
    /// into a new row and the click must be dropped — identity alone cannot
    /// tell, because `CircularList.recycle` keeps the object in the array.
    private(set) var recycleGeneration: UInt64 = 0
    // The page owns only packed cells. Its arena is shared by all lines in the
    // same terminal.
    private var storage: CellStoragePage

    /// Upper bound on the cells that can contain data other than a blank cell
    /// with ``tailBlankCell``.
    ///
    /// **Invariant:** Each cell in `usedLength ..< storage.count` is
    /// `tailBlankCell`.
    ///
    /// This value lets ``clear(with:)`` clear only the written part of a row.
    /// Terminal rows are usually shorter than `cols`, so the tail often does
    /// not require a write. See `Docs/io-cpu-profile.md` §10.
    ///
    /// An incorrect value can leave old text in a recycled row. Simple writers
    /// update this value accurately. Bulk operations set it to `storage.count`.
    /// The `storage` property is private, so this file contains all updates.
    private var usedLength: Int

    /// The packed blank stored after ``usedLength``.
    /// This value is valid only when `usedLength < storage.count`.
    private var tailBlankCell = PackedCell()

    /// Marks the full row as potentially dirty.
    @inline(__always)
    private func invalidateUsedLength () { usedLength = storage.count }

    /// Records that cells before `end` can contain written data.
    @inline(__always)
    private func noteWritten (upTo end: Int) {
        if end > usedLength { usedLength = min(end, storage.count) }
    }

    /// Checks the ``usedLength`` invariant against the stored cells.
    @inline(__always)
    private func assertTailIsBlank () {
        #if DEBUG
        guard usedLength < storage.count else { return }
        for i in usedLength..<storage.count {
            assert(storage.rawCell(at: i) == tailBlankCell,
                   "BufferLine.usedLength invariant failed at cell \(i) of \(storage.count) " +
                   "(usedLength=\(usedLength)). A writer changed a cell after usedLength.")
        }
        #endif
    }

    private var imagesValue: [TerminalImage]? = nil
    var images: [TerminalImage]? {
        get { imagesValue }
        set {
            // The common recycle and snapshot path writes nil to an empty row.
            guard newValue != nil || imagesValue != nil else { return }
            imagesValue = newValue
            bump()
        }
    }

    /// Monotonically increasing counter incremented on every mutation of this line's
    /// contents (cells, isWrapped, renderMode, images). Renderers that cache per-line
    /// draw state can compare this counter against a cached value to detect in-place
    /// changes without diffing individual cells.
    public var generation: UInt64 { _generation }
    private(set) var _generation: UInt64 = 0

    @inline(__always)
    private func bump() { _generation &+= 1 }

    public convenience init (cols: Int, fillData: CharData? = nil, isWrapped: Bool = false,
                             bidiState: BidiPresentationState = .default)
    {
        self.init(cols: cols, fillData: fillData, isWrapped: isWrapped,
                  bidiState: bidiState, arena: CellArena())
    }

    convenience init (cols: Int, fillData: CharData? = nil, isWrapped: Bool = false,
                      bidiState: BidiPresentationState = .default, arena: CellArena)
    {
        let fillCharacter = fillData ?? CharData.Null
        let packedFill = arena.pack(fillCharacter)!
        let blank = arena.pack(attribute: fillCharacter.attribute, scalar: 0,
                               widthState: .narrow)!
        self.init(cols: cols, packedFill: packedFill,
                  blankTailCell: packedFill == blank ? blank : nil,
                  isWrapped: isWrapped, bidiState: bidiState, arena: arena)
    }

    init(cols: Int, packedFill: PackedCell, blankTailCell: PackedCell? = nil,
         isWrapped: Bool = false, bidiState: BidiPresentationState = .default,
         arena: CellArena)
    {
        isWrappedValue = isWrapped
        bidiStateValue = bidiState
        storage = CellStoragePage(count: cols, repeating: packedFill, arena: arena)
        usedLength = blankTailCell == nil ? cols : 0
        tailBlankCell = blankTailCell ?? PackedCell()
    }

    public init (from other: BufferLine)
    {
        isWrappedValue = other.isWrappedValue
        bidiStateValue = other.bidiStateValue
        renderModeValue = other.renderModeValue
        semanticMarksValue = other.semanticMarksValue
        semanticHardContinuationGroupValue = other.semanticHardContinuationGroupValue
        // owningBuffer is NOT inherited: a clone is stamped with its real
        // owner when it is attached to a buffer (B.3). Inheriting it from a
        // cross-buffer template leaks the wrong owner.
        imagesValue = other.imagesValue
        storage = CellStoragePage(copying: other.storage)
        usedLength = other.usedLength
        tailBlankCell = other.tailBlankCell
    }

    /// Returns the number of CharData cells in this row
    public var count: Int {
        get {
            return storage.count
        }
    }

    /// The 64-bit cell path used inside SwiftTerm. Public clients continue to
    /// use the `CharData` subscript below.
    @inline(__always)
    func packedCell(at index: Int) -> PackedCell {
        guard let index = clampedCellIndex(index) else {
            return storage.arena.pack(CharData.Null)!
        }
        return storage.rawCell(at: index)
    }

    @inline(__always)
    func packedView(at index: Int) -> PackedCellView {
        PackedCellView(packed: packedCell(at: index), arena: storage.arena)
    }

    @inline(__always)
    func setPackedCell(_ cell: PackedCell, at index: Int) {
        let target = min(index, storage.count - 1)
        storage.setRawCell(cell, at: target)
        if target >= usedLength { usedLength = target &+ 1 }
        bump()
    }

    /// Removes the wide-cell seams that a write of `width` cells starting at
    /// `x` is about to break before the caller writes.
    ///
    /// The check is keyed on the cells being overwritten rather than on their
    /// neighbours, which is what Ghostty's `printCell` does. Under the cell
    /// invariant a `.spacerTail` at `x` implies a `.wide` head at `x - 1`, and
    /// a `.wide` head at the last written cell implies a `.spacerTail` just
    /// past it, so the destination cells carry the same information the
    /// neighbours do. The common narrow-over-narrow write therefore reads one
    /// cell — the one it is about to store into, already in cache — instead of
    /// the two neighbour cells `repairWideSeam` reads.
    @inline(__always)
    func repairSeamsForWrite(at x: Int, width: Int) {
#if SWIFTTERM_SEAM_COUNTER
        SeamRepairCounter.shared.recordCall()
#endif
        let cellCount = storage.count
        guard x >= 0, x < cellCount else { return }
        let first = storage.rawCell(at: x)
        let lastIndex = min(x &+ width &- 1, cellCount &- 1)
        let last = lastIndex == x ? first : storage.rawCell(at: lastIndex)
        if first.isNarrowWidth && last.isNarrowWidth { return }
        repairSeamsForWriteSlow(at: x, first: first,
                                lastIndex: lastIndex, last: last,
                                cellCount: cellCount)
    }

    /// The rare half of `repairSeamsForWrite`. Kept out of line so the common
    /// path stays a load and a mask test.
    private func repairSeamsForWriteSlow(at x: Int, first: PackedCell,
                                         lastIndex: Int, last: PackedCell,
                                         cellCount: Int)
    {
        var repaired = false
        if first.widthState == .spacerTail, x > 0 {
            let headIndex = x &- 1
            let head = storage.rawCell(at: headIndex)
            if head.widthState == .wide {
                storage.setRawCell(head.demotedToNarrowBlank(), at: headIndex)
                repaired = true
            }
        }
        if last.widthState == .wide, lastIndex &+ 1 < cellCount {
            let tailIndex = lastIndex &+ 1
            let tail = storage.rawCell(at: tailIndex)
            if tail.widthState == .spacerTail {
                storage.setRawCell(tail.demotedToNarrowBlank(), at: tailIndex)
                repaired = true
            }
        }
        if repaired {
#if SWIFTTERM_SEAM_COUNTER
            SeamRepairCounter.shared.recordRepair()
#endif
            bump()
        }
    }

    func repairWideSeam(at x: Int) {
#if SWIFTTERM_SEAM_COUNTER
        SeamRepairCounter.shared.recordCall()
#endif
        guard x > 0, x - 1 < storage.count else { return }
        let headIndex = x - 1
        let head = storage.rawCell(at: headIndex)
        guard head.widthState == .wide else { return }
#if SWIFTTERM_SEAM_COUNTER
        SeamRepairCounter.shared.recordRepair()
#endif

        storage.setRawCell(head.demotedToNarrowBlank(), at: headIndex)
        if x < storage.count {
            let tail = storage.rawCell(at: x)
            if tail.widthState == .spacerTail {
                storage.setRawCell(tail.demotedToNarrowBlank(), at: x)
            }
        }
        bump()
    }

    func setPackedAsciiRun(_ bytes: ArraySlice<UInt8>, sourceStart: Int,
                           count: Int, at destinationStart: Int,
                           styleID: UInt16, payloadCode: UInt16 = 0,
                           semanticContentCode: UInt8)
    {
        guard count > 0 else { return }
        precondition(sourceStart >= bytes.startIndex && sourceStart <= bytes.endIndex)
        precondition(count <= bytes.endIndex - sourceStart)
        let destinationEnd = destinationStart + count
        if destinationStart > 0, destinationStart < storage.count,
           storage.rawCell(at: destinationStart).widthState == .spacerTail {
            let headIndex = destinationStart - 1
            let head = storage.rawCell(at: headIndex)
            storage.setRawCell(head.demotedToNarrowBlank(), at: headIndex)
        }
        if destinationEnd < storage.count {
            let tail = storage.rawCell(at: destinationEnd)
            if tail.widthState == .spacerTail {
                storage.setRawCell(tail.demotedToNarrowBlank(), at: destinationEnd)
            }
        }
        let template = PackedCell.makeUnchecked(contentTag: .codepoint, content: 0,
                                                styleID: styleID, widthState: .narrow,
                                                isProtected: false, payloadCode: payloadCode,
                                                semanticContentCode: semanticContentCode).rawValue
        let source = bytes.span
            .extracting(droppingFirst: sourceStart - bytes.startIndex)
            .extracting(first: count)
        for offset in source.indices {
            let rawValue = template |
                (UInt64(source[offset]) << PackedCell.contentShift)
            storage.setRawCell(PackedCell(rawValue: rawValue),
                               at: destinationStart + offset)
        }
        noteWritten(upTo: destinationEnd)
        bump()
    }

    func setPackedAsciiRun(_ bytes: Span<UInt8>, sourceStart: Int,
                           count: Int, at destinationStart: Int,
                           styleID: UInt16, payloadCode: UInt16 = 0,
                           semanticContentCode: UInt8)
    {
        guard count > 0 else { return }
        precondition(sourceStart >= 0 && sourceStart <= bytes.count)
        precondition(count <= bytes.count - sourceStart)
        let destinationEnd = destinationStart + count
        if destinationStart > 0, destinationStart < storage.count,
           storage.rawCell(at: destinationStart).widthState == .spacerTail {
            let headIndex = destinationStart - 1
            let head = storage.rawCell(at: headIndex)
            storage.setRawCell(head.demotedToNarrowBlank(), at: headIndex)
        }
        if destinationEnd < storage.count {
            let tail = storage.rawCell(at: destinationEnd)
            if tail.widthState == .spacerTail {
                storage.setRawCell(tail.demotedToNarrowBlank(), at: destinationEnd)
            }
        }
        let template = PackedCell.makeUnchecked(contentTag: .codepoint, content: 0,
                                                styleID: styleID, widthState: .narrow,
                                                isProtected: false, payloadCode: payloadCode,
                                                semanticContentCode: semanticContentCode).rawValue
        let source = bytes.extracting(sourceStart..<(sourceStart + count))
        for offset in source.indices {
            let rawValue = template |
                (UInt64(source[offset]) << PackedCell.contentShift)
            storage.setRawCell(PackedCell(rawValue: rawValue),
                               at: destinationStart + offset)
        }
        noteWritten(upTo: destinationEnd)
        bump()
    }

    /// Writes validated Unicode scalars that all have the same cell width.
    func setPackedScalarRun(_ scalars: UnsafeBufferPointer<UInt32>,
                            sourceStart: Int, count: Int,
                            at destinationStart: Int,
                            widthState: PackedCell.WidthState,
                            styleID: UInt16, payloadCode: UInt16 = 0,
                            semanticContentCode: UInt8)
    {
        guard count > 0 else { return }
        precondition(widthState == .narrow || widthState == .wide)
        precondition(sourceStart >= 0 && sourceStart <= scalars.count)
        precondition(count <= scalars.count - sourceStart)
        let cellWidth = widthState == .wide ? 2 : 1
        let destinationEnd = destinationStart + count * cellWidth
        if destinationStart > 0, destinationStart < storage.count,
           storage.rawCell(at: destinationStart).widthState == .spacerTail {
            let headIndex = destinationStart - 1
            let head = storage.rawCell(at: headIndex)
            storage.setRawCell(head.demotedToNarrowBlank(), at: headIndex)
        }
        if destinationEnd < storage.count {
            let tail = storage.rawCell(at: destinationEnd)
            if tail.widthState == .spacerTail {
                storage.setRawCell(tail.demotedToNarrowBlank(), at: destinationEnd)
            }
        }
        let headTemplate = PackedCell.makeUnchecked(
            contentTag: .codepoint, content: 0, styleID: styleID,
            widthState: widthState, isProtected: false,
            payloadCode: payloadCode,
            semanticContentCode: semanticContentCode).rawValue
        if widthState == .wide {
            let tail = PackedCell.makeUnchecked(
                contentTag: .codepoint, content: 0, styleID: styleID,
                widthState: .spacerTail, isProtected: false,
                payloadCode: payloadCode,
                semanticContentCode: semanticContentCode)
            for offset in 0..<count {
                let destination = destinationStart + offset * 2
                let rawValue = headTemplate |
                    (UInt64(scalars[sourceStart + offset]) << PackedCell.contentShift)
                storage.setRawCell(PackedCell(rawValue: rawValue), at: destination)
                storage.setRawCell(tail, at: destination + 1)
            }
        } else {
            for offset in 0..<count {
                let rawValue = headTemplate |
                    (UInt64(scalars[sourceStart + offset]) << PackedCell.contentShift)
                storage.setRawCell(PackedCell(rawValue: rawValue),
                                   at: destinationStart + offset)
            }
        }
        noteWritten(upTo: destinationEnd)
        bump()
    }

    @inline(__always)
    func packedCode(at index: Int) -> Int32 { packedView(at: index).code }

    @inline(__always)
    func packedWidth(at index: Int) -> Int8 { packedView(at: index).width }

    @inline(__always)
    func packedAttribute(at index: Int) -> Attribute { packedView(at: index).attribute }

    @inline(__always)
    func packedCharacter(at index: Int) -> Character { packedView(at: index).getCharacter() }

    @inline(__always)
    func packedIsSimpleRune(at index: Int) -> Bool { packedView(at: index).isSimpleRune }

    @inline(__always)
    private func clampedCellIndex(_ index: Int) -> Int? {
        guard storage.count > 0 else { return nil }
        return min(max(index, 0), storage.count - 1)
    }

    @inline(__always)
    func pack(_ value: CharData) -> PackedCell { storage.packed(value) }

    var cellArena: CellArena { storage.arena }

    func adoptArena(_ arena: CellArena) {
        guard storage.arena !== arena else { return }
        let tailAttribute = storage.arena.attribute(for: tailBlankCell)
        storage = storage.rehomed(to: arena)
        tailBlankCell = arena.pack(attribute: tailAttribute, scalar: 0,
                                   widthState: .narrow)!
    }

    public func getData() -> [CharData] {
        (0..<storage.count).map { storage.cell(at: $0) }
    }

    /// Accesses the CharIndex at the specified position
    public subscript (index : Int /*, callingMethod: String = #function */) -> CharData {
        get {
            // The x value in a buffer can point beyond the column, due to the way that we allow
            // buffer.x to grow (this is to support some wrapmodes and write on the edge)
            let dataSize = storage.count
            if index >= dataSize {
                /* print ("Warning: the method \(callingMethod) has not been audited to clamp buffer.x to cols-1; fixing") */
                return storage.cell(at: dataSize - 1)
            }
            return storage.cell(at: index)
        }
        set(value) {
            if index >= storage.count {
                // All bugs I was aware of have been handled, but keep this message here to
                // help future refactorings.
                print("BufferLine: You passed an index out of range, adjusting to prevent crash, but you should debug")
                storage.setCell(value, at: storage.count - 1)
                usedLength = storage.count
            } else {
                storage.setCell(value, at: index)
                if index >= usedLength { usedLength = index &+ 1 }
            }
            bump()
        }
    }

    /// Returns the number of character cells the element at this position occupies.
    public func getWidth (index: Int) -> Int {
        return Int(storage.width(at: index))
    }

    /// Clears only cell and image state. Semantic metadata survives ordinary
    /// erase operations.
    @inline(__always)
    private func clearCellState(with empty: PackedCell) {
        assertTailIsBlank()
        if usedLength == storage.count || empty != tailBlankCell {
            storage.fill(with: empty)
        } else if usedLength > 0 {
            storage.fill(with: empty, in: 0..<usedLength)
        }
        tailBlankCell = empty
        usedLength = 0
        // Most recycled lines have no images. Do not call ARC for an
        // optional array that is already nil.
        if imagesValue != nil {
            imagesValue = nil
        }
    }

    /// Clears a row while preserving its semantic metadata.
    func clear(with empty: PackedCell) {
        clearCellState(with: empty)
        recycleGeneration &+= 1
        bump()
    }

    /// Resets a line object for reuse. This is one logical mutation, so it
    /// bypasses the individual metadata setters and changes `generation` once.
    @discardableResult
    func recycle(with empty: PackedCell, isWrapped: Bool,
                 bidiState: BidiPresentationState) -> Bool {
        let hadImages = imagesValue != nil
        clearCellState(with: empty)
        if !semanticMarksValue.isEmpty {
            semanticMarksValue.removeAll(keepingCapacity: true)
        }
        semanticHardContinuationGroupValue = nil
        isWrappedValue = isWrapped
        bidiStateValue = bidiState
        renderModeValue = .single
        recycleGeneration &+= 1
        bump()
        return hadImages
    }

    /// Removes the semantic prompt metadata. Called only when the line
    /// itself is destroyed (recycled for reuse), never by cell mutations.
    func destroySemanticState() {
        guard !semanticMarksValue.isEmpty || semanticHardContinuationGroupValue != nil else {
            return
        }
        if !semanticMarksValue.isEmpty {
            semanticMarksValue.removeAll(keepingCapacity: true)
        }
        semanticHardContinuationGroupValue = nil
        bump()
    }
    /// Test whether contains any chars.
    public func hasContent (index: Int) -> Bool {
        return storage.logicalCode(at: index) != 0 ||
            storage.attribute(at: index) != CharData.defaultAttr
    }

    /// True if the buffer line has any values stored in it, false otherwise
    public func hasAnyContent () -> Bool {
        for i in 0..<storage.count {
            if hasContent(index: i) {
                return true
            }
        }
        return false
    }

    /// Repeatedly inserts a CharData elements into the buffer line.
    /// - Parameters:
    ///  - pos: position where to insert the data
    ///  - n: the number of times the data is inserted
    ///  - fillData: the data that will be filled into the line
    public func insertCells (pos: Int, n: Int, rightMargin: Int, fillData: CharData)
    {
        insertPackedCells(pos: pos, n: n, rightMargin: rightMargin,
                          fill: storage.packed(fillData))
    }

    func insertPackedCells(pos: Int, n: Int, rightMargin: Int, fill: PackedCell)
    {
        defer { invalidateUsedLength() }
        let len = rightMargin + 1
        let pos = pos % len
        repairWideSeam(at: pos)
        repairWideSeam(at: rightMargin + 1)
        if n < len - pos {
            repairWideSeam(at: len - n)
            for i in (0..<len-pos-n).reversed() {
                storage.setRawCell(storage.rawCell(at: pos + i), at: pos + n + i)
            }
            for i in 0..<n {
                storage.setRawCell(fill, at: pos + i)
            }
        } else {
            for i in pos..<len {
                storage.setRawCell(fill, at: i)
            }
        }
        marksShift(from: pos, by: n, rightMargin: rightMargin)
        bump()
    }

    /// Removes the cells at the specified position, shifting data leftwards
    public func deleteCells (pos: Int, n: Int, rightMargin: Int, fillData: CharData)
    {
        deletePackedCells(pos: pos, n: n, rightMargin: rightMargin,
                          fill: storage.packed(fillData))
    }

    func deletePackedCells(pos: Int, n: Int, rightMargin: Int, fill: PackedCell)
    {
        defer { invalidateUsedLength() }
        let len = rightMargin + 1
        let p = pos % len
        repairWideSeam(at: pos)
        repairWideSeam(at: pos + n)
        repairWideSeam(at: rightMargin + 1)
        if n < len - p {
            for i in 0..<len-pos-n {
                storage.setRawCell(storage.rawCell(at: pos + n + i), at: pos + i)
            }
            for i in len-n..<len {
                storage.setRawCell(fill, at: i)
            }
        } else {
            for i in pos..<len {
                storage.setRawCell(fill, at: i)
            }
        }
        marksShift(from: pos, by: -n, rightMargin: rightMargin)
        bump()
    }

    /// Shifts mark columns with their cells when ICH inserts or DCH deletes
    /// cells at `pos` inside the margin. Marks are never removed here: a mark
    /// whose cell was deleted lands on `pos`, one pushed past the margin
    /// stays on the margin.
    func marksShift(from pos: Int, by delta: Int, rightMargin: Int) {
        guard delta != 0, !semanticMarks.isEmpty else { return }
        semanticMarks = semanticMarks.map { mark in
            guard mark.column >= pos, mark.column <= rightMargin else { return mark }
            var result = mark
            result.column = min(max(mark.column + delta, pos), rightMargin)
            return result
        }
    }

    /// Clamps every mark column into the line's content width, for shrinking
    /// resizes. A zero-width line can hold no marks.
    func marksClampTo(width: Int) {
        guard !semanticMarks.isEmpty else { return }
        if width <= 0 {
            semanticMarks.removeAll(keepingCapacity: true)
            return
        }
        semanticMarks = semanticMarks.map { mark in
            var result = mark
            result.column = min(max(mark.column, 0), width - 1)
            return result
        }
    }

    /// Stores a shell-authored mark. Setting a mark of a kind the line
    /// already carries replaces that mark: readline redisplay re-emits `A`
    /// on the same row on every repaint.
    func setSemanticMark(kind: SemanticPromptKind, column: Int, group: UInt64) {
        semanticMarks.removeAll { $0.kind == kind }
        semanticMarks.append(SemanticMark(kind: kind, column: column, group: group))
        semanticMarks.sort { $0.column < $1.column }
    }

    /// Replaces the cells in the start to end range with the specified fill data.
    /// Cell erasure never touches the continuation epoch (R1: structural, not
    /// content).
    public func replaceCells (start: Int, end: Int, fillData : CharData)
    {
        replacePackedCells(start: start, end: end, fill: storage.packed(fillData))
    }

    func replacePackedCells(start: Int, end: Int, fill: PackedCell)
    {
        let length = storage.count
        let idx = min(end, length)
        if start < idx {
            storage.fill(with: fill, in: start..<idx)
        }
        noteWritten(upTo: idx)
        bump()
    }

    /// Resizes the buffer line, if the new size is larger, the empty region is filled with
    /// `fillData` values, if it is smaller, the data is trimmed
    public func resize (cols: Int, fillData: CharData)
    {
        resize(cols: cols, fill: storage.packed(fillData))
    }

    func resize(cols: Int, fill: PackedCell)
    {
        defer { invalidateUsedLength() }
        let len = storage.count
        if len == cols {
            return
        }
        defer { bump() }

        storage = storage.resized(to: cols, fill: fill)
        if cols < len {
            marksClampTo(width: cols)
        }
    }

    /// Fills the entire bufferline with the specified ``CharData``
    public func fill (with: CharData)
    {
        fill(with: storage.packed(with))
    }

    func fill(with packed: PackedCell)
    {
        storage.fill(with: packed)
        invalidateUsedLength()
        bump()
    }

    /// Fills the specified region of the bufferline with the specified ``CharData``
    /// - Parameters:
    ///  - with: the ``CharData`` to fill the region with
    ///  - atCol: starting column to fill at
    ///  - len: number of columns to fill
    public func fill (with: CharData, atCol: Int, len: Int)
    {
        fill(with: storage.packed(with), atCol: atCol, len: len)
    }

    func fill(with packed: PackedCell, atCol: Int, len: Int)
    {
        storage.fill(with: packed, in: atCol..<(atCol + len))
        noteWritten(upTo: atCol + len)
        bump()
    }

    /// Fills the current BufferLine with the contents of another BufferLine.
    public func copyFrom (line: BufferLine)
    {
        if line !== self {
            if line.storage.arena === storage.arena && line.storage.count == storage.count {
                storage.copyCells(from: line.storage, sourceStart: 0,
                                  destinationStart: 0, count: storage.count)
            } else {
                storage = line.storage.arena === storage.arena
                    ? CellStoragePage(copying: line.storage)
                    : line.storage.rehomed(to: storage.arena)
            }
            usedLength = line.usedLength
            if line.storage.arena === storage.arena {
                tailBlankCell = line.tailBlankCell
            } else {
                let tailAttribute = line.storage.arena.attribute(for: line.tailBlankCell)
                tailBlankCell = storage.arena.pack(attribute: tailAttribute, scalar: 0,
                                                   widthState: .narrow)!
            }
        }
        isWrapped = line.isWrapped
        semanticMarks = line.semanticMarks
        semanticHardContinuationGroup = line.semanticHardContinuationGroup
        bidiState = line.bidiState
        bump()
    }

    /// Copies the renderable state of `line` into this reusable snapshot line.
    ///
    /// Snapshot rows own their cells. They do not carry live semantic marks or
    /// image objects. `TerminalSnapshot` copies image placement separately.
    func copyForSnapshot (from line: BufferLine, arena snapshotArena: CellArena)
    {
        if line !== self {
            if storage.arena === snapshotArena &&
               line.storage.count == storage.count {
                storage.copyPackedCells(from: line.storage, sourceStart: 0,
                                        destinationStart: 0, count: storage.count)
            } else {
                storage = CellStoragePage(copyingPacked: line.storage,
                                          arena: snapshotArena)
            }
            usedLength = line.usedLength
            // Snapshot arenas preserve terminal identifiers exactly.
            tailBlankCell = line.tailBlankCell
        }
        isWrapped = line.isWrapped
        bidiState = line.bidiState
        renderMode = line.renderMode
        semanticMarks.removeAll(keepingCapacity: true)
        semanticHardContinuationGroup = nil
        images = nil
        bump()
    }

    /// Returns the trimmed length in terms of cells used from the BufferLine
    ///
    public func getTrimmedLength () -> Int
    {
        for i in (0..<storage.count).reversed() {
            let code = storage.logicalCode(at: i)
            if code != 0 {
                return i + Int(storage.width(at: i))
            }
        }
        return 0
    }

    /// Copies a range of CharData elements from another bufferline into this one
    /// - Parameters:
    ///  - src: the buffer line to copy from
    ///  - srcCol: the column index in the other buffer line
    ///  - dstCol: the destination in this buffer line
    ///  - len: the number of elements to copy
    public func copyFrom (_ src: BufferLine, srcCol: Int, dstCol: Int, len: Int)
    {
        defer { noteWritten(upTo: dstCol + len) }
        let movesSemanticHardContinuation = srcCol == 0 && dstCol == 0 && len >= count
        let movedSemanticHardContinuationGroup = src.semanticHardContinuationGroup
        if len > 0 {
            storage.copyCells(from: src.storage, sourceStart: srcCol,
                              destinationStart: dstCol, count: len)
        }
        // Marks travel with their cells. The margin-scroll paths and reflow
        // shuffle cell ranges between line objects through this call, and a
        // mark's row is wherever its cells went: this moves marks, it never
        // authors them. Marks outside the copied range stay where they are.
        let moved = src.semanticMarks.filter { $0.column >= srcCol && $0.column < srcCol + len }
        // Snapshot the live origin before the marks move, so a same-kind
        // collision can be resolved by liveness rather than position. Skipped
        // entirely on the common no-marks scroll row (E.5).
        let origin = moved.isEmpty ? nil : owningBuffer?.rawSemanticOrigin()
        if src === self {
            semanticMarks.removeAll {
                ($0.column >= srcCol && $0.column < srcCol + len) ||
                ($0.column >= dstCol && $0.column < dstCol + len)
            }
        } else {
            src.semanticMarks.removeAll { $0.column >= srcCol && $0.column < srcCol + len }
            semanticMarks.removeAll { $0.column >= dstCol && $0.column < dstCol + len }
        }
        if !moved.isEmpty {
            var originMovedHere = false
            for mark in moved {
                let newColumn = mark.column - srcCol + dstCol
                let movedIsOrigin = origin.map {
                    $0.line === src && $0.kind == mark.kind && $0.column == mark.column
                } ?? false
                if let idx = semanticMarks.firstIndex(where: { $0.kind == mark.kind }) {
                    // A same-kind mark outside the copied destination range did
                    // not move. The live origin always wins the collision: if
                    // the origin is the mark that moved here, it displaces the
                    // stationary one; otherwise the stationary mark is kept
                    // (it is the origin, or — absent origin info — the
                    // conservative choice) and the moved duplicate is dropped.
                    let stationaryIsOrigin = origin.map {
                        $0.line === self && $0.kind == mark.kind && $0.column == semanticMarks[idx].column
                    } ?? false
                    if movedIsOrigin && !stationaryIsOrigin {
                        semanticMarks.remove(at: idx)
                        semanticMarks.append(SemanticMark(kind: mark.kind, column: newColumn,
                                                          group: mark.group))
                        originMovedHere = true
                    }
                } else {
                    semanticMarks.append(SemanticMark(kind: mark.kind, column: newColumn,
                                                      group: mark.group))
                    if movedIsOrigin {
                        originMovedHere = true
                    }
                }
            }
            semanticMarks.sort { $0.column < $1.column }
            if originMovedHere, src !== self {
                // The origin's cells now live on this line; follow them so
                // the getter binds to this object instead of relying on the
                // rebind heuristic.
                owningBuffer?.reassignSemanticOrigin(to: self)
            }
        }
        // A full-width copy moves the continuation epoch with the content; a
        // narrow-margin copy leaves it (R1: dead clicks over injection).
        if movesSemanticHardContinuation {
            semanticHardContinuationGroup = movedSemanticHardContinuationGroup
            if src !== self {
                src.semanticHardContinuationGroup = nil
            }
        }
        bump()
    }

    /// Returns the contents of the line as a string in the specified range
    /// - Parameter trimRight: if `true`, then this will trim any empty space from the right side
    /// of the terminal, otherwise, blanks will be included
    /// - Parameter startCol: the starting column to copy the data from, defaults toe zero if not provided
    /// - Parameter endCol: the end column (not included) to consume.  If the value -1, this copies all the way to the end
    /// - Returns: a string containing the contents of the BufferLine from [startCol..<endCol]
    public func translateToString (trimRight: Bool = false, startCol: Int = 0, endCol: Int = -1, skipNullCellsFollowingWide: Bool = false, characterProvider: ((CharData) -> Character)? = nil, textProvider: ((CharData) -> String)? = nil) -> String
    {
        var ec = endCol == -1 ? storage.count : endCol
        if trimRight {
            ec = max (startCol, min (ec, getTrimmedLength()))
        }
        let limit = max(ec, startCol)
        if !skipNullCellsFollowingWide {
            var result = ""
            for i in startCol..<limit {
                let text = textProvider.map { $0(storage.cell(at: i)) }
                    ?? characterProvider.map { String($0(storage.cell(at: i))) }
                    ?? storage.text(at: i)
                result.append(contentsOf: text)
            }
            return result
        }
        var result = ""
        var idx = startCol
        while idx < limit {
            let code = storage.logicalCode(at: idx)
            let width = storage.width(at: idx)
            if idx > 0 && code == 0 && storage.width(at: idx - 1) == 2 {
                idx += 1
                continue
            }
            let text = textProvider.map { $0(storage.cell(at: idx)) }
                ?? characterProvider.map { String($0(storage.cell(at: idx))) }
                ?? storage.text(at: idx)
            result.append(contentsOf: text)
            if width == 2 {
                let nextIndex = idx + 1
                if nextIndex < limit && storage.logicalCode(at: nextIndex) == 0 {
                    idx += 2
                    continue
                }
            }
            idx += 1
        }
        return result
    }

    /// Attaches the specified terminal image to this buffer line.
    /// This method is internal - use Buffer.attachImage() to attach images with proper tracking.
    func attach (image: TerminalImage) {
        if var imageArray = self.images {
            imageArray.append (image)
            images = imageArray
        } else {
            images = [image]
        }
    }

    public var debugDescription: String {
        get {
            translateToString()
        }
    }
}
