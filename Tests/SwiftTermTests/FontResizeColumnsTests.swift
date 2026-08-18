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
