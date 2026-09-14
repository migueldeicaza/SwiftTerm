/// Selects the rows copied into a portable render snapshot.
public enum RenderSnapshotScope: Sendable { case dirty, full }

public enum RenderSnapshotDirtyKind: UInt32, Sendable { case clean = 0, partial = 1, full = 2 }

/// Inclusive row endpoints. Normal ranges use viewport coordinates. Scroll
/// ranges use buffer coordinates and can be outside the viewport.
public struct RenderSnapshotRange: Equatable, Sendable {
    public let startY: Int
    public let endY: Int
}

/// Width role of a cell. `PackedCell` is internal, so the snapshot keeps a
/// public copy of its width state.
public enum RenderSnapshotWidthState: Sendable {
    case narrow, wide, spacerTail, spacerHead

    init(_ state: PackedCell.WidthState) {
        switch state {
        case .narrow: self = .narrow
        case .wide: self = .wide
        case .spacerTail: self = .spacerTail
        case .spacerHead: self = .spacerHead
        }
    }
}

public struct RenderSnapshotCursor: Equatable, Sendable {
    public let x: Int
    /// Viewport row, clamped to the visible grid even when the cursor is hidden.
    public let y: Int
    /// True when cursor display is disabled or its row is outside the viewport.
    public let hidden: Bool
    public let style: CursorStyle
    /// The selected cursor style or DEC cursor blink mode enables blink.
    public let blink: Bool
}

public struct RenderSnapshotCell: Sendable {
    /// Complete grapheme text. Empty cells and width-zero cells have no text.
    public let text: String
    public let width: Int8
    public let widthState: RenderSnapshotWidthState
    public let attribute: Attribute
    public let isProtected: Bool
    public let semanticContent: SemanticContent
    /// An optional identity only. This value does not retain the payload.
    public let payloadID: UInt16?
}

public struct RenderSnapshotRow: Sendable {
    public let y: Int
    /// True if this row continues the previous row.
    public let isWrapped: Bool
    /// True if the next buffer row continues this row.
    public let wrapsToNext: Bool
    public let renderMode: BufferLine.RenderLineMode
    public let cells: [RenderSnapshotCell]
}

/// An atomic, owned copy of terminal render state. Colors and cell attributes
/// retain their semantic values; a renderer resolves them after the copy.
/// `Color` values are immutable, so the copy shares them with the terminal.
public struct TerminalRenderSnapshot: Sendable {
    public let cols: Int
    public let rows: Int
    public let isAlternateScreen: Bool
    public let dirtyKind: RenderSnapshotDirtyKind
    public let dirtyRange: RenderSnapshotRange?
    public let scrollDirtyRange: RenderSnapshotRange?
    public let foregroundColor: Color
    public let backgroundColor: Color
    public let cursorColor: Color?
    public let palette: [Color]
    public let reverseVideo: Bool
    public let synchronizedOutputActive: Bool
    public let cursor: RenderSnapshotCursor
    public let lines: [RenderSnapshotRow]
}

// Only metadata is retained between copies. Pending damage remains in Terminal
// until the host calls clearUpdateRange after it draws the frame.
struct PortableRenderMetadata: Equatable {
    let cols: Int
    let rows: Int
    let alternate: Bool
    let yDisp: Int
    let linesTop: Int
    let foreground: Color
    let background: Color
    let cursorColor: Color?
    let palette: [Color]
    let reverse: Bool
    let modes: [BufferLine.RenderLineMode]
}

// Cache owned cell values only. Line metadata is copied on each snapshot.
struct PortableRenderCellCache {
    let identity: BufferLine.RenderIdentity
    let generation: UInt64
    let cells: [RenderSnapshotCell]
}
