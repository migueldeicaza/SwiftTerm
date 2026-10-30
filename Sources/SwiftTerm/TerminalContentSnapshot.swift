/// The current terminal grid size.
public struct TerminalDimensions: Sendable, Equatable {
    public let cols: Int
    public let rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

/// Copied input modes and dimensions, without copying terminal contents.
///
/// This is useful for inspection and common host decisions, but it is not a
/// complete input encoder state. In particular, pointer encoding details and
/// other host-input policy live on the dedicated host input APIs.
public struct TerminalInputStateSnapshot: Sendable, Equatable {
    public let dimensions: TerminalDimensions
    public let isAlternateBuffer: Bool
    public let applicationCursor: Bool
    public let applicationKeypad: Bool
    /// Whether DEC private mode 2004 (bracketed paste) is enabled.
    public let bracketedPasteMode: Bool
    public let mouseMode: Terminal.MouseMode
    public let keyboardEnhancementFlags: KittyKeyboardFlags
    /// Whether the application enabled focus reports (DECSET 1004).
    public let focusReportingEnabled: Bool

    public init(
        dimensions: TerminalDimensions,
        isAlternateBuffer: Bool,
        applicationCursor: Bool,
        applicationKeypad: Bool,
        bracketedPasteMode: Bool,
        mouseMode: Terminal.MouseMode,
        keyboardEnhancementFlags: KittyKeyboardFlags,
        focusReportingEnabled: Bool
    ) {
        self.dimensions = dimensions
        self.isAlternateBuffer = isAlternateBuffer
        self.applicationCursor = applicationCursor
        self.applicationKeypad = applicationKeypad
        self.bracketedPasteMode = bracketedPasteMode
        self.mouseMode = mouseMode
        self.keyboardEnhancementFlags = keyboardEnhancementFlags
        self.focusReportingEnabled = focusReportingEnabled
    }
}

/// Selects the rows of a buffer to copy.
public enum TerminalContentRegion: Sendable, Equatable {
    /// Every retained row: the whole scrollback followed by the live screen.
    case all
    /// The currently displayed rows, including when scrolled into history.
    case viewport
    /// The live screen and up to this many preceding scrollback rows.
    /// Negative values request only the live screen.
    case history(maximumScrollbackRows: Int)
    /// Rows by scroll-invariant number, as `capturedRange` and
    /// `absoluteRow` report them. Rows the terminal no longer retains, or
    /// has not produced yet, are left out.
    case rows(Range<Int>)
}

/// A cell value with its complete text, independent of terminal storage.
public struct TerminalCellSnapshot: Sendable, Equatable {
    public let text: String
    public let width: Int
    public let attribute: Attribute

    public init(text: String, width: Int, attribute: Attribute) {
        self.text = text
        self.width = width
        self.attribute = attribute
    }

    /// True for a cell nothing was written to, which the terminal stores as
    /// a NUL placeholder, and for the continuation cell of a wide character.
    public var isBlank: Bool {
        text.isEmpty || text == "\u{0}"
    }
}

/// A copied row with a scroll-invariant row number.
public struct TerminalContentRowSnapshot: Sendable, Equatable {
    public let absoluteRow: Int
    /// True when this row is a soft-wrapped continuation of the preceding row.
    public let isWrapped: Bool
    public let cells: [TerminalCellSnapshot]
    /// Right-trimmed display text without internal NUL placeholders.
    ///
    /// Wide-cell continuation cells are omitted and unwritten cells inside the
    /// trimmed region are represented as spaces. No styling is encoded.
    public var text: String {
        terminalContentSnapshotText(cells)
    }

