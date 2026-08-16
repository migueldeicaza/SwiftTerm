//
//  Buffer.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/26/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation

/**
 * The buffer represents the contents shown to the user.
 *
 * The buffer object contains both the lines that are shwon the user (including the scorllback) as well
 * as attributes like the cursor (x, y) position, the defined scroll region, the tab stops, the left and right margins and the scrolling delta.
 *
 * Some of the saved state information is also tracked here.
 */
public final class Buffer {
    private var _lines: CircularBufferLineList
    var xDisp, _yDisp, xBase: Int
    private var _x, _y, _yBase: Int
    private var _linesWithImagesCount: Int = 0
    
    // this keeps incrementing even as we run out of space in _lines and trim out
    // old lines.
    var linesTop: Int

    /// Monotonic count of lines that have been trimmed off the top of the
    /// scrollback since this buffer was created or reset. Increments by one
    /// each time output pushes a line out of a full scrollback buffer
    /// (`Terminal.scroll`); resets to zero on hard reset (RIS) and buffer
    /// (re)construction. Embedders can use this to anchor a scrolled-up
    /// viewport by absolute buffer line rather than pixel offset: at the
    /// scrollback cap the content height stays constant while rows shift,
    /// so a pixel-based anchor drifts by one row per trimmed line.
    public var totalLinesTrimmed: Int { linesTop }


    /// This is the index into the `lines` array that corresponds to the top row of displayed
    /// content in the terminal when the scroll is zero.   So the terminal contents that the application
    /// has access to are `lines [yBase..(yBase+rows)]`
    var yBase: Int {
        get { _yBase }
        set {
            if newValue > _lines.count {
//                #if DEBUG
//                abort ()
//                #else
//                return
//                #endif
            }
            _yBase = newValue
        }
    }
    /// This property tracks the first row in the `lines` array that will be displayed as the top row
    /// when scrolling takes place, this variable is updated to move the window of visible content
    public var yDisp: Int {
        get { return _yDisp }
        set {
            if _yDisp < 0 {
                #if DEBUG
                abort()
                #else
                return
                #endif
            }
            _yDisp = newValue
        }
    }
    /**
     * This is the cursor column 0-based, due to the way that the terminal must behave, buffer.x sometimes can
     * be beyond the boundary of the buffer, so it is important that any writes to a line with [buffer.x] first
     * does so by clamping the value to cols-1.
     *
     */
    public var x: Int {
        get { return _x }
        set(newValue) {
            if newValue < 0 {
                #if DEBUG
                abort()
                #else
                return
                #endif
            }
            _x = newValue
        }
    }
    
    /**
     * This is the cursor row 0-based
     */
    public var y: Int {
        get { return _y }
        set(newValue) {
            if newValue < 0 {
                #if DEBUG
                abort()
                #else
                return
                #endif
            }
            _y = newValue
        }
    }
    
    private var _scrollBottom: Int
    /**
     * This sets the bottom of the scrolling region in the buffer when Origin Mode is turned on
     */
    public var scrollBottom: Int {
        get { _scrollBottom }
        set {
            if newValue < 0 {
                #if DEBUG
                abort()
                #else
                return
                #endif
            }
            _scrollBottom = newValue
        }
    }
    
    var _scrollTop: Int

    /**
     * This sets the top scrolling region in the buffer when Origin Mode is turned on
     */
    public var scrollTop: Int {
        set(newValue) {
            if newValue >= 0 {
                _scrollTop = newValue
            }
        }
        get {
            return _scrollTop
        }
    }
    var tabStops: [Bool]
    
    /**
     * This records the saved X position
     */
    public var savedX: Int
    
    /**
     * This records the saved Y position
     */
    public var savedY: Int

    /// Saved state for the origin mode
    var savedOriginMode: Bool = false
    /// Saved state for the origin mode
    var savedMarginMode: Bool = false
    /// Saved state for the wrap around mode
    var savedWraparound: Bool = false
    /// Saved state for the reverse wrap around mode
    var savedReverseWraparound: Bool = false

    /**
     * The left margin, 0-indexed, used when marginMode is turned on
     */
    public var marginLeft: Int {
        get {
            _marginLeft
        }
        set {
            _marginLeft = newValue
        }
    }
    private var _marginLeft: Int = 0

    /**
     * The right margin, 0-indexed, used when marginMode is turned on
     */
    public var marginRight: Int {
        get {
            _marginRight
        }
        set {
            _marginRight = newValue
        }
    }
    private var _marginRight: Int = 0
    
    /**
     * This represents the saved attributed
     */
    public var savedAttr = CharData.defaultAttr
    
    /**
     * This tracks the current charset
     */
    public var savedCharset: [UInt8:String]? = nil
    
    var hasScrollback : Bool
    var cols: Int {
        get { _cols }
        set { _cols = newValue }
    }
    var rows: Int {
        get { _rows }
        set { _rows = newValue }
    }
    private var _cols: Int
    private var _rows: Int
    
    var scrollback: Int?
    
    var lines : CircularBufferLineList {
        get { return _lines }
    }

    /// Returns true if any lines in this buffer have images attached
    public var hasAnyImages: Bool {
        return _linesWithImagesCount > 0
    }

    /// Attaches an image to the line at the given index, tracking the count of lines with images
    func attachImage(_ image: TerminalImage, toLineAt index: Int) {
        let line = lines[index]
        let hadImages = line.images != nil
        line.attach(image: image)
        if !hadImages {
            _linesWithImagesCount += 1
        }
    }

    /// Clears images from the line at the given index, tracking the count of lines with images
    func clearImagesFromLine(at index: Int) {
        let line = lines[index]
        if line.images != nil {
            _linesWithImagesCount -= 1
            line.images = nil
        }
    }

    /// Recalculates the count of lines with images (used after reflow operations)
    func recalculateLinesWithImagesCount() {
        var count = 0
        for i in 0..<lines.count {
            if lines[i].images != nil {
                count += 1
            }
        }
        _linesWithImagesCount = count
    }

    private func setupLinesCallbacks() {
        _lines.onLineRecycled = { [weak self] hadImages in
            if hadImages {
                self?._linesWithImagesCount -= 1
            }
        }
        _lines.onLinePushed = { [weak self] hasImages in
            if hasImages {
                self?._linesWithImagesCount += 1
            }
        }
        // Stamp the owner at attach time (B.3): a clone never inherits a
        // cross-buffer template's owner, so it is assigned here, when the line
        // actually becomes a member of this buffer.
        _lines.onLineAttached = { [weak self] line in
            line.owningBuffer = self
        }
    }
    
    private var curAttr: Attribute = Attribute.empty
    private var insertMode: Bool = false
    private var marginMode: Bool = false
    private var wraparound: Bool = false

    // OSC 133 state belongs to a buffer so switching to the alternate screen
    // cannot leak an in-progress shell prompt into the normal screen.

    /// The classification new cells receive as they are written, as most
    /// recently declared by the shell.
    var semanticContent: SemanticContent = .none
    /// The input lifetime state machine (R4).
    var semanticInput: SemanticInputState = .idle
    var semanticClickMode: SemanticPromptClickMode = .none
    var semanticUsesSpecialCursorKeys = false

