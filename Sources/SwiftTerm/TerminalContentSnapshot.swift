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
    public let inputState: TerminalInputStateSnapshot
    /// The buffer the rows were copied from: `.normal` or `.alt`, never
    /// `.active`.
    public let bufferKind: Terminal.BufferKind
    public let capturedRange: Range<Int>
    public let liveTopRow: Int
    public let rows: [TerminalContentRowSnapshot]
    /// The cursor row of the copied buffer, in the coordinates of `absoluteRow`.
    public let cursorRow: Int
    /// The cursor column of the copied buffer.
    public let cursorColumn: Int
    /// The 256 palette entries in force when the copy was made, so indexed
    /// cell colors keep their appearance after the palette changes.
    public let palette: [Color]
    /// The palette the terminal derives from its installed colors and
    /// default colors; the entries of ``palette`` that differ were set by
    /// the application with `OSC 4`.
    public let defaultPalette: [Color]
    /// The colors cells with ``Attribute/Color/defaultColor`` resolve to.
    public let foregroundColor: Color
    public let backgroundColor: Color

    public init(
        inputState: TerminalInputStateSnapshot,
        bufferKind: Terminal.BufferKind = .normal,
        capturedRange: Range<Int>,
        liveTopRow: Int,
        rows: [TerminalContentRowSnapshot],
        cursorRow: Int = 0,
        cursorColumn: Int = 0,
        palette: [Color] = [],
        defaultPalette: [Color] = [],
        foregroundColor: Color = Color.defaultForeground,
        backgroundColor: Color = Color.defaultBackground
    ) {
        self.inputState = inputState
        self.bufferKind = bufferKind == .alt ? .alt : .normal
        self.capturedRange = capturedRange
        self.liveTopRow = liveTopRow
        self.rows = rows
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.palette = palette
        self.defaultPalette = defaultPalette
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
    }
}

extension TerminalContentSnapshot {
    /// The copied rows as text with SGR sequences, ready to feed into another
    /// terminal of the same width.
    ///
    /// The output starts with the default colors, when they are not
    /// SwiftTerm's stock ones, and the palette entries the application
    /// changed, as `OSC 10`, `OSC 11` and `OSC 4`, so indexed cells and the
    /// default colors keep their appearance in the receiving terminal.
    /// Every attribute is re-encoded with ``Attribute/sgrParameters()``,
    /// including dim, italic, strikethrough, underline styles and underline
    /// colors. Wide characters are emitted once and their continuation cells
    /// are skipped. Cells nothing was written to stay that way: runs of them
    /// are stepped over with a cursor move, and runs that carry a background
    /// are erased into place with `ECH`, so the receiving buffer keeps the
    /// same blank cells and the same colored blanks instead of spaces. Blank
    /// cells with a style that shows without text (inverse, underline,
    /// crossed out), which an erase cannot produce, become spaces that look
    /// the same.
    ///
    /// Rows end with `CR LF` unless the next row is a soft-wrapped
    /// continuation. Only a written character wraps the cursor and marks the
    /// next row as a continuation, and only a wide character does so without
    /// writing into the last column: a continued row ends with the cursor
    /// moved to its last column and an ideographic space (`U+3000`), which
    /// does not fit there, wraps and is erased from the start of the next
    /// row. Trailing blank cells of the other rows are dropped. The output
    /// ends with a reset and no line break, so the receiving cursor stays on
    /// the last row. The first copied row cannot be marked as a continuation
    /// of a row that was not copied.
    ///
    /// Two adjacent stored cells whose text the terminal would merge when
    /// written in sequence, such as a cell ending in a scalar with the
    /// Unicode `Prepend` property and the cell after it, are separated by a
    /// cursor move to the second cell's column, which starts a new spacing
    /// character; the test is the terminal's, with the pairs it leaves to
    /// segmentation counted as joining. A narrow cell in
    /// the last column whose text would widen it when written, which only
    /// autowrap being off can produce, is written with autowrap off, and
    /// autowrap is turned back on after it.
    ///
    /// This restores contents only. The export does not restore cursor
    /// position, modes, margins or the active buffer; replaying a live byte
    /// stream after the export is the host's responsibility.
    public func ansiRepresentation() -> String {
        let reset = Attribute.empty.sgrParameters()
        var result = colorSequences() + "\u{1b}[" + reset + "m"
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
        let width = inputState.dimensions.cols
        for (index, row) in rows.enumerated() {
            let continues = index + 1 < rows.count && rows[index + 1].isWrapped
            var cursor = 0
            var previous: TerminalExportPiece?
            for piece in exportPieces(of: row, width: width, continues: continues) {
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
            guard cell.width > 0, !cell.isBlank || cell.attribute.showsWhenBlank else { continue }
            if cell.isBlank {
                // An erase keeps only the background, so blank cells are
                // grouped by what an erase would leave. The half of a wide
                // character left when the other half is overwritten keeps
                // the character's attribute, which can carry a style that
                // shows on a blank cell; those are written as the spaces
                // that look the same.
                let attribute = cell.attribute.blankForm
                var run = cell.width
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
                let scalars = cell.text.unicodeScalars
                var text = cell.text
                if cell.width == 1, start == width - 1,
                   scalars.dropFirst().contains(where: TerminalExportPiece.widens) {
                    // A scalar that widens the cell it joins moves a cell in
                    // the last column to the next row instead, unless
                    // autowrap is off: only that leaves a narrow cell with
                    // such text, so the cell is written the same way.
                    text = "\u{1b}[?7l" + text + "\u{1b}[?7h"
                }
                pieces.append(TerminalExportPiece(
                    column: start, width: cell.width, attribute: cell.attribute,
                    text: text, lastCell: cell.text))
            }
        }
        return pieces
    }

    /// `OSC 10` and `OSC 11` when the default colors are not SwiftTerm's
    /// stock ones, then `OSC 4` for the palette entries the application
    /// changed. The default colors go first because a terminal that derives
    /// its palette from them rebuilds it when they change. A stock terminal
    /// produces nothing, so its export starts with the SGR reset.
    func colorSequences() -> String {
        var result = ""
        if foregroundColor != Color.defaultForeground {
            result += "\u{1b}]10;\(foregroundColor.formatAsXcolor())\u{7}"
        }
        if backgroundColor != Color.defaultBackground {
            result += "\u{1b}]11;\(backgroundColor.formatAsXcolor())\u{7}"
        }
        if palette.count == 256, defaultPalette.count == 256 {
            for (index, color) in palette.enumerated() where color != defaultPalette[index] {
                result += "\u{1b}]4;\(index);\(color.formatAsXcolor())\u{7}"
            }
        }
        return result
    }
}

/// One sequence of ``TerminalContentSnapshot/ansiRepresentation()``: a cell's
/// text, a run of styled spaces or an erase, with the columns it covers.
private struct TerminalExportPiece {
    let column: Int
    let width: Int
    let attribute: Attribute
    let text: String
    /// The text of the last cell the sequence writes; nil for an erase,
    /// which leaves cells the terminal never extends.
    let lastCell: String?

