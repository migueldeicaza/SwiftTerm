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
    /// The 256 palette entries in force when the copy was made, so indexed
    /// cell colors keep their appearance after the palette changes.
    public let palette: [Color]
    /// The colors cells with ``Attribute/Color/defaultColor`` resolve to.
    public let foregroundColor: Color
    public let backgroundColor: Color

    public init(
        inputState: TerminalInputStateSnapshot,
        bufferKind: Terminal.BufferKind = .normal,
        capturedRange: Range<Int>,
        liveTopRow: Int,
        rows: [TerminalContentRowSnapshot],
        palette: [Color] = [],
        foregroundColor: Color = Color.defaultForeground,
        backgroundColor: Color = Color.defaultBackground
    ) {
        self.inputState = inputState
        self.bufferKind = bufferKind == .alt ? .alt : .normal
        self.capturedRange = capturedRange
        self.liveTopRow = liveTopRow
        self.rows = rows
        self.palette = palette
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
    }
}

extension TerminalContentSnapshot {
    /// The copied rows as text with SGR sequences, ready to feed into another
    /// terminal of the same width.
    ///
    /// Every attribute is re-encoded with ``Attribute/sgrParameters()``,
    /// including dim, italic, strikethrough, underline styles and underline
    /// colors. Wide characters are emitted once and their continuation cells
    /// are skipped. Cells nothing was written to stay that way: runs of them
    /// are stepped over with a cursor move, and runs that carry a background
    /// are erased into place with `ECH`, so the receiving buffer keeps the
    /// same blank cells and the same colored blanks instead of spaces. Rows
    /// end with `CR LF` unless the next row is a soft-wrapped continuation,
    /// in which case the row is filled to the terminal width and left to wrap
    /// on its own; trailing blank cells of the other rows are dropped. The
    /// output ends with a reset and no line break, so the receiving cursor
    /// stays on the last row.
    ///
    /// This restores contents only. Cursor position, modes, margins and the
    /// active buffer are not part of the snapshot; replaying a live byte
    /// stream after the export is the host's responsibility.
    public func ansiRepresentation() -> String {
        let reset = Attribute.empty.sgrParameters()
        var result = "\u{1b}[" + reset + "m"
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
            let cells = row.cells
            var end = cells.count
            if !continues {
                while end > 0, cells[end - 1].isBlank, !cells[end - 1].attribute.paintsBackground {
                    end -= 1
                }
            }
            var cursor = 0
            var pending = 0
            var column = 0
            while column < end {
                let cell = cells[column]
                column += 1
                guard cell.width > 0 else { continue }
                if cell.isBlank, !cell.attribute.paintsBackground {
                    pending += cell.width
                    continue
                }
                if pending > 0 {
                    result += "\u{1b}[\(pending)C"
                    cursor += pending
                    pending = 0
                }
                select(cell.attribute)
                if cell.isBlank {
                    var run = cell.width
                    while column < end, cells[column].width > 0, cells[column].isBlank,
                          cells[column].attribute == cell.attribute {
                        run += cells[column].width
                        column += 1
                    }
                    // A cursor move cannot go past the last column, so a run
                    // that reaches it on a wrapping row ends with a written
                    // space to leave the cursor pending a wrap.
                    let written = continues && cursor + run == width ? 1 : 0
                    if run - written > 0 {
                        result += "\u{1b}[\(run - written)X\u{1b}[\(run - written)C"
                    }
                    if written > 0 {
                        result += " "
                    }
                    cursor += run
                } else {
                    result += cell.text
                    cursor += cell.width
                }
            }
            if continues {
                let remaining = width - cursor
                let nextStartsWide = rows[index + 1].cells.first { $0.width > 0 }?.width == 2
                // One free column before a wide character is the wrap the
                // terminal does on its own; anything else needs written
                // spaces so the cursor ends up pending a wrap.
                if remaining > 0, !(remaining == 1 && nextStartsWide) {
                    select(.empty)
                    result += String(repeating: " ", count: remaining)
                }
            } else if index + 1 < rows.count {
                // The line feed may scroll, and a scrolled-in row is filled
                // with the current background: reset first so it stays blank.
                select(.empty)
                result += "\r\n"
            }
        }
        if currentSgr != reset {
            result += "\u{1b}[" + reset + "m"
        }
        return result
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
                               kind: BufferKind = .active) -> TerminalContentSnapshot {
        terminalLock.preconditionLocked()
        let source = bufferFromKind(kind: kind)
        let count = source.lines.count
        let screenRows = min(max(0, rows), count)
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
            let width = min(cols, line.count)
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
            capturedRange: (source.linesTop + start)..<(source.linesTop + end),
            liveTopRow: source.linesTop + liveStart,
            rows: copiedRows,
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
    /// state. By default it copies every retained row of the active buffer;
    /// `kind` selects the normal or alternate buffer regardless of which one
    /// is displayed. It intentionally omits images and hyperlinks; use
    /// render/graphics snapshots when a renderer needs those details.
    public func contentSnapshot(region: TerminalContentRegion = .all,
                                kind: BufferKind = .active) -> TerminalContentSnapshot {
        terminalLock.withLock { contentSnapshotLocked(region: region, kind: kind) }
    }
}