    // The origin is the line object carrying the active group's primary
    // mark, plus a cached row index. No scroll, splice, margin, trim, or
    // reflow path knows this cache exists: the read path revalidates with
    // one pointer compare and rescans outward when the line moved.
    private var semanticPromptStartLine: BufferLine?
    private var semanticPromptStartRowCache = 0
    private(set) var semanticPromptRowScanCount = 0

    // A monotonic prompt-group counter. `beginSemanticPromptGroup` advances it;
    // the group-opening mark and every hard-continuation line of the group are
    // stamped with the current value, and R5 derivation follows a hard link
    // only when the epochs agree — that is what isolates a new prompt from an
    // old group's stranded continuation rows.
    private var semanticGroupCounter: UInt64 = 0
    private(set) var activeSemanticGroupID: UInt64 = 0

    var semanticPromptStartRow: Int? {
        guard let startLine = semanticPromptStartLine else { return nil }
        if semanticPromptStartRowCache >= 0, semanticPromptStartRowCache < lines.count,
           lines[semanticPromptStartRowCache] === startLine,
           lineCarriesOriginMark(startLine) {
            return semanticPromptStartRowCache
        }
        semanticPromptRowScanCount += 1
        let near = semanticPromptStartRowCache
        if let row = findRow(near: near, where: { $0 === startLine }),
           lineCarriesOriginMark(startLine) {
            semanticPromptStartRowCache = row
            return row
        }
        // A margin copy can move the mark away from its line object. Re-bind
        // to the most recent group opening at or above the cursor. The
        // below-cursor fallback only covers transient scroll states.
        if let row = findSemanticPromptRebindRow() {
            semanticPromptStartLine = lines[row]
            semanticPromptStartRowCache = row
            return row
        }
        semanticPromptStartLine = nil
        return nil
    }

    // R3: re-bind to the most recent group-opening mark at or above the
    // cursor. The scan is row-major (nearest row wins, either kind) so a
    // dead group deeper in the history never beats a nearer live one — a
    // kind-major scan would let an `initial` in scrollback outrank a closer
    // secondary-anchored group. The below-cursor fallback only covers the
    // transient window mid-scroll before the cursor catches up.
    private func findSemanticPromptRebindRow() -> Int? {
        guard !lines.isEmpty else { return nil }
        let cursorRow = min(max(yBase + y, 0), lines.count - 1)

        for row in stride(from: cursorRow, through: 0, by: -1)
        where rowHasGroupOpeningMark(row) {
            return row
        }

        guard cursorRow + 1 < lines.count else { return nil }
        for row in stride(from: cursorRow + 1, through: lines.count - 1, by: 1)
        where rowHasGroupOpeningMark(row) {
            return row
        }
        return nil
    }

    // E.1 single authority: the rebind only accepts the ACTIVE group's opening
    // mark, so it can never attach the origin to a dead group's mark. If the
    // live origin's line is gone and no active-group opening mark remains, the
    // origin resolves to nil and clicks are refused rather than routed against
    // a dead prompt.
    private func rowHasGroupOpeningMark(_ row: Int) -> Bool {
        lines[row].semanticMarks.contains {
            ($0.kind == .initial || $0.kind == .secondary) && $0.group == activeSemanticGroupID
        }
    }

    private func lineCarriesOriginMark(_ line: BufferLine) -> Bool {
        line.semanticMarks.contains { $0.kind == .initial || $0.kind == .secondary }
    }

    /// Scans for a line, radiating outward from `near`: scrolls move the
    /// origin by small deltas, so the match is usually adjacent.
    private func findRow(near: Int, where predicate: (BufferLine) -> Bool) -> Int? {
        let count = lines.count
        guard count > 0 else { return nil }
        let anchor = min(max(near, 0), count - 1)
        var below = anchor
        var above = anchor + 1
        while below >= 0 || above < count {
            if below >= 0 {
                if predicate(lines[below]) {
                    return below
                }
                below -= 1
            }
            if above < count {
                if predicate(lines[above]) {
                    return above
                }
                above += 1
            }
        }
        return nil
    }

    var hasSemanticPromptGroup: Bool {
        semanticPromptStartRow != nil
    }

    func beginSemanticPromptGroup(originRow row: Int) {
        guard row >= 0, row < lines.count else { return }
        semanticGroupCounter &+= 1
        if semanticGroupCounter == 0 { semanticGroupCounter = 1 }
        activeSemanticGroupID = semanticGroupCounter
        semanticPromptStartLine = lines[row]
        semanticPromptStartRowCache = row
    }

    /// R2 reuse rule for `A`/`P;k=i`: reuse the active group only when the
    /// interaction state is prompt or armed, the target row is the resolved
    /// origin **line object** (identity, never the numeric row), and that line
    /// carries the active group's opening mark. Otherwise a new group must be
    /// allocated (a repaint reuses; `D A`, `N B`, and a recycled row do not).
    func canReuseSemanticGroup(atRow row: Int) -> Bool {
        guard semanticInput == .prompt || semanticInput == .armed else { return false }
        guard row >= 0, row < lines.count else { return false }
        guard let originRow = semanticPromptStartRow,
              lines[originRow] === lines[row] else {
            return false
        }
        // F.1: the same opening-mark predicate the rebind uses, so reuse and
        // rebind-refusal can never desynchronize.
        return rowHasGroupOpeningMark(row)
    }

    func clearSemanticPromptGroup() {
        semanticPromptStartLine = nil
    }

    /// The live origin as (line, kind, column), read directly from the
    /// tracked origin line without triggering a rebind. `copyFrom` calls this
    /// mid-scroll, so it must not scan or mutate.
    func rawSemanticOrigin() -> (line: BufferLine, kind: SemanticPromptKind, column: Int)? {
        guard let line = semanticPromptStartLine else { return nil }
        if let mark = line.semanticMarks.first(where: { $0.kind == .initial }) {
            return (line, .initial, mark.column)
        }
        if let mark = line.semanticMarks.first(where: { $0.kind == .secondary }) {
            return (line, .secondary, mark.column)
        }
        return nil
    }

    /// Follows the origin's cells to the line they were copied onto. The row
    /// cache is left to re-resolve lazily on the next read.
    func reassignSemanticOrigin(to line: BufferLine) {
        semanticPromptStartLine = line
    }

    /// Drops `.input`/`.prompt` cell tags from a line being absorbed into a
    /// different (active) group, so a dead group's leftover cells cannot skew
    /// the active group's offset walk (E.4).
    func clearStaleSemanticCells(on line: BufferLine) {
        for col in 0..<line.count {
            var cell = line[col]
            switch cell.semanticContent {
            case .input, .prompt:
                cell.setSemanticContent(.none)
                line[col] = cell
            case .none, .output:
                break
            }
        }
    }

    /// The current absolute row of a line, by identity, or nil if it has
    /// been trimmed or recycled away. Used to re-resolve a deferred click's
    /// target after scrollback may have shifted every index. Reuses the one
    /// identity-scan implementation, hinted near the origin cache (E.5).
    func absoluteRow(of line: BufferLine) -> Int? {
        findRow(near: semanticPromptStartRowCache, where: { $0 === line })
    }