    /// True when writing `next` right after this piece would extend this
    /// piece's last cell instead of starting a cell of its own.
    func joins(_ next: TerminalExportPiece) -> Bool {
        guard let lastCell, let nextCell = next.lastCell, next.column == column + width else { return false }
        return TerminalExportPiece.joins(lastCell, nextCell.unicodeScalars.first!)
    }

    /// True when the terminal widens a narrow cell that `scalar` joins: a
    /// scalar with a column width, a spacing mark or the emoji presentation
    /// selector.
    static func widens(_ scalar: Unicode.Scalar) -> Bool {
        UnicodeUtil.columnWidth(rune: scalar) > 0
            || UnicodeUtil.isSpacingMarkWidth(scalar.value)
            || scalar.value == 0xFE0F
    }

    /// The test the terminal makes before it stores `scalar` after the cell
    /// with text `cell`. The pairs the terminal leaves to the standard
    /// library's segmentation count as joining: a cursor move they did not
    /// need costs four bytes, a missing one merges two cells.
    static func joins(_ cell: String, _ scalar: Unicode.Scalar) -> Bool {
        let previous = cell.unicodeScalars.last!.value
        let value = scalar.value
        if UnicodeUtil.isEmojiModifier(value) {
            return UnicodeUtil.isEmojiModifierBase(previous)
        }
        return UnicodeUtil.graphemeJoinNonEmojiModifier(
            previous: previous,
            previousProperties: UnicodeUtil.graphemeProperties(previous),
            incoming: value,
            incomingProperties: UnicodeUtil.graphemeProperties(value),
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
    func inputStateSnapshotLocked(dimensions: TerminalDimensions? = nil) -> TerminalInputStateSnapshot {
        terminalLock.preconditionLocked()
        return TerminalInputStateSnapshot(
            dimensions: dimensions ?? TerminalDimensions(cols: cols, rows: rows),
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
            start = min(max(0, range.lowerBound - source.linesTop), count)
            end = min(max(start, range.upperBound - source.linesTop), count)
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
            inputState: inputStateSnapshotLocked(dimensions: dimensions),
            bufferKind: source === altBuffer ? .alt : .normal,
            capturedRange: (source.linesTop + start)..<(source.linesTop + end),
            liveTopRow: source.linesTop + liveStart,
            rows: copiedRows,
            cursorRow: source.linesTop + source.yBase + source.y,
            cursorColumn: source.x,
            palette: ansiColors,
            defaultPalette: defaultAnsiColors,
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
    /// state. By default it copies every retained row of the active buffer;
    /// `buffer` selects the normal or alternate buffer regardless of which one
    /// is displayed. It intentionally omits images and hyperlinks; use
    /// render/graphics snapshots when a renderer needs those details.
    public func contentSnapshot(region: TerminalContentRegion = .all,
                                buffer: BufferKind = .active) -> TerminalContentSnapshot {
        terminalLock.withLock { contentSnapshotLocked(region: region, buffer: buffer) }
    }

    /// Copies the selected buffer. This overload accepts the `kind` label.
    public func contentSnapshot(region: TerminalContentRegion = .all,
                                kind: BufferKind) -> TerminalContentSnapshot {
        contentSnapshot(region: region, buffer: kind)
    }
}
