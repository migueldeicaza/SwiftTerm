//
//  SelectionService.swift
//  iOS
//
//  Created by Miguel de Icaza on 3/5/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

#if !SWIFTTERM_EMBEDDED
import Foundation
#endif

/**
 * Tracks the selection state in the terminal, the selection is determined by the `active`
 * property, and if that is true, then the `start` and `end` represents offsets within
 * the terminal's buffer.  They are guaranteed to be ordered.
 *
 * All state is guarded by `terminal.terminalLock`; callers must hold it.
 */
public class SelectionService: CustomDebugStringConvertible {
    var terminal: Terminal

    struct SelectedContentSnapshot {
        struct Row {
            let line: BufferLine
            let contentGeneration: UInt64
            let columns: Range<Int>
            /// Keep cells for screen rows and partial history rows. A change
            /// outside a partial selection must not clear that selection.
            let cells: [PackedCell]?
            let isWrapped: Bool
            let bidiState: BidiPresentationState
        }

        let buffer: Buffer
        let rows: [Row]
    }
    
    /// Use exclusive column endpoints for portable selection clients.
    var exclusiveEnd: Bool

    public init (terminal: Terminal, exclusiveEnd: Bool = false)
    {
        self.terminal = terminal
        self.exclusiveEnd = exclusiveEnd
        _active = false
        start = Position(col: 0, row: 0)
        end = Position(col: 0, row: 0)
        pivot = Position(col: 0, row: 0)
        hasSelectionRange = false
        terminal.register (selection: self)
    }

    /// Removes this service from the terminal's registry.
    ///
    /// This is what makes the registry's `unowned(unsafe)` slots safe: the entry
    /// is gone before the object is. `terminal` is held strongly, so it is
    /// guaranteed to still be alive here.
    deinit {
        terminal.unregister (selection: self)
    }

    /**
     * Translates the selection when the terminal shifts lines in place, which
     * happens when an application scrolls a region set with DECSTBM that does
     * not start at the top of the screen.  Those scrolls do not push lines into
     * the scrollback, so `yDisp` does not move and the absolute rows the
     * selection is anchored to end up holding different text.
     *
     * Rows outside the scrolled region keep their position.  A selection is
     * dropped if it scrolls out of the region or crosses a region boundary.
     * In those cases, the original text is gone or is no longer contiguous.
     */
    func adjustForInPlaceScroll (top: Int, bottom: Int, lines: Int)
    {
        guard active, lines != 0 else {
            return
        }

        let (first, last) = Position.compare (start, end) == .before ? (start, end) : (end, start)
        let intersectsRegion = first.row <= bottom && last.row >= top
        guard intersectsRegion else {
            return
        }
        guard first.row >= top && last.row <= bottom else {
            selectNone ()
            return
        }

        func translate (_ position: Position) -> Position? {
            guard position.row >= top && position.row <= bottom else {
                return position
            }
            let newRow = position.row - lines
            guard newRow >= top && newRow <= bottom else {
                return nil
            }
            return Position (col: position.col, row: newRow)
        }

        guard let newStart = translate (start), let newEnd = translate (end) else {
            selectNone ()
            return
        }

        let newPivot: Position?
        if let pivot, exclusiveEnd || pivot == start || pivot == end {
            guard let translatedPivot = translate (pivot) else {
                selectNone ()
                return
            }
            newPivot = translatedPivot
        } else {
            newPivot = pivot
        }

        let newWordSelectionAnchor: (start: Position, end: Position)?
        if let wordSelectionAnchor {
            guard let translatedStart = translate (wordSelectionAnchor.start),
                  let translatedEnd = translate (wordSelectionAnchor.end) else {
                selectNone ()
                return
            }
            newWordSelectionAnchor = (translatedStart, translatedEnd)
        } else {
            newWordSelectionAnchor = nil
        }

        let newRowSelectionAnchor: Int?
        if let rowSelectionAnchor {
            guard let translatedAnchor = translate(
                Position(col: 0, row: rowSelectionAnchor)
            ) else {
                selectNone ()
                return
            }
            newRowSelectionAnchor = translatedAnchor.row
        } else {
            newRowSelectionAnchor = nil
        }

        start = newStart
        end = newEnd
        pivot = newPivot
        wordSelectionAnchor = newWordSelectionAnchor
        rowSelectionAnchor = newRowSelectionAnchor
        terminal.tdel?.selectionChanged (source: terminal)
    }

    /**
     * Clears the selection if it overlaps a region whose contents were shifted
     * only within a range of columns, which happens when margin mode narrows
     * the scrolled area (DECSLRM).  A selection cannot be represented as
     * partially shifted, so the honest answer is to drop it.
     */
    func invalidateForColumnRestrictedScroll (top: Int, bottom: Int, left: Int, right: Int)
    {
        guard active else {
            return
        }

        let (first, last) = Position.compare (start, end) == .before ? (start, end) : (end, start)
        guard first.row <= bottom && last.row >= top else {
            return
        }
        // A single-row selection that sits entirely outside the margin columns
        // is unaffected; anything spanning rows crosses them by definition.
        if first.row == last.row && (last.col < left || first.col > right) {
            return
        }
        selectNone ()
    }

