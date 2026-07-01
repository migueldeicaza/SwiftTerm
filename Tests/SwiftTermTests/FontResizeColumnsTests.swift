//
//  FontResizeColumnsTests.swift
//  SwiftTerm
//
//  Regression tests ensuring that after a font change the terminal content
//  stays clear of the scroller, i.e. the recomputed geometry reserves the
//  scroller width just like the live window-resize path does.
//

#if os(macOS)
import Foundation
import Testing
import AppKit
@testable import SwiftTerm

final class FontResizeColumnsTests {
    /// The core invariant: after a font change the rendered columns must fit
    /// within the area that is not covered by the scroller. If `resetFont`
    /// sized the terminal from the raw frame width, the right-most columns
    /// would be drawn underneath the scroller and become hidden.
    @Test func testFontChangeKeepsContentClearOfScroller() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        let view = TerminalView(frame: frame)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let renderedWidth = CGFloat(view.getTerminal().cols) * view.cellDimension.width
        let usableWidth = view.getEffectiveWidth(size: frame.size)

        // Content must not extend into the reserved scroller strip.
        #expect(renderedWidth <= usableWidth)
        // Sanity: the scroller actually reserves space in this configuration,
        // so the test is exercising a non-trivial case.
        #expect(usableWidth < frame.width)
    }

    /// The font-change path (`resetFont`) and the live-resize path
    /// (`processSizeChange`) must agree on the column count for a given frame,
    /// so zooming the font in and back out never drifts the column count.
    @Test func testFontChangeColumnsMatchResizePath() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        let view = TerminalView(frame: frame)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let colsAfterFontChange = view.getTerminal().cols
        view.processSizeChange(newSize: frame.size)
        let colsAfterResize = view.getTerminal().cols

        #expect(colsAfterFontChange == colsAfterResize)
    }
}
#endif
