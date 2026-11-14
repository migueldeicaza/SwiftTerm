//
//  MarkedTextOverlayExtentTests.swift
//
//  The IME / dictation marked-text overlay paints its background behind the
//  marked text only, so text to the right of the caret stays visible while
//  composing in the middle of a line.
//
#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

@MainActor
final class MarkedTextOverlayExtentTests {

    @Test func testBackgroundCoversOnlyTheMarkedText() throws {
        let view = TerminalView.makeForMarkedTextTests()
        view.feed(text: "> existing text\r\u{1b}[2C")
        // The caret follows the cursor in the frame paths, which do not run without a window.
        view.updateCursorPosition()
        let caretX = view.caretView.frame.minX
        #expect(caretX > 0)
        view.setMarkedText("xy")
        let overlay = try #require(view.dictationOverlay)
        let rects = overlay.backgroundRects
        #expect(rects.count == 1)
        let rect = try #require(rects.first)
        #expect(abs(overlay.frame.minX + rect.minX - caretX) < 0.5)
        let width = rect.width
        #expect(width > 0)
        #expect(width <= 2 * view.cellDimension.width + 1)
    }

    /// Long dictation hypotheses wrap; the wrapped lines must hide the rows below.
    @Test func testWrappedLinesCoverTheFullWidth() throws {
        let view = TerminalView.makeForMarkedTextTests()
        view.setMarkedText(String(repeating: "dictation ", count: 12))
        let overlay = try #require(view.dictationOverlay)
        let rects = overlay.backgroundRects
        #expect(rects.count > 2)
        for rect in rects.dropLast() {
            #expect(abs(rect.width - overlay.frame.width) < 0.5)
        }
        let last = try #require(rects.last)
        #expect(last.width < overlay.frame.width)
    }

    /// A fallback-font glyph such as Hiragino ends inside a cell.
    @Test func testBackgroundEndsOnACellBoundary() throws {
        let view = TerminalView.makeForMarkedTextTests()
        view.feed(text: "> existing text\r\u{1b}[2C")
        view.updateCursorPosition()
        view.setMarkedText("あいう")
        let overlay = try #require(view.dictationOverlay)
        let last = try #require(overlay.backgroundRects.last)
        let cells = (overlay.frame.minX + last.maxX) / view.cellDimension.width
        #expect(abs(cells - cells.rounded()) < 0.01)
    }
}
#endif
