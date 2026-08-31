#if os(macOS) || os(iOS) || os(visionOS) || os(macCatalyst)
/// Copied input modes and dimensions, without copying terminal contents.
public struct TerminalInputStateSnapshot: Sendable {
    public let dimensions: TerminalDimensions
    public let isAlternateBuffer: Bool
    public let applicationCursor: Bool
    public let mouseMode: Terminal.MouseMode
    public let keyboardEnhancementFlags: KittyKeyboardFlags

    public init(dimensions: TerminalDimensions, isAlternateBuffer: Bool,
                applicationCursor: Bool, mouseMode: Terminal.MouseMode,
                keyboardEnhancementFlags: KittyKeyboardFlags) {
        self.dimensions = dimensions
        self.isAlternateBuffer = isAlternateBuffer
        self.applicationCursor = applicationCursor
        self.mouseMode = mouseMode
        self.keyboardEnhancementFlags = keyboardEnhancementFlags
    }
}

/// Selects a bounded region of the active buffer to copy.
public enum TerminalContentRegion: Sendable {
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
    /// Right-trimmed text, preserving null cells (including wide-cell tails)
    /// and every scalar of each terminal grapheme. No styling is encoded.
    public let text: String
    public let cells: [TerminalCellSnapshot]

    public init(absoluteRow: Int, text: String, cells: [TerminalCellSnapshot]) {
        self.absoluteRow = absoluteRow
        self.text = text
        self.cells = cells
    }
}

/// Contents and input state captured in one terminal-lock transaction.
///
/// Row numbers use the same scroll-invariant coordinate space as
/// `Terminal.getScrollInvariantLine(row:)`. Only `capturedRange` is copied;
/// it is not necessarily the complete history retained by the terminal.
public struct TerminalContentSnapshot: Sendable {
    public let inputState: TerminalInputStateSnapshot
    public let capturedRange: Range<Int>
    public let liveTopRow: Int
    public let rows: [TerminalContentRowSnapshot]

    public init(inputState: TerminalInputStateSnapshot, capturedRange: Range<Int>,
                liveTopRow: Int, rows: [TerminalContentRowSnapshot]) {
        self.inputState = inputState
        self.capturedRange = capturedRange
        self.liveTopRow = liveTopRow
        self.rows = rows
    }
}
#endif
