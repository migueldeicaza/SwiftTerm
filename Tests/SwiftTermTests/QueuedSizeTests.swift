//
//  QueuedSizeTests.swift
//
//  A font change queues the grid's counts for the next frame, measured on the
//  frame the view has then. A later resize applies new counts at once; the
//  next frame must not put the old ones back.
//
#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
@Suite struct QueuedSizeTests {
    @Test func aResizeReplacesTheCountsAFontChangeQueued() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 560))
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let born = view.withTerminal { ($0.cols, $0.rows) }

        view.setFrameSize(NSSize(width: 663, height: 744))
        let resized = view.withTerminal { ($0.cols, $0.rows) }
        #expect(resized != born)

        view.frameTick()
        let afterFrame = view.withTerminal { ($0.cols, $0.rows) }
        #expect(afterFrame == resized)
    }

    /// On the render loop, a frame can take the queued counts and then wait
    /// for the terminal lock while main resizes at once. That frame must not
    /// put its old counts back, and must not report them.
    @Test func aFrameThatTookOldCountsDoesNotRestoreThem() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 560))
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let born = view.withTerminal { ($0.cols, $0.rows) }
        guard let viewState = view.captureFrameViewState() else {
            Issue.record("no frame view state")
            return
        }

        var resized = born
        let prepared = view.renderOwner.prepareFrame(viewState: viewState) {
            // The frame has the font change's counts now; resize in the gap.
            view.setFrameSize(NSSize(width: 663, height: 744))
            resized = view.withTerminal { ($0.cols, $0.rows) }
        }
        #expect(resized != born)
        #expect(prepared?.resizedTo == nil)
        let afterFrame = view.withTerminal { ($0.cols, $0.rows) }
        #expect(afterFrame == resized)
    }

    private final class DraggedTerminalView: TerminalView {
        var dragging = false
        override var inLiveResize: Bool { dragging }
    }

    /// A drag queues its counts for the next frame. A resize applied at once
    /// after it, for another frame, must not be undone by that frame.
    @Test func aResizeReplacesTheCountsALiveDragQueued() {
        let view = DraggedTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 560))
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.frameTick()

        view.dragging = true
        view.setFrameSize(NSSize(width: 500, height: 300))
        view.dragging = false
        view.setFrameSize(NSSize(width: 663, height: 744))
        let resized = view.withTerminal { ($0.cols, $0.rows) }

        view.frameTick()
        let afterFrame = view.withTerminal { ($0.cols, $0.rows) }
        #expect(afterFrame == resized)
    }

    /// A font change in a drag measures the current frame with the new cells.
    /// The next frame must keep those counts, not the drag's older ones.
    @Test func aFontChangeInADragKeepsItsCounts() {
        let view = DraggedTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 560))
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.frameTick()

        view.dragging = true
        view.setFrameSize(NSSize(width: 663, height: 744))
        view.font = NSFont.monospacedSystemFont(ofSize: 20, weight: .regular)
        let expected = (
            Int(view.getEffectiveWidth(size: view.frame.size) / view.cellDimension.width),
            Int(view.frame.height / view.cellDimension.height))

        view.frameTick()
        view.dragging = false
        let afterFrame = view.withTerminal { ($0.cols, $0.rows) }
        #expect(afterFrame == expected)
    }
}
#endif
