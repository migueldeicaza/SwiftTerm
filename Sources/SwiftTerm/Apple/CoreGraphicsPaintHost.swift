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
    var contentOffset: CGPoint { get }
    var selectionHandleColor: TTColor { get }
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

#if os(macOS)
/// A view that shows a `CaretView` for its snapshot cursor.
@MainActor
protocol CaretHost: CoreGraphicsPaintHost {
    var hasFocus: Bool { get }
}
#endif

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
#endif

#endif
#endif // !SWIFTTERM_EMBEDDED