    /// Captures the cells that the active selection identifies.
    ///
    /// A feed can move these cells through a scroll operation. The selection
    /// service adjusts its row positions during that operation. A later
    /// comparison therefore uses the adjusted positions and does not depend on
    /// the original row numbers.
    func captureSelectedContent () -> SelectedContentSnapshot?
    {
        guard active else {
            return nil
        }
        let buffer = terminal.displayBuffer
        let firstRow = min (start.row, end.row)
        let lastRow = max (start.row, end.row)
        guard firstRow >= 0, lastRow < buffer.lines.count else {
            return nil
        }

        var rows: [SelectedContentSnapshot.Row] = []
        rows.reserveCapacity (lastRow - firstRow + 1)
        for row in firstRow...lastRow {
            let line = buffer.lines [row]
            guard let columns = selectedColumnsRange (row: row, cols: line.count) else {
                continue
            }
            rows.append (SelectedContentSnapshot.Row (
                line: line,
                contentGeneration: line.contentGeneration,
                columns: columns,
                cells: row >= buffer.yBase || columns != 0..<line.count
                    ? columns.map { line.packedCell (at: $0) } : nil,
                isWrapped: line.isWrapped,
                bidiState: line.bidiState))
        }
        return SelectedContentSnapshot (buffer: buffer, rows: rows)
    }

    /// Clears the selection when a feed changed its buffer or selected cells.
    func clearIfSelectedContentChanged (from snapshot: SelectedContentSnapshot)
    {
        guard active else {
            return
        }
        let buffer = terminal.displayBuffer
        guard buffer === snapshot.buffer, selectedContentIsUnchanged (since: snapshot.rows, in: buffer) else {
            selectNone ()
            return
        }
    }

    /// Whether the selected rows hold what they held at the snapshot. A row
    /// whose line and content generation are the same is unchanged; any
    /// other compares its cells, kept for screen rows and partial history rows.
    private func selectedContentIsUnchanged (since rows: [SelectedContentSnapshot.Row], in buffer: Buffer) -> Bool
    {
        let firstRow = min (start.row, end.row)
        let lastRow = max (start.row, end.row)
        guard firstRow >= 0, lastRow < buffer.lines.count else {
            return false
        }

        var index = 0
        for row in firstRow...lastRow {
            let line = buffer.lines [row]
            guard let columns = selectedColumnsRange (row: row, cols: line.count) else {
                continue
            }
            guard index < rows.count, rows [index].columns == columns else {
                return false
            }
            let before = rows [index]
            index += 1
            if line === before.line && line.contentGeneration == before.contentGeneration {
                continue
            }
            guard let cells = before.cells, line.isWrapped == before.isWrapped,
                  line.bidiState == before.bidiState,
                  zip (columns, cells).allSatisfy ({ line.packedCell (at: $0) == $1 }) else {
                return false
            }
        }
        return index == rows.count
    }

    func selectedColumnsRange (row: Int, cols: Int) -> Range<Int>?
    {
        SelectionService.selectedColumns (row: row, cols: cols, start: start, end: end,
                                          block: isBlock, exclusiveEnd: exclusiveEnd)
    }

    /// The columns a selection covers on one row, or nil when it covers none.
    /// Both renderers and the portable spans get their columns here.
    ///
    /// A stream runs from `start` to `end` in reading order. A block covers
    /// the same columns, between the two points, on every row between them.
    /// Unless `exclusiveEnd` is set, an end in the last column includes that
    /// column, since the pointer can't go past it.
    static func selectedColumns (row: Int, cols: Int, start: Position, end: Position,
                                 block: Bool, exclusiveEnd: Bool) -> Range<Int>?
    {
        let firstRow = min (start.row, end.row)
        let lastRow = max (start.row, end.row)
        guard row >= firstRow, row <= lastRow else {
            return nil
        }

        let lowerColumn: Int
        let upperColumn: Int
        if block {
            guard start.col != end.col else {
                return nil
            }
            let right = max (start.col, end.col)
            lowerColumn = min (start.col, end.col)
            upperColumn = right + (!exclusiveEnd && right == cols - 1 ? 1 : 0)
        } else if start.row == end.row, row == start.row {
            if start.col < end.col {
                lowerColumn = start.col
                upperColumn = end.col + (!exclusiveEnd && end.col == cols - 1 ? 1 : 0)
            } else if start.col > end.col {
                lowerColumn = end.col
                upperColumn = start.col
            } else {
                return nil
            }
        } else if start.row < end.row {
            if row == start.row {
                lowerColumn = start.col
                upperColumn = cols
            } else if row == end.row {
                lowerColumn = 0
                upperColumn = end.col + (!exclusiveEnd && end.col == cols - 1 ? 1 : 0)
            } else {
                lowerColumn = 0
                upperColumn = cols
            }
        } else if end.row < start.row {
            if row == end.row {
                lowerColumn = end.col
                upperColumn = cols
            } else if row == start.row {
                lowerColumn = 0
                upperColumn = start.col + (!exclusiveEnd && start.col == cols - 1 ? 1 : 0)
            } else {
                lowerColumn = 0
                upperColumn = cols
            }
        } else {
            return nil
        }

        let lowerBound = max (0, min (lowerColumn, cols))
        let upperBound = max (lowerBound, min (upperColumn, cols))
        guard lowerBound < upperBound else {
            return nil
        }
        return lowerBound..<upperBound
    }
    
    /**
     * Controls whether the selection is active or not.   Changing the value will invoke the `selectionChanged`
     * method on the terminal's delegate if the state changes.
     */
    /// Backing store for ``active``.
    ///
    /// The observer keeps `Terminal`'s active-selection count in step. That
    /// count is what lets the scroll path skip the selection registry entirely
    /// while nothing is selected, which is the common case and used to cost a
    /// weak load per scrolled line. Property observers do not run for the
    /// assignment in `init`, which is correct here: the terminal's count starts
    /// at zero and so does this flag.
    var _active: Bool = false {
        didSet {
            guard _active != oldValue else { return }
            terminal.selectionActiveDidChange (nowActive: _active)
        }
    }
    public var active: Bool {
        get {
            return _active
        }
        set(newValue) {
            if _active != newValue {
                _active = newValue
                terminal.tdel?.selectionChanged (source: terminal)
            }
            if active == false {
                pivot = nil
            }
        }
    }
    
