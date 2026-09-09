//
//  FontResizeColumnsTests.swift
//  SwiftTerm
//
//  Regression tests for terminal columns and macOS scroller styles.
//

#if os(macOS)
import Foundation
import Testing
import AppKit
@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct FontResizeColumnsTests {
    @Test func testOverlayScrollerDoesNotRemoveColumns() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        let view = TerminalView(frame: frame)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let renderedWidth = CGFloat(view.withTerminal { $0.cols }) * view.cellDimension.width
        let usableWidth = view.getEffectiveWidth(size: frame.size)

        #expect(view.scrollerStyle == .overlay)
        #expect(usableWidth == frame.width)
        #expect(renderedWidth <= usableWidth)
        #expect(usableWidth - renderedWidth < view.cellDimension.width)
    }

    @Test func testLegacyScrollerReservesItsWidth() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        let view = TerminalView(frame: frame)
        view.scrollerStyle = .legacy
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let renderedWidth = CGFloat(view.withTerminal { $0.cols }) * view.cellDimension.width
        let usableWidth = view.getEffectiveWidth(size: frame.size)

        #expect(usableWidth < frame.width)
        #expect(renderedWidth <= usableWidth)
        #expect(usableWidth - renderedWidth < view.cellDimension.width)
    }

    @Test func testOverlayScrollerAppearsOnDemand() async throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let scroller = view.subviews.compactMap { $0 as? NSScroller }.first
        let indicator = view.subviews.first {
            $0.identifier?.rawValue == "SwiftTermOverlayScrollerIndicator"
        }

        #expect(scroller?.alphaValue == 0)
        #expect(scroller?.isHidden == true)
        #expect(scroller?.controlSize == .small)
        #expect(indicator?.isHidden == true)
        #expect(indicator?.isFlipped == true)
        view.applyScrollerState(.init(isEnabled: true, doubleValue: 0.5, knobProportion: 0.2))
        view.showOverlayScroller()
        #expect(scroller?.alphaValue == 0)
        #expect(scroller?.isHidden == false)
        #expect(indicator?.isHidden == false)
        #expect(indicator?.alphaValue == 1)
        view.layoutSubtreeIfNeeded()
        if let scroller {
            let point = CGPoint(x: scroller.frame.midX, y: scroller.frame.midY)
            #expect(view.hitTest(point) === scroller)
        }
        try await Task.sleep(for: .seconds(2))
        #expect(scroller?.isHidden == true)
        #expect(indicator?.isHidden == true)
    }

    @Test func testScrollerUsesTerminalScrollPositionDirectly() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let scroller = view.subviews.compactMap { $0 as? NSScroller }.first

        view.applyScrollerState(.init(isEnabled: true, doubleValue: 1, knobProportion: 0.2))
        #expect(scroller?.doubleValue == 1)
    }

    /// The font-change path (`resetFont`) and the live-resize path
    /// (`processSizeChange`) must agree on the column count for a given frame,
    /// so zooming the font in and back out never drifts the column count.
    @Test func testFontChangeColumnsMatchResizePath() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        let view = TerminalView(frame: frame)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let colsAfterFontChange = view.withTerminal { $0.cols }
        view.processSizeChange(newSize: frame.size)
        let colsAfterResize = view.withTerminal { $0.cols }

        #expect(colsAfterFontChange == colsAfterResize)
    }
}
#endif