    /// The single entry point through which the OSC 133 handler stores a
    /// shell-authored mark (R2). Same-kind re-marks replace.
    func setSemanticMark(kind: SemanticPromptKind, row: Int, column: Int) {
        guard row >= 0, row < lines.count else { return }
        let line = lines[row]
        guard line.count > 0 else { return }
        // Every mark written while a group is active carries that group's ID;
        // the group-opener's ID is what derivation compares a line's epoch to.
        line.setSemanticMark(kind: kind, column: min(max(column, 0), line.count - 1),
                             group: activeSemanticGroupID)
    }

    /// Shell-authored marks stored on a buffer row.
    func semanticPromptMarks(at row: Int) -> [SemanticPromptAnchor] {
        guard row >= 0, row < lines.count, lines[row].count > 0 else { return [] }
        let line = lines[row]
        return line.semanticMarks.map {
            let column = min(max($0.column, 0), line.count - 1)
            return SemanticPromptAnchor(position: Position(col: column, row: row), kind: $0.kind)
        }
    }

    var activeSemanticPromptOrigin: Position? {
        // D.3: resolve the row here, but take the mark selection from
        // `rawSemanticOrigin` so the initial-wins-else-secondary rule lives in
        // one place — click-time resolution and `copyFrom`'s liveness dedup
        // cannot disagree about which mark is the origin.
        guard let row = semanticPromptStartRow, lines[row].count > 0,
              let origin = rawSemanticOrigin() else {
            return nil
        }
        return Position(col: min(max(origin.column, 0), lines[row].count - 1), row: row)
    }

    /// The derived classification of a row (R5): `initial` for a row whose
    /// line carries a group-opening mark; `continuation` for a row reachable
    /// from such a row through the `isWrapped` chain, or through
    /// hard-continuation lines whose epoch matches the origin mark's group ID;
    /// nil otherwise. The group-ID match is what keeps an old group's stranded
    /// continuation rows from joining a new prompt.
    func semanticRowKind(at row: Int) -> SemanticPromptKind? {
        guard row >= 0, row < lines.count else { return nil }
        let activeOrigin = semanticPromptStartRow
        if originMarkGroup(at: row, activeOrigin: activeOrigin) != nil {
            return .initial
        }
        // F.1: classification is group-agnostic — a joining mark chains to its
        // OWN group, matching how a hard-continuation epoch already does, so a
        // completed PS2/right row derives `.continuation` even after a new
        // group allocates (and the invariant checker no longer false-positives
        // on finished multi-line commands).
        if joiningMarkGroup(at: row) != nil {
            return .continuation
        }
        var current = row
        var epoch: UInt64? = nil
        while current > 0 {
            let line = lines[current]
            if line.isWrapped {
                // soft wrap: same physical write, same group inherently
            } else if let g = line.semanticHardContinuationGroup {
                if let e = epoch, e != g {
                    return nil        // crossed into a different group's epoch
                }
                epoch = g
            } else {
                return nil            // chain broken
            }
            current -= 1
            if let originGroup = originMarkGroup(at: current, activeOrigin: activeOrigin) {
                // A hard chain must land on its own group's origin; a pure
                // soft-wrap chain (epoch == nil) accepts any origin.
                if let e = epoch {
                    return originGroup == e ? .continuation : nil
                }
                return .continuation
            }
            if let joinGroup = joiningMarkGroup(at: current) {
                if let e = epoch {
                    return joinGroup == e ? .continuation : nil
                }
                return .continuation
            }
        }
        return nil
    }

    /// The group ID of a row's group-opening mark, or nil if the row is not an
    /// origin. An `initial` mark is always an origin; a `secondary` mark counts
    /// only on the tracked active origin row (an `A;k=s` group with no primary).
    private func originMarkGroup(at row: Int, activeOrigin: Int?) -> UInt64? {
        let line = lines[row]
        if let mark = line.semanticMarks.first(where: { $0.kind == .initial }) {
            return mark.group
        }
        if activeOrigin == row,
           let mark = line.semanticMarks.first(where: { $0.kind == .secondary }) {
            return mark.group
        }
        return nil
    }

    /// The group ID of a group-joining mark (secondary, continuation, or right)
    /// on a row — a PS2 or right-prompt row that is part of that mark's group.
    /// The single membership predicate used by both classification (any group)
    /// and click geometry (restricted to the active group).
    private func joiningMarkGroup(at row: Int) -> UInt64? {
        lines[row].semanticMarks.first {
            ($0.kind == .secondary || $0.kind == .continuation || $0.kind == .right)
                && $0.group != 0
        }?.group
    }

    /// Whether a row continues the active group across a hard boundary: its
    /// epoch matches the active group, or it carries an active group-joining
    /// mark (PS2/right). The click geometry uses this to walk the group.
    func rowContinuesActiveGroupHard(_ row: Int) -> Bool {
        guard row >= 0, row < lines.count, activeSemanticGroupID != 0 else { return false }
        return lines[row].semanticHardContinuationGroup == activeSemanticGroupID
            || joiningMarkGroup(at: row) == activeSemanticGroupID
    }

    func semanticPromptRelativeOrigin(for position: Position) -> Position? {
        guard let primary = activeSemanticPromptOrigin else { return nil }
        guard position.row >= primary.row else { return primary }
        var relative = primary
        for row in primary.row...min(position.row, lines.count - 1) {
            // C.1: only the active group's own secondaries count — a stale
            // secondary from a dead group surviving on a cleared screen must
            // not skew the relative report.
            for mark in lines[row].semanticMarks
            where mark.kind == .secondary && mark.group == activeSemanticGroupID {
                if row < position.row || mark.column <= position.col {
                    relative = Position(col: mark.column, row: row)
                }
            }
        }
        return relative
    }
    var defaultBidiState: BidiPresentationState
    var scroll: (_ isWrapped: Bool)->() = { x in
        fatalError("This should be set after creating a buffer")
    }
    
    func setInsertMode(_ value: Bool) {
        self.insertMode = value
    }

    func setMarginMode(_ value: Bool) {
        self.marginMode = value
    }

    func setWraparound(_ value: Bool) {
        self.wraparound = value
    }

    public init (cols: Int, rows: Int, tabStopWidth: Int, scrollback: Int?,
                 bidiState: BidiPresentationState = .default) {
        self.hasScrollback = scrollback != nil
        _yDisp = 0
        xDisp = 0
        _yBase = 0
        tabStops = [Bool]()
        savedX = 0
        savedY = 0
        xBase = 0
        _scrollTop = 0
        _scrollBottom = rows - 1
        _marginLeft = 0
        _marginRight = cols - 1
        linesTop = 0
        _x = 0
        _y = 0
        self._cols = cols
        self._rows = rows
        self.scrollback = scrollback
        self.defaultBidiState = bidiState
        
        let len = hasScrollback ? (scrollback ?? 0) + rows : rows
        _lines = CircularBufferLineList (maxLength: len)
        _lines.makeEmpty = { [unowned self] line in getBlankLine(attribute: CharData.defaultAttr, isWrapped: false) }
        setupLinesCallbacks()
        setupTabStops (tabStopWidth: tabStopWidth)
    }
        