    // This avoids the user visible cache
    func setActiveAndNotify () {
        _active = true
        terminal.tdel?.selectionChanged (source: terminal)
    }

    /**
     * Whether any range is selected
     */
    public private(set) var hasSelectionRange: Bool

    /**
     * Returns the selection starting point in buffer coordinates
     */
    public private(set) var start: Position {
        didSet {
          hasSelectionRange = start != end
        }
    }

    /**
     * Used to track the pivot point when selection in iOS-style selection
     */
    public var pivot: Position?

    /**
     * When `selectWordOrExpression` seeds a selection (a double-click), the
     * selected range is recorded here so that a subsequent word-mode drag can
     * pivot around the whole seed word.  Without this, dragging *backwards*
     * past the seed word would leave `start` pinned at the seed word's start
     * and the seed word would be dropped from the selection.
     */
    var wordSelectionAnchor: (start: Position, end: Position)?

    /// The row that started a row selection. It stays fixed while the pointer
    /// moves across that row.
    var rowSelectionAnchor: Int?

    /**
     * Returns the selection ending point in buffer coordinates
     */
    public private(set) var end: Position {
        didSet {
          hasSelectionRange = start != end
        }
    }
    
    /// True if the selection spans more than one line
    public var isMultiLine: Bool {
        return start.row != end.row
    }

    /// Whether the selection is a block: the columns between `start` and
    /// `end`, on every row between them. Otherwise it runs from `start` to
    /// `end` in reading order. ``startBlockSelection(bufferPosition:)`` makes
    /// a block; every other way of starting a selection makes a stream.
    public private(set) var isBlock: Bool = false

    /**
     * Starts the selection from the specific screen-relative location
     */
    public func startSelection (row: Int, col: Int)
    {
        setSoftStart(row: row, col: col)
        selectingRows = false
        selectionMode = .character
        wordSelectionAnchor = nil
        rowSelectionAnchor = nil
        isBlock = false
        setActiveAndNotify()
    }

    /// Starts a block selection at a buffer position. A drag from here
    /// selects the columns between this point and the pointer, on every row
    /// between them, as an Option-drag does in Terminal.app.
    public func startBlockSelection (bufferPosition: Position)
    {
        let point = clamp (terminal.displayBuffer, bufferPosition)
        start = point
        end = point
        pivot = nil
        selectingRows = false
        selectionMode = .character
        wordSelectionAnchor = nil
        rowSelectionAnchor = nil
        isBlock = true
        setActiveAndNotify()
    }
        
    func clamp (_ buffer: Buffer, _ p: Position) -> Position {
        let maxRow = max(0, buffer.lines.count - 1)
        return Position(col: max(0, min(p.col, exclusiveEnd ? buffer.cols : buffer.cols - 1)),
                        row: max(0, min(p.row, maxRow)))
    }
    /**
     * Sets the selection, this is validated against the
     */
    public func setSelection (start: Position, end: Position) {
        let buffer = terminal.displayBuffer
        let sclamped = clamp (buffer, start)
        let eclamped = clamp (buffer, end)
        
        self.start = sclamped
        self.end = eclamped
        pivot = nil
        selectingRows = false
        selectionMode = .character
        wordSelectionAnchor = nil
        rowSelectionAnchor = nil
        isBlock = false

        setActiveAndNotify()
    }

    /**
     * Starts selection, the range is determined by the last start position
     */
    public func startSelection ()
    {
        end = start
        selectingRows = false
        selectionMode = .character
        wordSelectionAnchor = nil
        rowSelectionAnchor = nil
        isBlock = false
        setActiveAndNotify()
    }
    
    /**
     * Sets the start and end positions but does not start selection
     * this lets us record the last position of mouse clicks so that
     * drag and shift+click operations know from where to start selection
     * from.
     *
     * The location is screen-relative
     */
    public func setSoftStart (row: Int, col: Int) {
        setSoftStart (bufferPosition: Position(col: col, row: row + terminal.displayBuffer.yDisp))
    }
    
    /**
     * Sets the start and end positions but does not start selection
     * this lets us record the last position of mouse clicks so that
     * drag and shift+click operations know from where to start selection
     * from.
     *
     * The locoation is buffer-relative
     */
    public func setSoftStart (bufferPosition: Position) {
        start = bufferPosition
        end = bufferPosition
        setActiveAndNotify()
    }
    
    /**
     * Extends the selection based on the user "shift" clicking. This has
     * slightly different semantics than a "drag" extension because we can
     * shift the start to be the last prior end point if the new extension
     * is before the current start point.
     *
     * The row is screen-relative
     */
    public func shiftExtend (row: Int, col: Int)
    {
        shiftExtend(bufferPosition: Position(
            col: col,
            row: row + terminal.displayBuffer.yDisp
        ))
    }
    
