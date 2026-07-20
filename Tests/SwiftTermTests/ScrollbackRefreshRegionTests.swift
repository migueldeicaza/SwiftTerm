//
//  ScrollbackRefreshRegionTests.swift
//  SwiftTerm
//
//  Regression tests for the dirty-region math in updateDisplay: the update
//  range reported by the terminal is relative to the live screen (yBase),
//  while the view displays rows starting at yDisp. When the user has
//  scrolled back, the invalidated rect must follow the rows to where they
//  are actually displayed, otherwise newly echoed output stays invisible
//  until something forces a full redraw.
//

#if os(macOS)
import Foundation
import Testing
import AppKit
@testable import SwiftTerm

/// Records every rect passed to `setNeedsDisplay(_:)` so tests can assert
/// which parts of the view an update actually invalidated.
final class InvalidationRecordingTerminalView: TerminalView {
    var recordedRects: [CGRect] = []

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        recordedRects.append(invalidRect)
        super.setNeedsDisplay(invalidRect)
    }
}

final class ScrollbackRefreshRegionTests {

    /// Builds a terminal view whose buffer has plenty of scrollback and whose
    /// display is at the bottom (yDisp == yBase).
    private func makeView() -> (InvalidationRecordingTerminalView, Terminal) {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        let view = InvalidationRecordingTerminalView(frame: frame)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let terminal = view.getTerminal()
        for i in 0..<(terminal.rows + 30) {
            view.feed(text: "line \(i)\r\n")
        }
        return (view, terminal)
    }

    /// Center of the given view row (0 = top of the viewport) in view
    /// coordinates, suitable for containment checks against dirty rects.
    private func midpoint(ofViewRow row: Int, in view: TerminalView) -> CGPoint {
        CGPoint(x: view.frame.width / 2,
                y: view.frame.height - (CGFloat(row) + 0.5) * view.cellDimension.height)
    }

    private func covered(_ rects: [CGRect], _ point: CGPoint) -> Bool {
        rects.contains { $0.contains(point) }
    }

    /// Scrolled to the bottom, the update range maps 1:1 onto view rows —
    /// the pre-existing behavior must not change.
    @Test func testInvalidationAtBottomIsUntranslated() {
        let (view, terminal) = makeView()
        let buffer = terminal.buffer
        #expect(terminal.rows > 8)
        #expect(buffer.yBase > 5)
        #expect(buffer.yDisp == buffer.yBase)

        terminal.clearUpdateRange()
        view.recordedRects.removeAll()
        terminal.updateRange(3)
        view.updateDisplay(notifyAccessibility: false)

        #expect(covered(view.recordedRects, midpoint(ofViewRow: 3, in: view)))
    }

    /// The core regression: with the view scrolled back N rows, a change on
    /// live-screen row r is displayed on view row r + N, and that is the row
    /// that must be invalidated — not view row r, which shows unchanged
    /// scrollback.
    @Test func testInvalidationFollowsRowsWhenScrolledBack() {
        let (view, terminal) = makeView()
        let buffer = terminal.buffer
        let scrollOffset = 2
        view.scrollTo(row: buffer.yBase - scrollOffset, notifyAccessibility: false)
        #expect(buffer.yDisp == buffer.yBase - scrollOffset)

        terminal.clearUpdateRange()
        view.recordedRects.removeAll()
        terminal.updateRange(3)
        view.updateDisplay(notifyAccessibility: false)

        // The changed row is displayed scrollOffset rows lower.
        #expect(covered(view.recordedRects, midpoint(ofViewRow: 3 + scrollOffset, in: view)))
        // The untranslated position shows unchanged scrollback; repainting it
        // instead of the real row is exactly the bug this guards against.
        #expect(!covered(view.recordedRects, midpoint(ofViewRow: 3, in: view)))
    }

    /// A change on a live-screen row that has been pushed below the viewport
    /// by scrolling back must not invalidate anything: nothing visible
    /// changed, and scrolling back down repaints the whole view anyway.
    @Test func testRowsBelowViewportAreSkippedWhenScrolledBack() {
        let (view, terminal) = makeView()
        let buffer = terminal.buffer
        view.scrollTo(row: buffer.yBase - 5, notifyAccessibility: false)

        terminal.clearUpdateRange()
        view.recordedRects.removeAll()
        terminal.updateRange(terminal.rows - 1)
        view.updateDisplay(notifyAccessibility: false)

        #expect(view.recordedRects.isEmpty)
    }

    /// A full-screen refresh means "repaint everything visible", so it must
    /// cover the whole viewport even while scrolled back (updateFullScreen and
    /// friends are used for palette changes and the like, which also affect
    /// the visible scrollback).
    @Test func testFullScreenRefreshCoversViewportWhenScrolledBack() {
        let (view, terminal) = makeView()
        let buffer = terminal.buffer
        view.scrollTo(row: buffer.yBase - 2, notifyAccessibility: false)

        terminal.clearUpdateRange()
        view.recordedRects.removeAll()
        terminal.refresh(startRow: 0, endRow: terminal.rows - 1)
        view.updateDisplay(notifyAccessibility: false)

        #expect(covered(view.recordedRects, midpoint(ofViewRow: 0, in: view)))
        #expect(covered(view.recordedRects, midpoint(ofViewRow: terminal.rows - 1, in: view)))
    }
}
#endif