    public func getCorrectBufferLength (_ rows: Int) -> Int
    {
        if hasScrollback {
            let correct = rows + (scrollback ?? 0)
            return correct > Int32.max ? Int (Int32.max) : correct
        } else {
            return rows
        }
    }
    
    public func getNullCell (attribute: Attribute? = nil) -> CharData
    {
        let fgbg = attribute == nil ? Attribute.empty : attribute!.justColor ()
        return CharData(attribute: fgbg, scalar: UnicodeScalar(32)!, size: 1)
    }
    
    public func getBlankLine (attribute: Attribute, isWrapped: Bool = false) -> BufferLine
    {
        let cd = CharData (attribute: attribute)
        let line = BufferLine(cols: cols, fillData: cd, isWrapped: isWrapped,
                              bidiState: defaultBidiState)
        line.owningBuffer = self
        return line
    }
    
    func makeEmptyLine (_ line: Int) -> BufferLine
    {
        return getBlankLine(attribute: CharData.defaultAttr, isWrapped: false)
    }
    
    /**
     * Returns the CharData at the specified position, the screen coordinate is what the user
     * sees.
     */
    public func getChar (at: Position) -> CharData
    {
        let bufferRow = lines [at.row+_yDisp]
        let col = at.col
        if col >= bufferRow.count || col < 0 {
            return CharData.Null
        }
        return bufferRow [at.col]
    }

    public func getChar (atBufferRelative: Position) -> CharData
    {
        let bufferRow = lines [atBufferRelative.row]
        let col = atBufferRelative.col
        if col >= bufferRow.count || col < 0 {
            return CharData.Null
        }
        return bufferRow [atBufferRelative.col]
    }

    public func clear ()
    {
        yDisp = 0
        yBase = 0
        xBase = 0
        linesTop = 0
        x = 0
        y = 0

        _lines = CircularBufferLineList (maxLength: getCorrectBufferLength(rows))
        _lines.makeEmpty = { [unowned self] line in getBlankLine(attribute: CharData.defaultAttr, isWrapped: false) }
        setupLinesCallbacks()
        _linesWithImagesCount = 0
        scrollTop = 0
        scrollBottom = rows - 1
        marginLeft = 0
        marginRight = cols - 1
        semanticContent = .none
        semanticInput = .idle
        semanticClickMode = .none
        semanticUsesSpecialCursorKeys = false
        semanticPromptStartLine = nil
        semanticGroupCounter = 0
        activeSemanticGroupID = 0

        // Figure out how to do this elegantly
        // SetupTabStops ()
    }
    
    public func softReset ()
    {
        savedAttr = CharData.defaultAttr
        savedY = 0
        savedX = 0
        savedCharset = CharSets.defaultCharset
        marginRight = cols-1
        marginLeft = 0
        savedWraparound = false
        savedOriginMode = false
        savedMarginMode = false
        savedReverseWraparound = false
    }
    
    public var isCursorInViewPort : Bool {
        get {
            let absoluteY = yBase + yDisp
            let relativeY = absoluteY + yDisp
            return relativeY >= 0 && relativeY < rows
        }
    }
    
    public func fillViewportRows (attribute : Attribute? = nil)
    {
        // TODO: limitation in original, this does not cope with partial fills, it is either zero or nothing
        if _lines.count != 0 {
            return
        }
        let attr = attribute != nil ? attribute! : CharData.defaultAttr
        for _ in 0..<rows {
            _lines.push (getBlankLine (attribute: attr))
        }
    }
    
    public var isReflowEnabled: Bool {
        return hasScrollback
    }
    
    public func resize (newCols : Int, newRows : Int)
    {
        if marginRight > newCols - 1 {
            marginRight = newCols - 1
        }
        if marginLeft >= marginRight {
            marginLeft = marginRight
        }
        let newMaxLength = getCorrectBufferLength(newRows)
        if newMaxLength > lines.maxLength {
            lines.maxLength = newMaxLength
        }
        if lines.count > 0 {
            // Deal with columns increasing (reducing needs to happen after reflow)
            
            if cols < newCols {
                // Iterate only the lines that exist: touching every capacity slot
                // materializes a BufferLine per empty slot (the CircularList subscript
                // calls makeEmpty), making resize O(scrollback capacity). Empty slots
                // are created on demand at the buffer's current cols, so they never
                // need resizing here.
                for i in 0..<lines.count {
                    lines [i].resize (cols: newCols, fillData: CharData.Null)
                }

            }

            // Resize rows in both directions as needed
            var addToY = 0
            if rows < newRows {
                for y in rows..<newRows {
                    if lines.count < newRows + yBase {
                        if yBase > 0 && lines.count <= yBase + y + addToY + 1 {
                            // There is room above the buffer and there are no empty elements below the line,
                            // scroll up
                            yBase -= 1
                            addToY += 1
                            if yDisp > 0 {
                                // Viewport is at the top of the buffer, must increase downwards
                                yDisp -= 1
                            }
                        } else {
                            // Add a blank line if there is no buffer left at the top to scroll to, or if there
                            // are blank lines after the cursor
                            lines.push (BufferLine (cols: newCols, fillData: CharData.Null,
                                                    bidiState: defaultBidiState))
                        }
                    }
                }
            } else { // (this._rows >= newRows)
                for _ in (newRows..<rows).reversed () {
                    if lines.count > newRows + yBase {
                        if lines.count > yBase + self.y + 1 {
                            // The line is a blank line below the cursor, remove it
                            lines.pop ()
                        } else {
                            // The line is the cursor, scroll down
                            yBase += 1
                            yDisp += 1
                        }
                    }
                }
            }

            // Reduce max length if needed after adjustments, this is done after as it
            // would otherwise cut data from the bottom of the buffer.
            if newMaxLength < lines.maxLength {
                // Trim from the top of the buffer and adjust ybase and ydisp.
                let amountToTrim = lines.count - newMaxLength
                if amountToTrim > 0 {
                    lines.trimStart(count: amountToTrim)
                    yBase = max (yBase - amountToTrim, 0)
                    yDisp = max (yDisp - amountToTrim, 0)
                    savedY = max (savedY - amountToTrim, 0)
                }

                lines.maxLength = newMaxLength
            }

            // Make sure that the cursor stays on screen
            x = min (x, newCols - 1)
            y = min (y, newRows - 1)
            if addToY != 0 {
                y += addToY
            }

            savedX = min (savedX, newCols - 1)

            scrollTop = 0
        }
        scrollBottom = newRows - 1
        if tabStops.count > newCols {
            tabStops.removeSubrange (newCols..<tabStops.count-1)
        } else {
            let n = newCols - tabStops.count
            for _ in 0..<n {
                tabStops.append (false)
            }
        }
        
        if isReflowEnabled {
            reflow (newCols, newRows)
            // Trim the end of the line off if cols shrunk
            if cols > newCols {
                // lines.count, not lines.maxLength (see the widen loop above).
                for i in 0..<lines.count {
                    lines [i].resize (cols: newCols, fillData: CharData.Null)
                }
            }
        }
        
        // DEBUG: Post-condition
        if lines.count > 0 {
            // lines.count, not lines.maxLength: checking every capacity slot would
            // materialize blank lines for the whole scrollback on every resize and,
            // worse, they would be created at the old `cols` (updated below) and
            // trip the abort() when widening.
            for i in 0..<lines.count {
                let line = lines [i]
                if line.count < newCols {
                    print ("stop here newCols=\(newCols) but the element has: \(line.count)")
                    abort ()
                }
            }
        }
        rows = newRows
        cols = newCols
    }
    