    /**
     * Extends the selection based on the user "shift" clicking. This has
     * slightly different semantics than a "drag" extension because we can
     * shift the start to be the last prior end point if the new extension
     * is before the current start point.
     *
     * The bufferPosition is buffer-relative
     */
    public func shiftExtend (bufferPosition newEnd: Position) {
        if isBlock {
            // The block keeps the corner farthest from the click, so the
            // edges nearest the click move to it and the block stays a block.
            let point = clamp (terminal.displayBuffer, newEnd)
            let top = min (start.row, end.row), bottom = max (start.row, end.row)
            let left = min (start.col, end.col), right = max (start.col, end.col)
            start = Position (col: abs (point.col - left) >= abs (point.col - right) ? left : right,
                              row: abs (point.row - top) >= abs (point.row - bottom) ? top : bottom)
            end = point
            setActiveAndNotify()
            return
        }
        if selectionMode == .row {
            extendRowSelection(through: newEnd.row)
            setActiveAndNotify()
            return
        }

        var adjustedNewEnd = newEnd
        
        // If we're in word selection mode, extend to word boundaries
        if selectionMode == .word {
            let direction = Position.compare(newEnd, start) == .before ? -1 : 1
            adjustedNewEnd = extendToWordBoundary(position: newEnd, in: terminal.displayBuffer, direction: direction)
        }
        
        var shouldSwapStart = false
        if Position.compare (start, end) == .before {
            // start is before end, is the new end before Start
            if Position.compare (adjustedNewEnd, start) == .before {
                // yes, swap Start and End
                shouldSwapStart = true
            }
        } else if Position.compare (start, end) == .after {
            if Position.compare (adjustedNewEnd, start) == .after {
                // yes, swap Start and End
                shouldSwapStart = true
            }
        }
        if (shouldSwapStart) {
            start = end
        }
        end = adjustedNewEnd
        
        setActiveAndNotify()
    }
    
    /**
     * Implements the iOS selection around the pivot, that is, the handle that is being dragged
     * becomes the pivot point for start/end
     *
     * The row is screen-relative, for buffer relative use the `pivotExtend(bufferPosition:)` overload
     */
    public func pivotExtend (row: Int, col: Int) {
        let newPoint = Position  (col: col, row: row + terminal.displayBuffer.yDisp)

        return pivotExtend(bufferPosition: newPoint)
    }
    
    /**
     * Implements the iOS selection around the pivot, that is, the handle that is being dragged
     * becomes the pivot point for start/end
     *
     * The position is buffer-relative, for screen relative, use `pivotExtend(row:col:)`
     */
    public func pivotExtend (bufferPosition: Position) {
        guard let pivot = pivot else {
            return
        }

        if selectionMode == .row {
            setRowSelection(from: pivot.row, through: bufferPosition.row)
            setActiveAndNotify()
            return
        }
        
        var adjustedPosition = bufferPosition
        
        // If we're in word selection mode, extend to word boundaries
        if selectionMode == .word {
            let direction = Position.compare(bufferPosition, pivot) == .before ? -1 : 1
            adjustedPosition = extendToWordBoundary(position: bufferPosition, in: terminal.displayBuffer, direction: direction)
        }
        
        switch Position.compare (adjustedPosition, pivot) {
        case .after:
            start = pivot
            end = adjustedPosition
        case .before:
            start = adjustedPosition
            end = pivot
        case .equal:
            start = pivot
            end = pivot
        }
        
        setActiveAndNotify()
    }
    
    /**
     * Extends the selection by moving the end point to the new point.
     * The row is in screen coordinates
     */
    public func dragExtend (row: Int, col: Int)
    {
        dragExtend(bufferPosition: Position(col: col, row: row + terminal.displayBuffer.yDisp))
    }
    
    /**
     * Extends the selection by moving the end point to the new point.
     * The position is in buffer coordinates
     */
    public func dragExtend (bufferPosition: Position) {
        if isBlock {
            end = clamp (terminal.displayBuffer, bufferPosition)
            setActiveAndNotify()
            return
        }
        if selectionMode == .row {
            extendRowSelection(through: bufferPosition.row)
            setActiveAndNotify()
            return
        }

        // When the selection was seeded by a double-click (word mode), pivot the
        // drag around the whole seed word.  This keeps the seed word in the
        // selection when the drag goes *backwards* (to the left/up) past it, and
        // snaps both ends to word boundaries in either direction.
        if selectionMode == .word, let anchor = wordSelectionAnchor {
            let buffer = terminal.displayBuffer
            if Position.compare(bufferPosition, anchor.start) == .before {
                start = extendToWordBoundary(position: bufferPosition, in: buffer, direction: -1)
                end = anchor.end
            } else if Position.compare(bufferPosition, anchor.end) == .after {
                start = anchor.start
                end = extendToWordBoundary(position: bufferPosition, in: buffer, direction: 1)
            } else {
                // Still inside the seed word: keep the whole word selected.
                start = anchor.start
                end = anchor.end
            }
            setActiveAndNotify()
            return
        }

        var adjustedEnd = bufferPosition

        // If we're in word selection mode, extend to word boundaries
        if selectionMode == .word {
            let direction = Position.compare(bufferPosition, start) == .before ? -1 : 1
            adjustedEnd = extendToWordBoundary(position: bufferPosition, in: terminal.displayBuffer, direction: direction)
        }

        end = adjustedEnd
        setActiveAndNotify()
    }
    
    /**
     * Selects the entire buffer and triggers the selection
     */
    public func selectAll ()
    {
        selectionMode = .character
        selectingRows = false
        wordSelectionAnchor = nil
        rowSelectionAnchor = nil
        pivot = nil
        isBlock = false
        start = Position(col: 0, row: 0)
        end = Position(col: exclusiveEnd ? terminal.cols : terminal.cols - 1,
                       row: terminal.displayBuffer.lines.count - 1)
        setActiveAndNotify()
    }
    
    public var selectingRows: Bool = false
    
    /// Tracks the current selection mode to maintain consistency during extension
    public enum SelectionMode {
        case character
        case word
        case row
    }
    
    public var selectionMode: SelectionMode = .character
    
    /// Selects the logical line through a buffer row: that row and the rows
    /// soft-wrapped onto it, as a triple-click does. A drag from here selects
    /// whole logical lines.
    public func select(row: Int)
    {
        selectingRows = true
        selectionMode = .row
        wordSelectionAnchor = nil
        rowSelectionAnchor = row
        isBlock = false
        setRowSelection(from: row, through: row)
        setActiveAndNotify()
    }

