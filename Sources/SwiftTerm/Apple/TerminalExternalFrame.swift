//
//  TerminalExternalFrame.swift
//  SwiftTerm
//
//  The input of `TerminalRenderView`: terminal state that comes from a
//  source other than a local `Terminal`, for example a terminal that runs in
//  another process or on another machine.
//

#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation

/// A selection in the line numbering of a `TerminalExternalFrame`.
public struct TerminalExternalSelection: Equatable, Sendable {
    /// The anchor of the selection.
    public var start: Position
    /// The end of the selection. As with `SelectionService`, the highlight
    /// stops before this column, except that an end in the last column
    /// includes that column.
    public var end: Position

    public init (start: Position, end: Position) {
        self.start = start
        self.end = end
    }
}

/// The state of one frame.
///
/// Line numbers can use any increasing numbering (for example absolute line
/// numbers that never repeat). `topLine`, the cursor and the selection use
/// the same numbering.
public struct TerminalExternalFrame: Sendable {
    public var columns: Int
    public var rows: Int
    /// The line number of the first visible row.
    public var topLine: Int
    public var cursorLine: Int
    public var cursorColumn: Int
    public var cursorVisible: Bool
    public var cursorStyle: CursorStyle
    public var isAlternateBuffer: Bool
    /// The 256-color palette. Build it with `makePalette` from the theme.
    public var palette: [Color]
    public var selection: TerminalExternalSelection?

    public init (columns: Int, rows: Int, topLine: Int, cursorLine: Int, cursorColumn: Int,
                 cursorVisible: Bool, cursorStyle: CursorStyle, isAlternateBuffer: Bool,
                 palette: [Color], selection: TerminalExternalSelection? = nil)
    {
        self.columns = columns
        self.rows = rows
        self.topLine = topLine
        self.cursorLine = cursorLine
        self.cursorColumn = cursorColumn
        self.cursorVisible = cursorVisible
        self.cursorStyle = cursorStyle
        self.isAlternateBuffer = isAlternateBuffer
        self.palette = palette
        self.selection = selection
    }

    /// Builds the 256-color palette from the 16 ANSI colors, as a local
    /// `Terminal` does with `installPalette`. The defaults match a `Terminal`
    /// created with `TerminalOptions.default`.
    public static func makePalette (ansiColors: [Color]? = nil,
                                    strategy: Ansi256PaletteStrategy = TerminalOptions.default.ansi256PaletteStrategy,
                                    foreground: Color? = nil,
                                    background: Color? = nil) -> [Color]
    {
        let initial = ansiColors?.count == 16 ? ansiColors! : Color.terminalAppColors
        return Color.setupDefaultAnsiColors(initialColors: initial, strategy: strategy,
                                            backgroundColor: background,
                                            foregroundColor: foreground)
    }
}

/// Provides frames to a `TerminalRenderView`.
@MainActor
public protocol TerminalExternalFrameSource: AnyObject {
    /// Called on the main thread once for each frame that the view draws.
    ///
    /// Call `body` once with the frame, the store that owns the lines, and a
    /// function that returns the line for a line number, or nil when the
    /// line is not available (it then draws blank). Hold the lock that
    /// protects the store and its lines while `body` runs.
    func withFrame (_ body: (TerminalExternalFrame, TerminalRowStore, (Int) -> BufferLine?) -> Void)
}

#endif
#endif // !SWIFTTERM_EMBEDDED