    /// Removes the scrollback history (the lines above the visible screen)
    /// without touching the visible screen contents or the buffer's capacity
    public func clearScrollback ()
    {
        guard yBase > 0 else {
            return
        }
        let amountToTrim = yBase
        lines.trimStart (count: amountToTrim)
        yBase = 0
        yDisp = 0
        savedY = max (savedY - amountToTrim, 0)
    }

    public func changeHistorySize (_ newScrollback: Int?)
    {
        self.scrollback = newScrollback
        self.hasScrollback = newScrollback != nil
        
        let newMaxLength = getCorrectBufferLength(rows)
        let oldMaxLength = lines.maxLength
        
        if newMaxLength != oldMaxLength {
            if newMaxLength > oldMaxLength {
                // Increase buffer size - just update maxLength
                lines.maxLength = newMaxLength
            } else {
                // Decrease buffer size - need to trim and adjust
                let amountToTrim = lines.count - newMaxLength
                if amountToTrim > 0 {
                    lines.trimStart(count: amountToTrim)
                    yBase = max(yBase - amountToTrim, 0)
                    yDisp = max(yDisp - amountToTrim, 0)
                    savedY = max(savedY - amountToTrim, 0)
                }
                lines.maxLength = newMaxLength
            }
        }
    }

    /// R7: the structural invariants of the stored-marks model. Behavioral
    /// tests assert observable output; this asserts the storage rules.
    func semanticPromptInvariantsHold() -> Bool {
        let activeOrigin = semanticPromptStartRow
        for row in 0..<lines.count {
            let line = lines[row]
            var seenKinds: [SemanticPromptKind] = []
            for mark in line.semanticMarks {
                // Continuation is a derived row kind; storing it is a bug
                // by definition.
                if mark.kind == .continuation {
                    return false
                }
                // No two marks of the same kind on one line.
                if seenKinds.contains(mark.kind) {
                    return false
                }
                seenKinds.append(mark.kind)
                // Every mark column is inside the line's content width.
                if mark.column < 0 || mark.column >= line.count {
                    return false
                }
                // No mark records a group beyond the counter that issues them.
                if mark.group > semanticGroupCounter {
                    return false
                }
            }
            // D.2: no continuation epoch exceeds the group counter.
            if let epoch = line.semanticHardContinuationGroup, epoch > semanticGroupCounter {
                return false
            }
            // B.3: an attached line's owner is this buffer (never leaks a
            // cross-buffer owner). Marks require an owner for liveness dedup.
            if line.owningBuffer !== nil && line.owningBuffer !== self {
                return false
            }
            // D.2: no `.prompt`-tagged cell on a row whose derived kind is nil.
            if semanticRowKind(at: row) == nil {
                for column in 0..<line.count {
                    if case .prompt = line[column].semanticContent {
                        return false
                    }
                }
            }
        }
        // The origin resolves to a line carrying a group-opening mark, and
        // that row derives as `initial`.
        if let row = activeOrigin {
            guard originMarkGroup(at: row, activeOrigin: row) != nil,
                  semanticRowKind(at: row) == .initial else {
                return false
            }
        }
        return true
    }
    
    func translateBufferLineToString (lineIndex: Int, trimRight: Bool, startCol: Int = 0, endCol: Int = -1, skipNullCellsFollowingWide: Bool = false, characterProvider: ((CharData) -> Character)? = nil) -> String
    {
        let line = _lines [lineIndex]
        return line.translateToString(trimRight: trimRight, startCol: startCol, endCol: endCol, skipNullCellsFollowingWide: skipNullCellsFollowingWide, characterProvider: characterProvider)
    }
    
    func setupTabStops (index: Int = -1, tabStopWidth: Int)
    {
        var idx = index
        
        if idx != -1 {
            if tabStops.count > cols {
                tabStops.removeSubrange(cols...)
            } else {
                for _ in cols..<tabStops.count {
                    tabStops.append(false)
                }
            }
            let from = min (index, cols - 1)
            if !tabStops [from] {
                idx = previousTabStop (from)
            }
        } else {
            tabStops = Array.init (repeating: false, count: cols)
            idx = 0
        }
        for i in stride(from: idx, to: cols, by: tabStopWidth) {
            tabStops [i] = true
        }
    }
    
    func tabSet (pos : Int)
    {
        if pos < tabStops.count {
            tabStops [pos] = true
        }
    }
    
    func tabClear (pos : Int)
    {
        if pos < tabStops.count {
            tabStops [pos] = false
        }
    }
    
    func clearTabStops ()
    {
        tabStops = Array.init (repeating: false, count: tabStops.count)
    }
    
    func previousTabStop (_ index : Int = -1) -> Int
    {
        var idx = index == -1 ? x : index
        while idx > 0 && !tabStops [idx-1] {
            idx = idx - 1
        }
        if idx > 0 {
            idx -= 1
        }
        return idx >= cols ? cols - 1 : idx
    }
    
    func nextTabStop (marginMode: Bool, _ index : Int = -1) -> Int
    {
        // Users marginMode because apparently for tabs, there is no need to have originMode set
        let limit = marginMode ? marginRight : (cols-1)
        var idx = index == -1 ? x : index
        
        repeat {
            idx = idx + 1
            if idx > limit {
                break
            }
            if tabStops [idx] {
                break
            }
        } while idx < limit
        return idx >= limit ? limit : idx
    }
    
    func getWrappedLineTrimmedLength (_ lines: CircularBufferLineList, _ row: Int, _ cols: Int) -> Int
    {
        return getWrappedLineTrimmedLength (lines [row], row == lines.count - 1 ? nil : lines [row + 1], cols)
    }

    func getWrappedLineTrimmedLength (_ lines: [BufferLine], _ row: Int, _ cols: Int) -> Int
    {
        return getWrappedLineTrimmedLength (lines [row], row == lines.count - 1 ? nil : lines [row+1], cols)
    }

    func getWrappedLineTrimmedLength (_ line: BufferLine, _ nextLine: BufferLine?, _ cols: Int) -> Int
    {
        // If this is the last row in the wrapped line, get the actual trimmed length
        if nextLine == nil {
            return line.getTrimmedLength ()
        }

        // Detect whether the following line starts with a wide character and the end of the current line
        // is null, if so then we can be pretty sure the null character should be excluded from the line
        // length]
        let endsInNull = !(line.hasContent (index: cols - 1)) && line.getWidth (index: cols - 1) == 1
        let followingLineStartsWithWide = nextLine?.getWidth (index: 0) == 2

        if endsInNull && followingLineStartsWithWide {
            return cols - 1
        }

        return cols
    }