    private func extendRowSelection(through row: Int) {
        setRowSelection(from: rowSelectionAnchor ?? start.row, through: row)
    }

    private func setRowSelection(from anchorRow: Int, through targetRow: Int) {
        let first = logicalLineRows(through: min(anchorRow, targetRow)).lowerBound
        let last = logicalLineRows(through: max(anchorRow, targetRow)).upperBound
        start = Position(col: 0, row: first)
        end = Position(col: exclusiveEnd ? terminal.cols : terminal.cols - 1, row: last)
    }

    /// The rows of the logical line through a buffer row: the row and the
    /// rows soft-wrapped onto it.
    func logicalLineRows(through row: Int) -> ClosedRange<Int> {
        let lines = terminal.displayBuffer.lines
        guard row >= 0, row < lines.count else {
            return row...row
        }
        var first = row
        while first > 0, lines [first].isWrapped {
            first -= 1
        }
        var last = row
        while last + 1 < lines.count, lines [last + 1].isWrapped {
            last += 1
        }
        return first...last
    }

    private func character (at position: Position, in buffer: Buffer) -> Character
    {
        let cell = buffer.getChar (atBufferRelative: position)
        return terminal.getCharacter (for: cell)
    }

    /**
     * Performs a simple "word" selection based on a function that determines inclussion into the group
     */
    func simpleScanSelection (from position: Position, in buffer: Buffer, includeFunc: (Character)-> Bool)
    {
        // Look backward
        var colScan = position.col
        var left = colScan
        while colScan >= 0 {
            let ch = character (at: Position (col: colScan, row: position.row), in: buffer)
            if !includeFunc (ch) {
                break
            }
            left = colScan
            colScan -= 1
        }
        
        // Look forward
        colScan = position.col
        var right = colScan
        let limit = terminal.cols
        while colScan < limit {
            let ch = character (at: Position (col: colScan, row: position.row), in: buffer)
            if !includeFunc (ch) {
                break
            }
            colScan += 1
            right = colScan
        }
        start = Position (col: left, row: position.row)
        end = Position(col: right, row: position.row)
    }
    
    /**
     * Performs a forward search for the `end` character, but this can extend across matching subexpressions
     * made of pais of parenthesis, braces and brackets.
     */
    func balancedSearchForward (from position: Position, in buffer: Buffer)
    {
        var startCol = position.col
        var wait: [Character] = []
        
        start = position
        
        let maxRow = buffer.rows + buffer.yDisp
        if position.row >= maxRow {
            return
        }
        for line in position.row..<maxRow {
            for col in startCol..<terminal.cols {
                let p =  Position(col: col, row: line)
                let ch = character (at: p, in: buffer)
                
                if ch == "(" {
                    wait.append (")")
                } else if ch == "[" {
                    wait.append ("]")
                } else if ch == "{" {
                    wait.append ("}")
                } else if let v = wait.last {
                    if v == ch {
                        wait.removeLast()
                        if wait.count == 0 {
                            end = Position(col: p.col+1, row: p.row)
                            return
                        }
                    }
                }
            }
            startCol = 0
        }
        start = position
        end = position
    }

    /**
     * Performs a forward search for the `end` character, but this can extend across matching subexpressions
     * made of pais of parenthesis, braces and brackets.
     */
    func balancedSearchBackward (from position: Position, in buffer: Buffer)
    {
        var startCol = position.col
        var wait: [Character] = []

        end = position
        
        for line in (0...position.row).reversed() {
            for col in (0...startCol).reversed() {
                let p =  Position(col: col, row: line)
                let ch = character (at: p, in: buffer)
                
                if ch == ")" {
                    wait.append ("(")
                } else if ch == "]" {
                    wait.append ("[")
                } else if ch == "}" {
                    wait.append ("{")
                } else if let v = wait.last {
                    if v == ch {
                        wait.removeLast()
                        if wait.count == 0 {
                            end = Position(col: end.col+1, row: end.row)
                            start = p
                            return
                        }
                    }
                }
            }
            startCol = terminal.cols-1
        }
        start = position
        end = position
    }

    let nullChar = Character(UnicodeScalar(0))
    