    public init(absoluteRow: Int, cells: [TerminalCellSnapshot], isWrapped: Bool = false) {
        self.absoluteRow = absoluteRow
        self.isWrapped = isWrapped
        self.cells = cells
    }
}

private func terminalContentSnapshotText(_ cells: [TerminalCellSnapshot]) -> String {
    terminalReplacingNulls(terminalRowText(
        cellCount: cells.count,
        logicalCode: { Int32(cells[$0].text.unicodeScalars.first?.value ?? 0) },
        width: { cells[$0].width },
        text: { cells[$0].text.isEmpty ? "\u{0}" : cells[$0].text }))
}

/// Contents and input state captured in one terminal-lock transaction.
///
/// Row numbers use the same scroll-invariant coordinate space as
/// `Terminal.getScrollInvariantLine(row:)`. Only `capturedRange` is copied;
/// it is not necessarily the complete history retained by the terminal.
public struct TerminalContentSnapshot: Sendable, Equatable {
    /// The input modes and the size of the terminal grid.
    public let inputState: TerminalInputStateSnapshot
    /// The buffer the rows were copied from: `.normal` or `.alt`, never
    /// `.active`.
    public let bufferKind: Terminal.BufferKind
    /// The size of the copied buffer. The normal buffer keeps its own size
    /// while the alternate one is active, so this can differ from
    /// `inputState.dimensions`.
    public let dimensions: TerminalDimensions
    public let capturedRange: Range<Int>
    public let liveTopRow: Int
    public let rows: [TerminalContentRowSnapshot]
    /// The cursor row of the copied buffer, in the coordinates of `absoluteRow`.
    public let cursorRow: Int
    /// The cursor column of the copied buffer.
    public let cursorColumn: Int
    /// The 256 palette entries in force when the copy was made, so indexed
    /// cell colors keep their appearance after the palette changes. Empty
    /// when the palette was not captured.
    public let palette: [Color]
    /// The color cells with ``Attribute/Color/defaultColor`` resolve to as
    /// a foreground, or nil when it was not captured.
    public let foregroundColor: Color?
    /// The color cells with ``Attribute/Color/defaultColor`` resolve to as
    /// a background, or nil when it was not captured.
    public let backgroundColor: Color?