    func getLinesToRemove (oldCols: Int, newCols: Int, bufferAbsoluteY: Int, nullChar: CharData) -> [Int]
    {
        // Gather all BufferLines that need to be removed from the Buffer here so that they can be
        // batched up and only committed once
        var toRemove : [Int] = []

        var y = 0
        while y < lines.count-1 {
            defer { y = y + 1}
            // Check if this row is wrapped
            var i = y
            i = i + 1
            var nextLine = lines [i]
            if !nextLine.isWrapped {
                continue
            }

            // Check how many lines it's wrapped for
            var wrappedLines : [BufferLine] = []
            wrappedLines.append (lines [y])
            while i < lines.count && nextLine.isWrapped {
                wrappedLines.append (nextLine)
                i += 1
                nextLine = lines [i]
            }

            // If these lines contain the cursor don't touch them, the program will handle fixing up wrapped
            // lines with the cursor
            if bufferAbsoluteY >= y && bufferAbsoluteY < i {
                y += wrappedLines.count - 1
                continue
            }

            // Copy buffer data to new locations
            var destLineIndex = 0
            var destCol = getWrappedLineTrimmedLength (lines, destLineIndex, oldCols)
            var srcLineIndex = 1
            var srcCol = 0
            while srcLineIndex < wrappedLines.count {
                let srcTrimmedTineLength = getWrappedLineTrimmedLength (wrappedLines, srcLineIndex, oldCols)
                let srcRemainingCells = srcTrimmedTineLength - srcCol
                let destRemainingCells = newCols - destCol
                let cellsToCopy = min (srcRemainingCells, destRemainingCells)

                if destLineIndex < wrappedLines.count {
                    wrappedLines [destLineIndex].copyFrom (wrappedLines [srcLineIndex], srcCol: srcCol,
                                                           dstCol: destCol, len: cellsToCopy)
                }

                destCol += cellsToCopy;
                if destCol == newCols {
                    destLineIndex += 1
                    destCol = 0;
                }

                srcCol += cellsToCopy;
                if srcCol == srcTrimmedTineLength {
                    srcLineIndex += 1
                    srcCol = 0;
                }

                // Make sure the last cell isn't wide, if it is copy it to the current dest
                if destCol == 0 && destLineIndex != 0 {
                    if wrappedLines [destLineIndex - 1].getWidth(index: newCols - 1) == 2 {
                        wrappedLines [destLineIndex].copyFrom (wrappedLines [destLineIndex - 1], srcCol: newCols - 1, dstCol: destCol, len: 1)
                        destCol += 1
                        // Null out the end of the last row
                        wrappedLines [destLineIndex - 1].replaceCells (start: newCols - 1, end: newCols, fillData: nullChar)
                    }
                }
            }

            // Clear out remaining cells or fragments could remain;
            wrappedLines [destLineIndex].replaceCells (start: destCol, end: newCols, fillData: nullChar)

            // Work backwards and remove any rows at the end that only contain null cells
            var countToRemove = 0
            var ix = wrappedLines.count-1
            
            while ix > 0 {
                defer { ix = ix - 1 }
                if ix > destLineIndex || wrappedLines [ix].getTrimmedLength () == 0 {
                    countToRemove += 1
                } else {
                    break
                }
            }

            if countToRemove > 0 {
                toRemove.append (y + wrappedLines.count - countToRemove) // index
                toRemove.append (countToRemove)
            }

            y += wrappedLines.count - 1
        }

        return toRemove
    }
    
    func reflowWider (_ oldCols: Int, _ oldRows: Int, _ newCols: Int, _ newRows: Int)
    {
        let toRemove = getLinesToRemove(oldCols: oldCols, newCols: newCols, bufferAbsoluteY: yBase + y, nullChar: CharData.Null)
        
        //print ("Lines to remove: \(toRemove) \(toRemove.count)")
        if toRemove.count > 0 {
            // Create new layout
            let layout = CircularList<Int> (maxLength: lines.count)
            layout.makeEmpty = { line in 0 }

            // First iterate through the list and get the actual indexes to use for rows
            var nextToRemoveIndex = 0
            var nextToRemoveStart = toRemove [nextToRemoveIndex]
            var countRemovedSoFar = 0

            var i = 0
            while i < lines.count {
                if nextToRemoveStart == i {
                    nextToRemoveIndex += 1
                    let countToRemove = toRemove [nextToRemoveIndex]

                    i += countToRemove - 1
                    countRemovedSoFar += countToRemove

                    nextToRemoveStart = Int.max
                    if nextToRemoveIndex < toRemove.count - 1 {
                        nextToRemoveIndex += 1
                        nextToRemoveStart = toRemove [nextToRemoveIndex]
                    }
                } else {
                    layout.push (i)
                }
                i += 1
            }

            // Apply the new layout
            let newLayoutLines = CircularBufferLineList (maxLength: lines.count)
            newLayoutLines.makeEmpty = { [unowned self] line in getBlankLine(attribute: CharData.defaultAttr, isWrapped: false) }
            for i in 0..<layout.count {
                  newLayoutLines.push (lines [layout [i]])
            }
                  
            // Rearrange the list
            for i in 0..<newLayoutLines.count {
                  lines [i] = newLayoutLines [i]
            }
            lines.count = layout.count
            
            // adjust viewport
            var viewportAdjustments = countRemovedSoFar
            while viewportAdjustments > 0 {
                viewportAdjustments -= 1
                if yBase == 0 {
                    if y > 0 {
                        y -= 1
                    }
    
                    if lines.count < newRows {
                        // Add an extra row at the bottom of the viewport
                        lines.push (BufferLine (cols: newCols, fillData: CharData.Null,
                                                bidiState: defaultBidiState))
                    }
                } else {
                    if yDisp == yBase {
                        yDisp -= 1
                    }
                    yBase -= 1
                }
            }
            savedY = max (savedY - countRemovedSoFar, 0)
        }
    }
    
    // Gets the new line lengths for a given wrapped line. The purpose of this function it to pre-
    // compute the wrapping points since wide characters may need to be wrapped onto the following line.
    // This function will return an array of numbers of where each line wraps to, the resulting array
    // will only contain the values `newCols` (when the line does not end with a wide character) and
    // `newCols - 1` (when the line does end with a wide character), except for the last value which
    // will contain the remaining items to fill the line.
    // Calling this with a `newCols` value of `1` will lock up.
    func getNewLineLengths (wrappedLines: [BufferLine] , oldCols: Int, newCols: Int) -> [Int]
    {
        var newLineLengths : [Int] = []

        var cellsNeeded = 0
        for i in 0..<wrappedLines.count {
               cellsNeeded += getWrappedLineTrimmedLength (wrappedLines, i, oldCols)
        }

        // Use srcCol and srcLine to find the new wrapping point, use that to get the cellsAvailable and
        // linesNeeded
        var srcCol = 0;
        var srcLine = 0;
        var cellsAvailable = 0;
        while cellsAvailable < cellsNeeded {
               if cellsNeeded - cellsAvailable < newCols {
                       // Add the final line and exit the loop
                       newLineLengths.append (cellsNeeded - cellsAvailable)
                       break;
               }

               srcCol += newCols
               let oldTrimmedLength = getWrappedLineTrimmedLength (wrappedLines, srcLine, oldCols)
               if srcCol > oldTrimmedLength {
                       srcCol -= oldTrimmedLength
                       srcLine += 1
               }

               let endsWithWide = srcLine < wrappedLines.count &&
                                  wrappedLines [srcLine].getWidth(index: srcCol - 1) == 2
               if endsWithWide {
                       srcCol -= 1
               }

               let lineLength = endsWithWide ? newCols - 1 : newCols
               newLineLengths.append (lineLength)
               cellsAvailable += lineLength
        }

        return newLineLengths
    }

