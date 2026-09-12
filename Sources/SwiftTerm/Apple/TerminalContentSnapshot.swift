#if os(macOS) || os(iOS) || os(visionOS) || os(macCatalyst)
/// Copied input modes and dimensions, without copying terminal contents.
public struct TerminalInputStateSnapshot: Sendable {
    public let dimensions: TerminalDimensions
    public let isAlternateBuffer: Bool
    public let applicationCursor: Bool
    public let mouseMode: Terminal.MouseMode
    public let keyboardEnhancementFlags: KittyKeyboardFlags
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
}

/// A copied row with a scroll-invariant row number.
public struct TerminalContentRowSnapshot: Sendable, Equatable {
    public let absoluteRow: Int
    public let cells: [TerminalCellSnapshot]

    /// Right-trimmed text, preserving null cells (including wide-cell tails)
    /// and every scalar of each terminal grapheme. No styling is encoded.
    /// Computed from copied cells only when requested, outside the capture lock.
    public var text: String {
        // Packed cells use their first scalar as the logical code and widths
        // 0, 1 or 2. Match BufferLine's last-nonzero-code plus width rule.
        guard let last = cells.lastIndex(where: {
            ($0.text.unicodeScalars.first?.value ?? 0) != 0
        }) else { return "" }
        let end = last + min(cells[last].width, cells.count - last)
        return cells[..<end].reduce(into: "") { $0.append(contentsOf: $1.text) }
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
}
#endif