    /// Makes a snapshot. When `dimensions` is nil, the copied buffer has the
    /// size in `inputState`.
    public init(
        inputState: TerminalInputStateSnapshot,
        bufferKind: Terminal.BufferKind = .normal,
        dimensions: TerminalDimensions? = nil,
        capturedRange: Range<Int>,
        liveTopRow: Int,
        rows: [TerminalContentRowSnapshot],
        cursorRow: Int = 0,
        cursorColumn: Int = 0,
        palette: [Color] = [],
        foregroundColor: Color? = nil,
        backgroundColor: Color? = nil
    ) {
        self.inputState = inputState
        self.bufferKind = bufferKind == .alt ? .alt : .normal
        self.dimensions = dimensions ?? inputState.dimensions
        self.capturedRange = capturedRange
        self.liveTopRow = liveTopRow
        self.rows = rows
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.palette = palette
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
    }
}

extension TerminalContentSnapshot {
    /// The copied rows as text with SGR sequences, ready to feed into another
    /// terminal of the same width.
    ///
    /// When the snapshot has its colors, the output starts with both default
    /// colors and all captured palette entries, as `OSC 10`, `OSC 11` and
    /// `OSC 4`. This keeps their appearance even when the receiving terminal
    /// has different colors. A snapshot without colors does not change the
    /// colors of the receiver.
    /// Every attribute is re-encoded with ``Attribute/sgrParameters()``,
    /// including dim, italic, strikethrough, underline styles and underline
    /// colors. Wide characters are emitted once and their continuation cells
    /// are skipped. Cells nothing was written to stay that way: runs of them
    /// are stepped over with a cursor move, and runs that carry a background
    /// are erased into place with `ECH`, so the receiving buffer keeps the
    /// same blank cells and the same colored blanks instead of spaces. Blank
    /// cells with a style that shows without text (inverse, underline,
    /// crossed out), which an erase cannot produce, become spaces that look
    /// the same. A wide character cut by the last column, which a buffer
    /// without reflow keeps after its width shrinks, becomes a blank cell.
    ///
    /// The output starts with a carriage return, so the first row starts at
    /// column 0 of the receiving cursor row. Rows end with `CR LF` unless
    /// the next row is a soft-wrapped continuation. Only a written character
    /// wraps the cursor and marks the next row as a continuation, and only a
    /// wide character does so without writing into the last column: a
    /// continued row ends with the cursor moved to its last column and an
    /// ideographic space (`U+3000`), which does not fit there, wraps and is
    /// erased from the start of the next row. Trailing blank cells of the
    /// other rows are dropped. The output ends with a reset and no line
    /// break, so the receiving cursor stays on the last row. The first copied
    /// row cannot be marked as a continuation of a row that was not copied.
    ///
    /// Two adjacent stored cells whose text the terminal would merge when
    /// written in sequence, such as a cell ending in a scalar with the
    /// Unicode `Prepend` property and the cell after it, are separated by a
    /// cursor move to the second cell's column, which starts a new spacing
    /// character; the test is the terminal's, with the pairs it leaves to
    /// segmentation counted as joining.
    ///
    /// Some narrow cells change width when their text is written again.
    /// These cells are written before the other cells of their row. A cell
    /// whose text widens it (such as `❤` and `U+FE0F`) stays narrow only at
    /// the right edge with autowrap off: it is written in the last column
    /// with autowrap off, and `DCH` moves it to its column. A cell in the
    /// last column whose wide first scalar was made narrow (such as `⌚` and
    /// `U+FE0E`) does not fit there before it becomes narrow: it is written
    /// one column to the left, and `ICH` moves it to the last column.
    ///
    /// This restores contents only. The export does not restore cursor
    /// position, modes, margins or the active buffer, and it expects the
    /// receiving terminal to have no margins and empty rows below its cursor.
    /// Replaying a live byte stream after the export is the host's
    /// responsibility.
    public func ansiRepresentation() -> String {
        let reset = Attribute.empty.sgrParameters()
        var result = colorSequences() + "\u{1b}[" + reset + "m\r"
        // Attributes are compared by their SGR encoding: the two spellings of
        // the default colors look the same and must not produce a sequence.
        var current = Attribute.empty
        var currentSgr = reset
        func select(_ attribute: Attribute) {
            guard attribute != current else { return }
            let sgr = attribute.sgrParameters()
            if sgr != currentSgr {
                result += "\u{1b}[" + sgr + "m"
                currentSgr = sgr
            }
            current = attribute
        }
        let width = dimensions.cols
        for (index, row) in rows.enumerated() {
            let continues = index + 1 < rows.count && rows[index + 1].isWrapped
            let pieces = exportPieces(of: row, width: width, continues: continues)
            // The cells that move into place go first, in column order, while
            // the cells to their right are still empty. The deleted and the
            // inserted cells come back as blanks with the default background.
            var moved = false
            for piece in pieces where piece.placement != .inPlace {
                switch piece.placement {
                case .fromLastColumn:
                    result += "\u{1b}[\(width)G"
                    select(piece.attribute)
                    result += "\u{1b}[?7l" + piece.text + "\u{1b}[?7h"
                    if piece.column < width - 1 {
                        select(.empty)
                        result += "\u{1b}[\(piece.column + 1)G\u{1b}[\(width - 1 - piece.column)P"
                    }
                case .fromPreviousColumn:
                    result += "\u{1b}[\(width - 1)G"
                    select(piece.attribute)
                    result += piece.text
                    select(.empty)
                    result += "\u{1b}[\(width - 1)G\u{1b}[@"
                case .inPlace:
                    break
                }
                moved = true
            }
            var cursor = 0
            var previous: TerminalExportPiece?
            for piece in pieces where piece.placement == .inPlace {
                if moved {
                    result += "\r"
                    moved = false
                }
                if piece.column > cursor {
                    result += "\u{1b}[\(piece.column - cursor)C"
                } else if let previous, previous.joins(piece) {
                    // Two stored cells whose text would form one grapheme:
                    // a cursor move starts a new spacing character.
                    result += "\u{1b}[\(piece.column + 1)G"
                }
                select(piece.attribute)
                result += piece.text
                cursor = piece.column + piece.width
                previous = piece
            }
            if index + 1 < rows.count {
                // A wrap or a line feed may scroll, and a scrolled-in row is
                // filled with the current background: reset first so it
                // stays blank.
                select(.empty)
                if continues {
                    result += "\u{1b}[\(width)G\u{3000}\r\u{1b}[2X"
                } else {
                    result += "\r\n"
                }
            }
        }
        if currentSgr != reset {
            result += "\u{1b}[" + reset + "m"
        }
        return result
    }