    struct InsertionSet {
        var lines: [BufferLine]
        var start: Int
        var isNull: Bool
        public static func Null () -> InsertionSet { InsertionSet (lines: [], start: 0, isNull: true) }
    }
    
    func reflowNarrower (_ oldCols: Int, _ oldRows: Int, _ newCols: Int, _ newRows: Int)
    {
        // Gather all BufferLines that need to be inserted into the Buffer here so that they can be
        // batched up and only committed once
        var toInsert : [InsertionSet] = []
        var countToInsert = 0

        // Go backwards as many lines may be trimmed and this will avoid considering them
        var y = lines.count-1
        while y >= 0 {
            defer { y -= 1 }
            // Check whether this line is a problem or not, if not skip it
            var nextLine = lines [y]
            let lineLength = nextLine.getTrimmedLength ()
            if !nextLine.isWrapped && lineLength <= newCols {
                continue
            }

            // Gather wrapped lines and adjust y to be the starting line
            var wrappedLines : [BufferLine] = []
            wrappedLines.append (nextLine)
            while nextLine.isWrapped && y > 0 {
                y -= 1
                nextLine = lines [y]
                wrappedLines.insert (nextLine, at: 0)
            }

            // If these lines contain the cursor don't touch them, the program will handle fixing up
            // wrapped lines with the cursor
            let absoluteY = yBase + self.y

            if absoluteY >= y && absoluteY < y + wrappedLines.count {
                continue
            }

            let lastLineLength = wrappedLines [wrappedLines.count - 1].getTrimmedLength ()
            let destLineLengths = getNewLineLengths (wrappedLines: wrappedLines, oldCols: oldCols, newCols: newCols)
            if destLineLengths.count == 0 {
                continue
            }
            let linesToAdd = destLineLengths.count - wrappedLines.count

            var trimmedLines: Int
            if yBase == 0 && self.y != lines.count - 1 {
                // If the top section of the buffer is not yet filled
                trimmedLines = max (0, self.y - lines.maxLength + linesToAdd)
            } else {
                trimmedLines = max (0, lines.count - lines.maxLength + linesToAdd)
            }

            // Add the new lines
            var newLines : [BufferLine] = []
            let paragraphBidiState = wrappedLines[0].bidiState
            if linesToAdd > 0 {
                for _ in 0..<linesToAdd {
                    let newLine = getBlankLine (attribute: CharData.defaultAttr, isWrapped: true)
                    newLine.bidiState = paragraphBidiState
                    newLines.append (newLine)
                }
            }

            if newLines.count > 0 {
                toInsert.append (InsertionSet (lines: newLines, start: y + wrappedLines.count + countToInsert, isNull: false))
                
                countToInsert += newLines.count
            }
            for l in newLines {
                wrappedLines.append (l)
            }
            for line in wrappedLines {
                line.bidiState = paragraphBidiState
            }

            // Copy buffer data to new locations, this needs to happen backwards to do in-place
            var destLineIndex = destLineLengths.count - 1 // Math.floor(cellsNeeded / newCols)
            var destCol = destLineLengths [destLineIndex] // cellsNeeded % newCols;
            if destCol == 0 {
                destLineIndex -= 1
                destCol = destLineLengths [destLineIndex]
            }

            var srcLineIndex = wrappedLines.count - linesToAdd - 1
            var srcCol = lastLineLength
            while srcLineIndex >= 0 {
                let cellsToCopy = min (srcCol, destCol)
                wrappedLines [destLineIndex].copyFrom (wrappedLines [srcLineIndex], srcCol: srcCol - cellsToCopy, dstCol: destCol - cellsToCopy, len: cellsToCopy)
                destCol -= cellsToCopy
                if destCol == 0 {
                    destLineIndex -= 1
                    if destLineIndex >= 0 {
                        destCol = destLineLengths [destLineIndex]
                    }
                }

                srcCol -= cellsToCopy
                if srcCol == 0 {
                    srcLineIndex -= 1
                    let wrappedLinesIndex = max (srcLineIndex, 0)
                    srcCol = getWrappedLineTrimmedLength (wrappedLines, wrappedLinesIndex, oldCols)
                }
            }

            // Null out the end of the line ends if a wide character wrapped to the following line
            for i in 0..<wrappedLines.count {
                if destLineLengths [i] < newCols {
                    wrappedLines [i] [destLineLengths [i]] = CharData.Null
                }
            }

            // Adjust viewport as needed
            var viewportAdjustments = linesToAdd - trimmedLines
            while viewportAdjustments > 0 {
                viewportAdjustments -= 1
                if yBase == 0 {
                    if self.y < newRows - 1 {
                        self.y += 1
                        lines.pop ()
                    } else {
                        yBase += 1
                        yDisp += 1
                    }
                } else {
                    // Ensure ybase does not exceed its maximum value
                    if yBase < min (lines.maxLength, lines.count + countToInsert) - newRows {
                        if yBase == yDisp {
                            yDisp += 1
                        }

                        yBase += 1
                    }
                }
            }

            savedY = min (savedY + linesToAdd, yBase + newRows - 1)
        }

        rearrange (toInsert, countToInsert)
    }

    func rearrange (_ toInsert: [InsertionSet], _ countToInsert: Int)
    {
        // Rearrange lines in the buffer if there are any insertions, this is done at the end rather
        // than earlier so that it's a single O(n) pass through the buffer, instead of O(n^2) from many
        // costly calls to CircularList.splice.
        if toInsert.count > 0 {
            // Record buffer insert events and then play them back backwards so that the indexes are
            // correct
            // let insertEvents : [Int] = []

            // Record original lines so they don't get overridden when we rearrange the list
            let originalLines = CircularBufferLineList (maxLength: lines.maxLength)
            for i in 0..<lines.count {
                originalLines.push (lines [i])
            }

            let originalLinesLength = lines.count

            var originalLineIndex = originalLinesLength - 1
            var nextToInsertIndex = 0
            var nextToInsert = toInsert [nextToInsertIndex]
            lines.count = min (lines.maxLength, lines.count + countToInsert)
        
            var countInsertedSoFar = 0
            var i = min (lines.maxLength - 1, originalLinesLength + countToInsert - 1)
            while i >= 0 {
                defer { i = i-1 }
                if !nextToInsert.isNull && nextToInsert.start > originalLineIndex + countInsertedSoFar {
                        // Insert extra lines here, adjusting i as needed
                    for nexti in (0..<nextToInsert.lines.count).reversed() {
                        if i < 0 {
                            // if we reflow and the content has to be scrolled back past the beginning
                            // of the buffer then we end up loosing those lines
                            break
                        }
                        lines [i] = nextToInsert.lines [nexti]
                        i -= 1
                    }

                    i += 1

                    countInsertedSoFar += nextToInsert.lines.count
                    if nextToInsertIndex < toInsert.count - 1 {
                        nextToInsertIndex += 1
                       nextToInsert = toInsert [nextToInsertIndex]
                    } else {
                        nextToInsert = InsertionSet.Null ()
                    }
                } else {
                    lines [i] = originalLines [originalLineIndex]
                    originalLineIndex -= 1
                }
            }
        }
    }
    
