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

/// Selects a bounded region of the active buffer to copy.
public enum TerminalContentRegion: Sendable, Equatable {
    /// The currently displayed rows, including when scrolled into history.
    case viewport
    /// The live screen and up to this many preceding scrollback rows.
    /// Negative values request only the live screen.
    case history(maximumScrollbackRows: Int)
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
}

/// A copied row with a scroll-invariant row number.
public struct TerminalContentRowSnapshot: Sendable, Equatable {
    public let absoluteRow: Int
    /// True when this row is a soft-wrapped continuation of the preceding row.
    public let isWrapped: Bool
    public let cells: [TerminalCellSnapshot]

    public init(absoluteRow: Int, cells: [TerminalCellSnapshot], isWrapped: Bool = false) {
        self.absoluteRow = absoluteRow
        self.isWrapped = isWrapped
        self.cells = cells
    }

    /// Right-trimmed display text without internal NUL placeholders.
    ///
    /// Wide-cell continuation cells are omitted and unwritten cells inside the
    /// trimmed region are represented as spaces. No styling is encoded.
    /// Computed from copied cells only when requested, outside the capture lock.
    public var text: String {
        // Packed cells use their first scalar as the logical code and widths
        // 0, 1 or 2. Match BufferLine's last-nonzero-code plus width rule.
        guard let last = cells.lastIndex(where: {
            ($0.text.unicodeScalars.first?.value ?? 0) != 0
        }) else { return "" }
        let end = last + min(max(0, cells[last].width), cells.count - last)
        var result = ""
        for index in 0..<end {
            let cell = cells[index]
            let isNull = (cell.text.unicodeScalars.first?.value ?? 0) == 0
            guard isNull else {
                result.append(contentsOf: cell.text)
                continue
            }
            let followsWideCell = index > 0 && cells[index - 1].width == 2
            if cell.width == 0 || followsWideCell {
                continue
            }
            result.append(" ")
        }
        return result
    }
}

/// Contents and input state captured in one terminal-lock transaction.
///
/// Row numbers use the same scroll-invariant coordinate space as
/// `Terminal.getScrollInvariantLine(row:)`. Only `capturedRange` is copied;
/// it is not necessarily the complete history retained by the terminal.
public struct TerminalContentSnapshot: Sendable, Equatable {
    public let inputState: TerminalInputStateSnapshot
    public let capturedRange: Range<Int>
    public let liveTopRow: Int
    public let rows: [TerminalContentRowSnapshot]

    public init(
        inputState: TerminalInputStateSnapshot,
        capturedRange: Range<Int>,
        liveTopRow: Int,
        rows: [TerminalContentRowSnapshot]
    ) {
        self.inputState = inputState
        self.capturedRange = capturedRange
        self.liveTopRow = liveTopRow
        self.rows = rows
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

    /// Copies input modes and dimensions under one terminal lock.
    ///
    /// Do not call this method while you hold ``terminalLock`` or from a
    /// terminal delegate callback that already holds it.
    public func inputStateSnapshot() -> TerminalInputStateSnapshot {
        terminalLock.withLock { inputStateSnapshotLocked() }
    }

    func contentSnapshotLocked(region: TerminalContentRegion) -> TerminalContentSnapshot {
        terminalLock.preconditionLocked()
        let source = displayBuffer
        let count = source.lines.count
        let screenRows = min(max(0, rows), count)
        let liveStart = count - screenRows
        let start: Int
        let end: Int
        switch region {
        case .viewport:
            start = min(max(0, source.yDisp), count)
            end = start + min(screenRows, count - start)
        case .history(let maximumScrollbackRows):
            start = liveStart - min(max(0, maximumScrollbackRows), liveStart)
            end = count
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
            capturedRange: (source.linesTop + start)..<(source.linesTop + end),
            liveTopRow: source.linesTop + liveStart,
            rows: copiedRows)
    }

    /// Copies a bounded region and its input state under one terminal lock.
    ///
    /// Do not call this method while you hold ``terminalLock`` or from a
    /// terminal delegate callback that already holds it.
    ///
    /// This is a pure inspection snapshot: it does not mutate render damage
    /// state and can include bounded scrollback history. It intentionally omits
    /// images, hyperlinks, and palette values; use render/graphics snapshots
    /// when a renderer needs those details.
    public func contentSnapshot(region: TerminalContentRegion) -> TerminalContentSnapshot {
        terminalLock.withLock { contentSnapshotLocked(region: region) }
    }
}