    /// The sequences that write `row`, in column order. Cells nothing was
    /// written to produce none unless they carry a background, which is
    /// erased into place.
    private func exportPieces(of row: TerminalContentRowSnapshot, width: Int, continues: Bool) -> [TerminalExportPiece] {
        let cells = row.cells
        var end = cells.count
        if !continues {
            while end > 0, cells[end - 1].isBlank, !cells[end - 1].attribute.showsWhenBlank {
                end -= 1
            }
        }
        var pieces: [TerminalExportPiece] = []
        var column = 0
        while column < end {
            let cell = cells[column]
            let start = column
            column += 1
            // A wide character that does not fit is kept as a blank cell.
            let cut = cell.width > 1 && start + cell.width > width
            guard cell.width > 0, !cell.isBlank || cut || cell.attribute.showsWhenBlank else { continue }
            if cell.isBlank || cut {
                // An erase keeps only the background, so blank cells are
                // grouped by what an erase would leave. The half of a wide
                // character left when the other half is overwritten keeps
                // the character's attribute, which can carry a style that
                // shows on a blank cell; those are written as the spaces
                // that look the same.
                let attribute = cell.attribute.blankForm
                var run = cut ? 1 : cell.width
                while column < end, cells[column].width > 0, cells[column].isBlank,
                      cells[column].attribute.blankForm == attribute {
                    run += cells[column].width
                    column += 1
                }
                if attribute.stylesShowWhenBlank {
                    pieces.append(TerminalExportPiece(
                        column: start, width: run, attribute: attribute,
                        text: String(repeating: " ", count: run), lastCell: " "))
                } else {
                    pieces.append(TerminalExportPiece(
                        column: start, width: run, attribute: attribute,
                        text: "\u{1b}[\(run)X\u{1b}[\(run)C", lastCell: nil))
                }
            } else {
                var placement = TerminalExportPiece.Placement.inPlace
                if cell.width == 1 {
                    if TerminalExportPiece.widens(cell.text) {
                        placement = .fromLastColumn
                    } else if start == width - 1, width > 1,
                              let first = cell.text.unicodeScalars.first,
                              UnicodeUtil.columnWidth(rune: first) > 1 {
                        placement = .fromPreviousColumn
                    }
                }
                pieces.append(TerminalExportPiece(
                    column: start, width: cell.width, attribute: cell.attribute,
                    text: cell.text, lastCell: cell.text, placement: placement))
            }
        }
        return pieces
    }

    /// Writes both default colors, then every captured palette entry.
    /// The default colors go first because they can rebuild the palette.
    func colorSequences() -> String {
        var result = ""
        if let foregroundColor {
            result += "\u{1b}]10;\(foregroundColor.formatAsXcolor())\u{7}"
        }
        if let backgroundColor {
            result += "\u{1b}]11;\(backgroundColor.formatAsXcolor())\u{7}"
        }
        if palette.count == 256 {
            for (index, color) in palette.enumerated() {
                result += "\u{1b}]4;\(index);\(color.formatAsXcolor())\u{7}"
            }
        }
        return result
    }
}

/// One sequence of ``TerminalContentSnapshot/ansiRepresentation()``: a cell's
/// text, a run of styled spaces or an erase, with the columns it covers.
private struct TerminalExportPiece {
    /// Where the text is written before it is in its column.
    enum Placement: Equatable {
        /// At its column.
        case inPlace
        /// In the last column with autowrap off, then moved left with `DCH`.
        case fromLastColumn
        /// One column to the left of the last column, then moved into the
        /// last column with `ICH`.
        case fromPreviousColumn
    }