    func reflow (_ newCols: Int, _ newRows: Int)
    {
        if cols == newCols {
            return
        }
        // iterate through rows, ignore the last one as it cannot be wrapped

        if newCols > cols {
            reflowWider (cols, rows, newCols, newRows)
        } else {
            reflowNarrower (cols, rows, newCols, newRows)
        }
        recalculateLinesWithImagesCount()
    }
    
    static var n = 0
    
    func dump ()
    {
        var str = ""
        str += "xDisp=\(xDisp), yDisp=\(yDisp), xBase=\(xBase), yBase=\(yBase)\n"
        str += "scrollTop=\(scrollTop) scrollBottom=\(scrollBottom)\n"
        str += "count=\(lines.count) maxLength=\(lines.maxLength)\n"
        for i in 0..<_lines.getArray().count {
            var txt: String
            if let r = _lines.getArray()[i] {
                txt = r.debugDescription.replacingOccurrences(of: "\u{0}", with: " ")
            } else {
                txt = "<empty>"
            }
            let flag = i >= yDisp ? ">>" : "  "
            let istr = String (format: "%03d", i)
            let cstr = String (format: "%03d", _lines.debugGetCyclicIndex(i))
            str += "[\(istr):\(cstr)]\(flag)\(txt)\n"
        }
        let file = "/Users/miguel/Downloads/Logs/dump-\(Buffer.n)"
        do {
            try str.write(to: URL.init (fileURLWithPath: file), atomically: false, encoding: .utf8)

        } catch {
            print ("Could not log the dump() contents to \(file)")
        }
        Buffer.n += 1
    }
    
    /// Bulk-inserts ASCII characters (all width-1, non-combining).
    /// Returns number of bytes consumed. Returns 0 if insert mode is active.
    func insertAsciiRun(
        _ bytes: ArraySlice<UInt8>,
        attribute: Attribute,
        resolvePayload: () -> TinyAtom?
    ) -> Int {
        guard !insertMode else { return 0 }
        let right = marginMode ? _marginRight : _cols - 1
        var consumed = 0
        var idx = bytes.startIndex
        var payload: TinyAtom?
        var didResolvePayload = false

        while idx < bytes.endIndex {
            if _x > right {
                guard wraparound else { break }
                _x = marginMode ? _marginLeft : 0
                if _y >= _scrollBottom {
                    scroll(true)
                } else {
                    let paragraphBidiState = _lines[_y + _yBase].bidiState
                    _y += 1
                    _lines[_y + _yBase].isWrapped = true
                    _lines[_y + _yBase].bidiState = paragraphBidiState
                }
            }
            let available = right - _x + 1
            let runLen = min(available, bytes.endIndex - idx)
            let row = _lines[_y + _yBase]
            if !didResolvePayload {
                payload = resolvePayload()
                didResolvePayload = true
            }
            for i in 0..<runLen {
                var cell = CharData(attribute: attribute, code: Int32(bytes[idx + i]), size: 1)
                cell.setSemanticContent(semanticContent)   // buffer's own classification (D.1)
                if let payload {
                    cell.setPayload(atom: payload)
                }
                row[_x + i] = cell
            }
            _x += runLen
            consumed += runLen
            idx += runLen
        }
        return consumed
    }

    func insertCharacter(_ charData: CharData, resolvePayload: () -> TinyAtom?) {
        // D.1: stamp the OSC 133 role once, here at the insertion funnel, from
        // the buffer's own classification. No caller can forget to stamp, and
        // during ordinary output `semanticContent` is `.none` (a no-op).
        var charData = charData
        charData.setSemanticContent(semanticContent)
        var chWidth = Int (charData.width)
        
        let right = marginMode ? _marginRight : _cols - 1
        // goto next line if ch would overflow
        // TODO: needs a global min terminal width of 2
        // FIXME: additionally ensure chWidth fits into a line
        //   -->  maybe forbid cols<xy at higher level as it would
        //        introduce a bad runtime penalty here
        if _x + chWidth - 1 > right {
            // autowrap - DECAWM
            // automatically wraps to the beginning of the next line
            if wraparound {
                _x = marginMode ? _marginLeft : 0
                
                if _y >= _scrollBottom {
                    scroll (true)
                } else {
                    // The line already exists (eg. the initial viewport), mark it as a
                    // wrapped line
                    let paragraphBidiState = _lines[_y + _yBase].bidiState
                    _y += 1
                    _lines [_y + _yBase].isWrapped = true
                    _lines [_y + _yBase].bidiState = paragraphBidiState
                }
                // row changed, get it again
            } else {
                if (chWidth == 2) {
                    // FIXME: check for xterm behavior
                    // What to do here? We got a wide char that does not fit into last cell
                    return
                }
                // FIXME: Do we have to set buffer.x to cols - 1, if not wrapping?
                _x = right
            }
        }
        let bufferRow = _lines[_y+_yBase]

        // insert mode: move characters to right
        if insertMode {
            var empty = CharData.Null
            empty.attribute = curAttr
            // right shift cells according to the width
            bufferRow.insertCells (pos: _x, n: chWidth, rightMargin: marginMode ? _marginRight : _cols-1, fillData: empty)
            // test last cell - since the last cell has only room for
            // a halfwidth char any fullwidth shifted there is lost
            // and will be set to eraseChar
            let lastCell = bufferRow [_cols - 1]
            if lastCell.width == 2 {
                bufferRow [_cols - 1] = empty
            }
        }

        // Write current char to buffer and advance cursor.
        if _x >= _cols {
            _x = _cols-1
        }
        charData.setPayload(atom: resolvePayload() ?? TinyAtom.empty)
        bufferRow[_x] = charData
        _x += 1

        // fullwidth char - also set next cell to placeholder stub and advance cursor
        // for graphemes bigger than fullwidth we can simply loop to zero
        // we already made sure above, that buffer.x + chWidth will not overflow right
        if chWidth > 1 {
            var wideEmpty = CharData(attribute: curAttr, scalar: UnicodeScalar(0)!, size: 0)
            wideEmpty.setSemanticContent(charData.semanticContent)
            wideEmpty.setPayload(atom: charData.payload)
            chWidth -= 1
            while chWidth != 0 && _x < _cols {
                bufferRow [_x] = wideEmpty
                _x += 1
                chWidth -= 1
            }
        }
        
    }
    
    func dumpConsole ()
    {
        let debugBuffer = self
        for y in 0..<debugBuffer._lines.maxLength {
            let flag = y == debugBuffer.yDisp ? "D" : " "
            let yb   = y == debugBuffer.yBase ? "B" : " "
            let istr = String (format: "%03d", y)
            let cstr = String (format: "%03d", debugBuffer._lines.debugGetCyclicIndex(y))
        
            print ("[\(istr):\(cstr)]\(flag)\(yb) \(debugBuffer._lines.getArray() [y].debugDescription)")
        }
    }    
}
