//
//  CoreGraphicsRenderer.swift
//
//  Default renderer that delegates to the existing CoreGraphics-based
//  drawing code in AppleTerminalView.
//
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import CoreGraphics

/// A thin wrapper around the existing CoreGraphics rendering in
/// ``TerminalView``.  It delegates ``draw(in:dirtyRect:cellDimensions:bufferOffset:)``
/// back to the view's ``drawTerminalContents(dirtyRect:context:bufferOffset:)`` method.
public class CoreGraphicsRenderer: TerminalRenderer {
    weak var view: TerminalView?

    public init() {}

    public func setup(view: TerminalView) {
        self.view = view
    }

    public func draw(
        in context: CGContext,
        dirtyRect: CGRect,
        cellDimensions: CellDimensions,
        bufferOffset: Int
    ) {
        view?.drawTerminalContents(dirtyRect: dirtyRect, context: context, bufferOffset: bufferOffset)
    }

    public func colorsChanged() {
        view?.resetCaches()
    }

    public func fontChanged() {
        view?.resetCaches()
    }

    public func invalidateAll() {
        view?.resetCaches()
    }
}
#endif