    let column: Int
    let width: Int
    let attribute: Attribute
    let text: String
    /// The text of the last cell the sequence writes; nil for an erase,
    /// which leaves cells the terminal never extends.
    let lastCell: String?
    var placement: Placement = .inPlace

    /// True when writing `next` right after this piece would extend this
    /// piece's last cell instead of starting a cell of its own.
    func joins(_ next: TerminalExportPiece) -> Bool {
        guard let lastCell, let nextCell = next.lastCell, next.column == column + width else { return false }
        return TerminalExportPiece.joins(lastCell, nextCell.unicodeScalars.first!)
    }

    /// True when the terminal makes a narrow cell wide while it writes
    /// `text`: a scalar after the first one widens the cell it joins.
    static func widens(_ text: String) -> Bool {
        var previous: UInt32?
        for scalar in text.unicodeScalars {
            defer { previous = scalar.value }
            guard let previous else { continue }
            switch scalar.value {
            case 0xFE0F:
                if let base = Unicode.Scalar(previous), UnicodeUtil.isEmojiVs16Base(rune: base) {
                    return true
                }
            case 0xFE0E:
                continue
            default:
                if UnicodeUtil.widensJoinedCell(
                    incoming: scalar.value,
                    properties: UnicodeUtil.graphemeProperties(scalar.value),
                    width: UnicodeUtil.columnWidth(rune: scalar)) {
                    return true
                }
            }
        }
        return false
    }

    /// The test the terminal makes before it stores `scalar` after the cell
    /// with text `cell`. The pairs the terminal leaves to the standard
    /// library's segmentation count as joining: a cursor move they did not
    /// need costs four bytes, a missing one merges two cells.
    static func joins(_ cell: String, _ scalar: Unicode.Scalar) -> Bool {
        UnicodeUtil.graphemeJoin(
            previous: cell.unicodeScalars.last!.value,
            incoming: scalar.value,
            incomingProperties: UnicodeUtil.graphemeProperties(scalar.value),
            incomingWidth: UnicodeUtil.columnWidth(rune: scalar)) != .breaks
    }
}

extension Attribute {
    /// True when a cell with this attribute shows something other than the
    /// default background even if it has no text.
    var paintsBackground: Bool {
        if style.contains(.inverse) {
            return true
        }
        switch bg {
        case .defaultColor, .defaultInvertedColor:
            return false
        case .ansi256, .trueColor:
            return true
        }
    }

    /// True when the renderer draws this attribute's style on a cell without
    /// text: inverse fills it, underline and crossed-out draw their lines.
    var stylesShowWhenBlank: Bool {
        !style.intersection([.inverse, .underline, .crossedOut]).isEmpty
    }

    /// True when a cell with this attribute is visible without text.
    var showsWhenBlank: Bool {
        paintsBackground || stylesShowWhenBlank
    }

    /// The attribute that reproduces a blank cell with this one: the full
    /// attribute when its style shows, otherwise what an erase leaves, which
    /// is the background alone.
    var blankForm: Attribute {
        stylesShowWhenBlank ? self : Attribute(fg: .defaultColor, bg: bg, style: .none)
    }
}

extension Terminal {
    func inputStateSnapshotLocked() -> TerminalInputStateSnapshot {
        terminalLock.preconditionLocked()
        return TerminalInputStateSnapshot(
            dimensions: TerminalDimensions(cols: cols, rows: rows),
            isAlternateBuffer: isCurrentBufferAlternate,
            applicationCursor: applicationCursor,
            applicationKeypad: applicationKeypad,
            bracketedPasteMode: bracketedPasteMode,
            mouseMode: mouseMode,
            keyboardEnhancementFlags: keyboardEnhancementFlags,
            focusReportingEnabled: sendFocus)
    }

