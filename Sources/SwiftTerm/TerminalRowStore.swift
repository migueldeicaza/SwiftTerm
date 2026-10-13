//
//  TerminalRowStore.swift
//  SwiftTerm
//
//  Builds terminal rows from data that does not come from a local `Terminal`,
//  for example a terminal that runs in another process. The rows are ordinary
//  `BufferLine` values, so the snapshot renderers draw them with the same code
//  they use for a local terminal.
//
//  This file adds API only. It does not change how a `Terminal` parses or
//  stores output.
//

#if !SWIFTTERM_EMBEDDED

/// Creates and fills `BufferLine` values from an external source.
///
/// All lines that one store creates share its style and grapheme tables. The
/// store is not thread-safe: use it, and the lines it creates, under one lock
/// or on one thread.
///
/// The tables only grow. When ``isNearCapacity`` becomes true, create a new
/// store and rebuild the lines that you keep.
public final class TerminalRowStore {
    let arena: CellArena

    public init () {
        arena = CellArena()
    }

    /// Creates a line of `columns` empty cells.
    public func makeLine (columns: Int) -> BufferLine {
        BufferLine(cols: max(1, columns), fillData: nil, arena: arena)
    }

    /// How many more distinct attributes the store can hold. A cell whose
    /// attribute does not fit draws with the default attribute.
    public var remainingStyleCapacity: Int {
        max(0, arena.attributeLimit - arena.attributeCount)
    }

    /// How many more grapheme clusters (cells with more than one scalar) the
    /// store can hold.
    public var remainingGraphemeCapacity: Int {
        max(0, arena.graphemeLimit - arena.graphemeCount)
    }

    /// True when the style or grapheme table is more than 90% full.
    public var isNearCapacity: Bool {
        let styles: Int = arena.attributeCount * 10
        let styleLimit: Int = arena.attributeLimit * 9
        let graphemes: Int = arena.graphemeCount * 10
        let graphemeLimit: Int = arena.graphemeLimit * 9
        return styles >= styleLimit || graphemes >= graphemeLimit
    }

    /// Sets one cell.
    ///
    /// - Parameters:
    ///   - text: the grapheme cluster; nil or empty for a cell that was never
    ///     written (it renders as a blank and copies as nothing).
    ///   - width: 1 for a narrow cell, 2 for the first cell of a wide
    ///     character, 0 for the cell that follows a wide character.
    /// - Returns: false when `line` does not belong to this store or the cell
    ///   cannot be represented.
    @discardableResult
    public func setCell (_ line: BufferLine, column: Int, text: String?, width: Int,
                         attribute: Attribute, isProtected: Bool = false) -> Bool
    {
        guard line.cellArena === arena, column >= 0, column < line.count else { return false }
        let widthState: PackedCell.WidthState
        switch width {
        case 2: widthState = .wide
        case 0: widthState = .spacerTail
        default: widthState = .narrow
        }
        let packed: PackedCell?
        if let text, !text.isEmpty {
            let scalars = text.unicodeScalars
            if scalars.count == 1, let scalar = scalars.first {
                packed = arena.pack(attribute: attribute, scalar: scalar.value,
                                    widthState: widthState, isProtected: isProtected)
            } else {
                let style = arena.intern(attribute: attribute) ?? 0
                packed = arena.pack(styleID: style, scalars: scalars.map(\.value),
                                    widthState: widthState, isProtected: isProtected)
            }
        } else {
            packed = arena.pack(attribute: attribute, scalar: 0, widthState: widthState,
                                isProtected: isProtected)
        }
        guard let packed else { return false }
        line.setPackedCell(packed, at: column)
        return true
    }

    /// Sets the line-level state.
    public func setLineState (_ line: BufferLine, isWrapped: Bool,
                              renderMode: BufferLine.RenderLineMode = .single,
                              bidiState: BidiPresentationState = .default)
    {
        line.isWrapped = isWrapped
        line.renderMode = renderMode
        line.bidiState = bidiState
    }

    /// Makes every cell of `line` an empty cell.
    public func clear (_ line: BufferLine)
    {
        guard line.cellArena === arena else { return }
        let blank = arena.pack(attribute: CharData.defaultAttr, scalar: 0, widthState: .narrow)!
        for column in 0..<line.count {
            line.setPackedCell(blank, at: column)
        }
    }
}

extension Attribute {
    /// Creates an attribute from its parts, for hosts that build rows with
    /// ``TerminalRowStore``.
    public init (foreground: Color, background: Color, style: CharacterStyle,
                 underlineStyle: UnderlineStyle = .none, underlineColor: Color? = nil)
    {
        self.init(fg: foreground, bg: background, style: style,
                  underlineStyle: underlineStyle, underlineColor: underlineColor)
    }
}

#endif // !SWIFTTERM_EMBEDDED
