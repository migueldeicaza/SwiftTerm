//
//  TerminalRenderer.swift
//
//  Protocol abstracting the terminal rendering layer so that different
//  backends (CoreGraphics, Metal, etc.) can be swapped in.
//
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import CoreGraphics

/// Dimensions of a single terminal cell used during rendering.
public struct CellDimensions {
    public let width: CGFloat
    public let height: CGFloat
    public let descent: CGFloat
    public let leading: CGFloat

    public init(width: CGFloat, height: CGFloat, descent: CGFloat, leading: CGFloat) {
        self.width = width
        self.height = height
        self.descent = descent
        self.leading = leading
    }
}

/// Protocol abstracting terminal rendering (CoreGraphics, Metal, etc.).
public protocol TerminalRenderer: AnyObject {
    /// Called once to set up the renderer with the terminal view.
    func setup(view: TerminalView)

    /// Perform the actual rendering into the given CoreGraphics context.
    func draw(
        in context: CGContext,
        dirtyRect: CGRect,
        cellDimensions: CellDimensions,
        bufferOffset: Int
    )

    /// Handle terminal resize.
    func resize(cols: Int, rows: Int, cellDimensions: CellDimensions)

    /// Handle color scheme changes.
    func colorsChanged()

    /// Handle font changes.
    func fontChanged()

    /// Invalidate all cached rendering data.
    func invalidateAll()
}

/// Default implementations so conformers only need to override what they care about.
public extension TerminalRenderer {
    func resize(cols: Int, rows: Int, cellDimensions: CellDimensions) {}
    func colorsChanged() {}
    func fontChanged() {}
    func invalidateAll() {}
}
#endif
