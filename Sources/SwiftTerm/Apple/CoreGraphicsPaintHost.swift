//
//  CoreGraphicsPaintHost.swift
//  SwiftTerm
//
//  The view state that the Core Graphics snapshot painter reads.
//
//  `drawTerminalContents` and its helpers are an extension of this protocol,
//  not of `TerminalView`, so that a view without a local `Terminal` (see
//  `TerminalRenderView`) can paint snapshots with the same code.
//

#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import CoreGraphics
import CoreText

@MainActor
protocol CoreGraphicsPaintHost: AnyObject {
#if os(macOS)
    var cellDimension: TerminalView.CellDimension! { get }
    var fontSmoothing: Bool { get }
#else
    var cellDimension: TerminalView.CellDimension { get }
    var selectionHandleColor: TTColor { get }
    /// The first buffer row that the painter draws (iOS). The painter draws
    /// in the coordinates that `bufferOffset` gives to `drawTerminalContents`.
    func firstPaintedRow (snapshot: TerminalSnapshot) -> Int
#endif
    var fontSet: TerminalView.FontSet { get }
    var bounds: CGRect { get }
    var frame: CGRect { get }
    var antiAliasCustomBlockGlyphs: Bool { get }
    /// The default foreground color, used for underlines without a color.
    var effectiveNativeForegroundColor: TTColor { get }
    var coreGraphicsRenderCache: CoreGraphicsRenderCache { get }
    var textBuilder: SnapshotTextBuilder { get }
    nonisolated var kittyPlacementImageCache: Locked<[KittyPlacementImageKey: TTImage]> { get }

    func backingScaleFactor () -> CGFloat
    func getImageScale () -> CGFloat

    /// Captures the per-frame view state; nil when the view cannot draw yet.
    func captureFrameViewState () -> FrameViewState?

    /// Calls `body` with the snapshot of the current frame.
    func withSnapshotForDrawing (viewState: FrameViewState,
                                 _ body: (TerminalSnapshot, SnapshotRenderContext) -> Void)

    /// Called once for each Core Graphics frame (diagnostics).
    func didDrawCoreGraphicsFrame ()
}

/// A view that shows a `CaretView` for its snapshot cursor.
@MainActor
protocol CaretHost: CoreGraphicsPaintHost {
    /// Whether the caret shows as focused (filled and blinking).
    var hasFocus: Bool { get }
}

extension TerminalView: CoreGraphicsPaintHost {
    func didDrawCoreGraphicsFrame () {
        diagnosticsState.withLock { $0.renders += 1 }
    }

    func withSnapshotForDrawing (viewState: FrameViewState,
                                 _ body: (TerminalSnapshot, SnapshotRenderContext) -> Void) {
        renderOwner.withSnapshotForDrawing(viewState: viewState, body)
    }
}

#if os(macOS)
extension TerminalView: CaretHost {}
#else
extension TerminalView: CaretHost {
    var hasFocus: Bool { isFirstResponder }

    func firstPaintedRow (snapshot: TerminalSnapshot) -> Int {
        // The scroll view is kept in sync with yDisp (contentOffset.y ==
        // yDisp * cellHeight); see drawTerminalContents.
        Int(contentOffset.y / cellDimension.height)
    }
}
#endif

#endif
#endif // !SWIFTTERM_EMBEDDED