    func displayText(buffer: Buffer, line lineIndex: Int, columns: Int) -> String {
        let line = buffer.lines[lineIndex]
        let cellCount = min(max(0, columns), line.count)
        return terminalReplacingNulls(terminalRowText(
            cellCount: cellCount,
            logicalCode: { line.packedCode(at: $0) },
            width: { Int(line.packedWidth(at: $0)) },
            text: { self.getText(for: line[$0]) }))
    }

    /// Copies input modes and dimensions under one terminal lock.
    ///
    /// Do not call this method while you hold ``terminalLock`` or from a
    /// terminal delegate callback that already holds it.
    public func inputStateSnapshot() -> TerminalInputStateSnapshot {
        terminalLock.withLock { inputStateSnapshotLocked() }
    }

    func contentSnapshotLocked(region: TerminalContentRegion,
                               buffer kind: BufferKind = .active) -> TerminalContentSnapshot {
        terminalLock.preconditionLocked()
        let source = kind == .active ? displayBuffer : bufferFromKind(kind: kind)
        // The normal buffer keeps its own size while the alternate one is
        // active: a resize reaches it when it becomes visible again.
        let dimensions = TerminalDimensions(cols: source.cols, rows: source.rows)
        let count = source.lines.count
        let screenRows = min(max(0, dimensions.rows), count)
        let liveStart = count - screenRows
        let start: Int
        let end: Int
        switch region {
        case .all:
            start = 0
            end = count
        case .viewport:
            start = min(max(0, source.yDisp), count)
            end = start + min(screenRows, count - start)
        case .history(let maximumScrollbackRows):
            start = liveStart - min(max(0, maximumScrollbackRows), liveStart)
            end = count
        case .rows(let range):
            // Limit absolute bounds before subtraction to avoid integer overflow.
            start = min(max(range.lowerBound, source.linesTop) - source.linesTop, count)
            end = max(start, min(max(range.upperBound, source.linesTop) - source.linesTop, count))
        }
        let copiedRows = (start..<end).map { index in
            let line = source.lines[index]
            let width = min(dimensions.cols, line.count)
            let cells = (0..<width).map { column in
                let cell = line[column]
                return TerminalCellSnapshot(
                    text: cell.getText(),
                    width: Int(cell.width),
                    attribute: cell.attribute)
            }
            return TerminalContentRowSnapshot(
                absoluteRow: source.linesTop + index,
                cells: cells,
                isWrapped: line.isWrapped)
        }
        return TerminalContentSnapshot(
            inputState: inputStateSnapshotLocked(),
            bufferKind: source === altBuffer ? .alt : .normal,
            dimensions: dimensions,
            capturedRange: (source.linesTop + start)..<(source.linesTop + end),
            liveTopRow: source.linesTop + liveStart,
            rows: copiedRows,
            cursorRow: source.linesTop + source.yBase + source.y,
            cursorColumn: source.x,
            palette: ansiColors,
            foregroundColor: foregroundColor,
            backgroundColor: backgroundColor)
    }

    /// Copies a region of a buffer, with its palette and the input state,
    /// under one terminal lock.
    ///
    /// Do not call this method while you hold ``terminalLock`` or from a
    /// terminal delegate callback that already holds it.
    ///
    /// This is a pure inspection snapshot: it does not mutate render damage
    /// state. `region` selects the rows: ``TerminalContentRegion/all`` copies
    /// every retained row, with one `String` for each cell, while it holds the
    /// lock. `buffer` selects the normal or alternate buffer regardless of
    /// which one is displayed. It intentionally omits images and hyperlinks; use
    /// render/graphics snapshots when a renderer needs those details.
    public func contentSnapshot(region: TerminalContentRegion,
                                buffer: BufferKind = .active) -> TerminalContentSnapshot {
        terminalLock.withLock { contentSnapshotLocked(region: region, buffer: buffer) }
    }
}