    /**
     * Extends a position to the nearest word boundary based on the character at that position
     */
    func extendToWordBoundary(position: Position, in buffer: Buffer, direction: Int) -> Position {
        let ch = character (at: position, in: buffer)
        var includeFunc: (Character) -> Bool
        
        switch ch {
        case Character(UnicodeScalar(0)):
            includeFunc = { ch in ch == Character(UnicodeScalar(0)) }
        case " ":
            includeFunc = { ch in ch == " " }
        case let ch where ch.isLetter || ch.isNumber:
            includeFunc = { ch in ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-" }
        default:
            return position
        }
        
        var result = position
        if direction < 0 {
            // Extend backward
            var col = position.col
            while col >= 0 {
                let testCh = character (at: Position(col: col, row: position.row), in: buffer)
                if !includeFunc(testCh) {
                    break
                }
                result.col = col
                col -= 1
            }
        } else {
            // Extend forward
            var col = position.col
            while col < terminal.cols {
                let testCh = character (at: Position(col: col, row: position.row), in: buffer)
                if !includeFunc(testCh) {
                    break
                }
                col += 1
                result.col = col
            }
        }
        
        return result
    }
    /**
     * Selects what a double-click at the position means, on its logical line
     * (the row and the rows soft-wrapped onto it):
     *
     * - a URL (`scheme://…` or `www.…`), without trailing punctuation such as
     *   `.,;:)` unless a bracket inside it balances it;
     * - a file path: absolute, `~/`, `./`, `../`, or any word of path
     *   characters with a `/` in it, with a `:line` or `:line:col` after it;
     * - on a quote (`"`, `'` or `` ` ``), the quoted string through its
     *   matching quote, quotes included;
     * - on `(`, `[` or `{` and their closers, the balanced expression;
     * - otherwise the word, the run of spaces, or the one character.
     */
    public func selectWordOrExpression (at uncheckedPosition: Position, in buffer: Buffer)
    {
//        let position = Position(
//            col: max (min (uncheckedPosition.col, buffer.cols-1), 0),
//            row: max (min (uncheckedPosition.row, buffer.rows-1+buffer.yDisp), buffer.yDisp))
        let position = Position (col: min(terminal.cols - 1, max(uncheckedPosition.col, 0)),
                                 row: min(buffer.lines.count - 1, max(uncheckedPosition.row, 0)))
        isBlock = false
        if let range = smartWordRange (at: position, in: buffer) {
            start = range.start
            end = range.end
        } else {
            selectPlainWordOrExpression (at: position, in: buffer)
        }
        selectionMode = .word
        wordSelectionAnchor = (start, end)
        rowSelectionAnchor = nil
        selectingRows = false
        setActiveAndNotify()
    }

    /// The word rules from before URLs, paths and quotes: a word, a run of
    /// spaces, or a balanced expression.
    private func selectPlainWordOrExpression (at position: Position, in buffer: Buffer)
    {
        switch character (at: position, in: buffer) {
        case Character(UnicodeScalar(0)):
            simpleScanSelection (from: position, in: buffer) { ch in ch == nullChar }
        case " ":
            // Select all white space
            simpleScanSelection (from: position, in: buffer) { ch in ch == " " }
        case let ch where ch.isLetter || ch.isNumber:
            simpleScanSelection (from: position, in: buffer) { ch in ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-" }
        case "{":
            fallthrough
        case "(":
            fallthrough
        case "[":
            balancedSearchForward (from: position, in: buffer)
        case ")":
            fallthrough
        case "]":
            fallthrough
        case "}":
            balancedSearchBackward(from: position, in: buffer)
        default:
            // For other characters, we just stop there
            start = position
            end = position
        }
    }

    /// Returns the word at a buffer-relative position without changing the
    /// current selection. The word rules match word selection.
    func word(at uncheckedPosition: Position, in buffer: Buffer) -> (text: String, start: Position)? {
        guard uncheckedPosition.col >= 0, uncheckedPosition.col < terminal.cols,
              uncheckedPosition.row >= 0, uncheckedPosition.row < buffer.lines.count else {
            return nil
        }

        let position = uncheckedPosition
        let includes: (Character) -> Bool = { character in
            character.isLetter || character.isNumber || character == "." ||
                character == "_" || character == "-"
        }
        guard includes(character(at: position, in: buffer)) else { return nil }

        var first = position.col
        while first > 0,
              includes(character(at: Position(col: first - 1, row: position.row), in: buffer)) {
            first -= 1
        }

        var last = position.col + 1
        while last < terminal.cols,
              includes(character(at: Position(col: last, row: position.row), in: buffer)) {
            last += 1
        }

        let word = terminal.getText(
            start: Position(col: first, row: position.row),
            end: Position(col: last, row: position.row),
            buffer: buffer)
        guard !word.isEmpty else { return nil }
        return (text: word, start: Position(col: first, row: position.row))
    }

    /**
     * Clears the selection
     */
    public func selectNone ()
    {
        if active {
            active = false
            selectionMode = .character
            wordSelectionAnchor = nil
            rowSelectionAnchor = nil
            selectingRows = false
            isBlock = false
        }
    }

    /// The selected text. A stream comes out as it reads, with soft-wrapped
    /// rows joined. A block gives each row's part, trailing spaces trimmed,
    /// joined by "\n".
    public func getSelectedText () -> String {
        if isBlock {
            return blockText ()
        }
        var (min, max) = if Position.compare(start, end) == .before {
            (start, end)
        } else {
            (end, start)
        }
        // A row selection ends in the last column and covers it, so a full
        // last row is copied whole.
        if selectionMode == .row {
            max.col = terminal.cols
        }
        let r = terminal.getDisplayText(start: min, end: max)
        return r
    }

    private func blockText () -> String {
        let buffer = terminal.displayBuffer
        let firstRow = Swift.max (0, Swift.min (start.row, end.row))
        let lastRow = Swift.min (buffer.lines.count - 1, Swift.max (start.row, end.row))
        guard firstRow <= lastRow,
              let columns = selectedColumnsRange (row: firstRow, cols: terminal.cols) else {
            return ""
        }
        var rows: [String] = []
        for row in firstRow...lastRow {
            let line = buffer.lines [row]
            var lower = columns.lowerBound
            var upper = Swift.min (columns.upperBound, line.count)
            // A wide character cut by an edge is drawn selected, so it is
            // copied whole.
            if lower > 0, lower < line.count,
               line.packedWidth (at: lower) == 0, line.packedWidth (at: lower - 1) == 2 {
                lower -= 1
            }
            if upper > 0, upper < line.count, line.packedWidth (at: upper - 1) == 2 {
                upper += 1
            }
            var text = lower < upper
                ? terminal.translateBufferLineToString (buffer: buffer, line: row, start: lower, end: upper)
                : ""
            while text.last == " " {
                text.removeLast ()
            }
            rows.append (text)
        }
        return rows.joined (separator: "\n")
    }
    
    public var debugDescription: String {
        return "[Selection (active=\(active), start=\(start) end=\(end) hasSR=\(hasSelectionRange) pivot=\(pivot?.debugDescription ?? "nil")]"
    }
}

extension SelectionService {
    /// Return the complete cell interval for a pointer hit.
    private func pointerCell(_ position: Position) -> (start: Position, end: Position) {
        let buffer = terminal.displayBuffer
        var first = position
        if first.col > 0,
           buffer.getChar(atBufferRelative: first).width == 0,
           buffer.getChar(atBufferRelative: Position(col: first.col - 1, row: first.row)).width == 2 {
            first.col -= 1
        }
        let width = max(1, Int(buffer.getChar(atBufferRelative: first).width))
        return (first, Position(col: min(terminal.cols, first.col + width), row: first.row))
    }

    func updatePointerSelection(_ position: Position, begin: Bool, mode: UInt32) {
        let cell = pointerCell(position)
        if begin && mode != 3 {
            switch mode {
            case 1:
                pivot = nil
                selectWordOrExpression(at: cell.start, in: terminal.displayBuffer)
                if start == end { start = cell.start; end = cell.end }
                normalizePointerEndpoints()
                wordSelectionAnchor = (start, end)
            case 2:
                pivot = nil
                select(row: position.row)
            default:
                startSelection(row: position.row - terminal.displayBuffer.yDisp, col: cell.start.col)
                end = cell.end
                pivot = cell.start
            }
            setActiveAndNotify()
            return
        }
        guard active else {
            if begin { updatePointerSelection(position, begin: true, mode: 0) }
            return
        }
        if selectionMode != .character {
            if begin { shiftExtend(bufferPosition: cell.start) }
            else { dragExtend(bufferPosition: cell.start) }
            // Punctuation and emoji have no forward word boundary. The
            // shared word helper returns their start; include the hit cell
            // when that position becomes the forward exclusive endpoint.
            if selectionMode == .word, end == cell.start,
               Position.compare(start, end) != .after {
                end = cell.end
            }
            // The extend helpers notified with the raw endpoints. Notify again
            // once the wide-cell normalization has settled them.
            normalizePointerEndpoints()
            setActiveAndNotify()
            return
        }
        let anchor = pointerCell(pivot ?? start)
        if Position.compare(cell.start, anchor.start) == .before {
            start = cell.start
            end = anchor.end
        } else {
            start = anchor.start
            end = cell.end
        }
        pivot = anchor.start
        setActiveAndNotify()
    }

    private func normalizePointerEndpoints() {
        let buffer = terminal.displayBuffer
        if start.col < terminal.cols { start = pointerCell(start).start }
        // An exclusive end inside a wide cell must include that whole cell.
        if end.col > 0 && end.col < terminal.cols,
           buffer.getChar(atBufferRelative: end).width == 0,
           buffer.getChar(atBufferRelative: Position(col: end.col - 1, row: end.row)).width == 2 {
            end.col += 1
        }
    }
}

// MARK: Smart double-click

extension SelectionService {
    /// How many rows above and below the clicked row a double-click reads
    /// along a soft-wrapped line. A URL or path longer than this is cut.
    static let smartSelectionRowLimit = 100

    /// One character of a logical line and where it sits.
    private struct LineCell {
        let character: Character
        let row: Int
        let col: Int
        let width: Int
    }

    /// The URL, path or quoted string a double-click at `position` selects,
    /// as a stream from `start` to an exclusive `end`. Nil when the click
    /// is on none of them.
    func smartWordRange (at position: Position, in buffer: Buffer) -> (start: Position, end: Position)?
    {
        let cells = logicalLineCells (through: position, in: buffer)
        guard let index = cells.firstIndex (where: {
            $0.row == position.row && $0.col <= position.col && position.col < $0.col + $0.width
        }) else {
            return nil
        }
        let characters = cells.map { $0.character }
        guard let range = SelectionService.urlRange (in: characters, containing: index)
                ?? SelectionService.pathRange (in: characters, containing: index)
                ?? SelectionService.quotedRange (in: characters, at: index) else {
            return nil
        }
        let first = cells [range.lowerBound]
        let last = cells [range.upperBound - 1]
        return (Position (col: first.col, row: first.row),
                Position (col: last.col + last.width, row: last.row))
    }

    /// The characters of the logical line through `position`, in order. A
    /// wide character's second cell is left out, and so is an empty last
    /// cell that a wide character skipped when it wrapped.
    private func logicalLineCells (through position: Position, in buffer: Buffer) -> [LineCell]
    {
        let lines = buffer.lines
        let limit = SelectionService.smartSelectionRowLimit
        var first = position.row
        while first > 0, position.row - first < limit, lines [first].isWrapped {
            first -= 1
        }
        var last = position.row
        while last + 1 < lines.count, last - position.row < limit, lines [last + 1].isWrapped {
            last += 1
        }
        let cols = terminal.cols
        var cells: [LineCell] = []
        cells.reserveCapacity ((last - first + 1) * cols)
        for row in first...last {
            let line = lines [row]
            let count = min (cols, line.count)
            let continues = row < last
            for col in 0..<count {
                let cell = line [col]
                let width = Int (cell.width)
                if width == 0 {
                    continue
                }
                let character = terminal.getCharacter (for: cell)
                if continues, col == count - 1, character == nullChar {
                    continue
                }
                cells.append (LineCell (character: character, row: row, col: col, width: width))
            }
        }
        return cells
    }

    // MARK: URLs

    private static func isURLCharacter (_ c: Character) -> Bool {
        if c.isASCII {
            guard let ascii = c.asciiValue, ascii > 0x20, ascii < 0x7f else {
                return false
            }
            return !"<>\"'`{}|\\^".contains (c)
        }
        // International domain names and paths.
        return c.isLetter || c.isNumber
    }

    private static func isSchemeCharacter (_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "+" || c == "." || c == "-")
    }

    /// The URL around `index`: a `scheme://` or `www.` start, then URL
    /// characters, less trailing punctuation that no bracket in it balances.
    static func urlRange (in chars: [Character], containing index: Int) -> Range<Int>?
    {
        guard isURLCharacter (chars [index]) else {
            return nil
        }
        var lo = index
        while lo > 0, isURLCharacter (chars [lo - 1]) {
            lo -= 1
        }
        var hi = index + 1
        while hi < chars.count, isURLCharacter (chars [hi]) {
            hi += 1
        }

        // Where URLs start in this run, and where their bodies begin.
        var starts: [(start: Int, body: Int)] = []
        var k = lo
        while k < hi {
            if chars [k] == ":", k + 2 < hi, chars [k + 1] == "/", chars [k + 2] == "/" {
                var s = k
                while s > lo, isSchemeCharacter (chars [s - 1]) {
                    s -= 1
                }
                // A scheme starts with a letter.
                while s < k, !chars [s].isLetter {
                    s += 1
                }
                if s < k {
                    starts.append ((s, k + 3))
                }
                k += 3
                continue
            }
            if k + 4 <= hi, chars [k] == "w" || chars [k] == "W",
               chars [k + 1] == chars [k], chars [k + 2] == chars [k], chars [k + 3] == ".",
               k == lo || !(isSchemeCharacter (chars [k - 1]) || chars [k - 1] == "/" || chars [k - 1] == "@") {
                starts.append ((k, k + 4))
                k += 4
                continue
            }
            k += 1
        }

        // Another scheme or www. can be part of the URL's path or query.
        // Keep the complete run when it contains the clicked character.
        for url in starts {
            let end = trimURLEnd (chars, from: url.start, to: hi)
            guard end > url.body else {
                continue
            }
            if url.start <= index && index < end {
                return url.start..<end
            }
        }
        return nil
    }

    /// Drops sentence punctuation from a URL's end, and a closing bracket
    /// that has no opening one inside the URL.
    private static func trimURLEnd (_ chars: [Character], from start: Int, to end: Int) -> Int
    {
        var end = end
        while end > start {
            let last = chars [end - 1]
            if ".,;:!?".contains (last) {
                end -= 1
                continue
            }
            if last == ")" || last == "]" {
                let open: Character = last == ")" ? "(" : "["
                let body = chars [start..<end]
                if body.filter ({ $0 == last }).count > body.filter ({ $0 == open }).count {
                    end -= 1
                    continue
                }
            }
            break
        }
        return end
    }

    // MARK: Paths

    private static func isPathCharacter (_ c: Character) -> Bool {
        c.isLetter || c.isNumber || "/._-~+@".contains (c)
    }

    /// The path around `index`: a run of path characters with a `/` in it
    /// and something besides slashes, then up to two `:number` parts.
    static func pathRange (in chars: [Character], containing index: Int) -> Range<Int>?
    {
        let isTokenCharacter = { (c: Character) in isPathCharacter (c) || c == ":" }
        guard isTokenCharacter (chars [index]) else {
            return nil
        }
        var lo = index
        while lo > 0, isTokenCharacter (chars [lo - 1]) {
            lo -= 1
        }
        var hi = index + 1
        while hi < chars.count, isTokenCharacter (chars [hi]) {
            hi += 1
        }
        // A sentence's period is not part of the path.
        while hi - lo > 1, chars [hi - 1] == ".", chars [hi - 2].isLetter || chars [hi - 2].isNumber {
            hi -= 1
        }

        var parts: [Range<Int>] = []
        var partStart = lo
        for k in lo..<hi where chars [k] == ":" {
            parts.append (partStart..<k)
            partStart = k + 1
        }
        parts.append (partStart..<hi)

        for (n, part) in parts.enumerated () {
            let text = chars [part]
            guard text.contains ("/"), text.contains (where: { $0 != "/" }) else {
                continue
            }
            var end = part.upperBound
            var next = n + 1
            while next < parts.count, next - n <= 2, !parts [next].isEmpty,
                  chars [parts [next]].allSatisfy ({ $0.isASCII && $0.isNumber }) {
                end = parts [next].upperBound
                next += 1
            }
            if part.lowerBound <= index && index < end {
                return part.lowerBound..<end
            }
        }
        return nil
    }

    // MARK: Quotes

    private static let quoteCharacters: [Character] = ["\"", "'", "`"]

    /// Whether the quote at `index` opens or closes a string: not escaped
    /// with a backslash, and for `'`, not an apostrophe inside a word.
    private static func isDelimitingQuote (_ chars: [Character], _ index: Int, _ quote: Character) -> Bool
    {
        guard chars [index] == quote else {
            return false
        }
        var beforeBackslashes = index
        while beforeBackslashes > 0, chars [beforeBackslashes - 1] == "\\" {
            beforeBackslashes -= 1
        }
        if (index - beforeBackslashes) % 2 != 0 {
            return false
        }
        if quote == "'", index > 0, index + 1 < chars.count,
           chars [index - 1].isLetter, chars [index + 1].isLetter {
            return false
        }
        return true
    }

    /// On a quote, the string through its matching quote, quotes included.
    /// An even number of the same quotes before it makes it an opening one.
    static func quotedRange (in chars: [Character], at index: Int) -> Range<Int>?
    {
        let quote = chars [index]
        guard quoteCharacters.contains (quote), isDelimitingQuote (chars, index, quote) else {
            return nil
        }
        let before = (0..<index).filter { isDelimitingQuote (chars, $0, quote) }.count
        if before % 2 == 0 {
            for k in (index + 1)..<chars.count where isDelimitingQuote (chars, k, quote) {
                return index..<(k + 1)
            }
        } else {
            for k in stride (from: index - 1, through: 0, by: -1) where isDelimitingQuote (chars, k, quote) {
                return k..<(index + 1)
            }
        }
        return nil
    }
}
