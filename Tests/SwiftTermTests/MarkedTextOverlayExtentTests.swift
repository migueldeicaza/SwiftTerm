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
        #expect(abs(rect.width - 2 * view.cellDimension.width) < 0.5)
    }

    /// Long dictation hypotheses wrap; the wrapped lines must hide the rows below,
    /// such as a TUI's border or status line, including the last one.
    /// Line 1 starts at the caret, and every later line at the first column.
    @Test func testWrappedLinesCoverTheFullWidth() throws {
        let view = TerminalView.makeForMarkedTextTests()
        view.feed(text: "> existing text\r\u{1b}[2C")
        view.updateCursorPosition()
        let caretX = view.caretView.frame.minX
        let cols = view.withTerminal { $0.cols }
        // Fills the rest of the caret's row and the next row, and ends 3 columns into the row after.
        view.setMarkedText(String(repeating: "x", count: cols - 2 + cols + 3))
        let overlay = try #require(view.dictationOverlay)
        let rects = overlay.backgroundRects
        #expect(rects.count == 3)
        let first = try #require(rects.first)
        #expect(abs(overlay.frame.minX + first.minX - caretX) < 0.5)
        #expect(abs(first.maxX - overlay.frame.width) < 0.5)
        #expect(abs(rects[1].minX) < 0.5)
        #expect(abs(rects[1].width - overlay.frame.width) < 0.5)
        let last = try #require(rects.last)
        #expect(abs(last.minX) < 0.5)
        #expect(abs(last.width - overlay.frame.width) < 0.5)
    }

    /// One cell of marked text over a wide character covers both of its columns,
    /// so no half of the character shows next to the text.
    @Test func testBackgroundCoversAWideCharacterAfterTheMarkedText() throws {
        let view = TerminalView.makeForMarkedTextTests()
        view.feed(text: "> 日本語\r\u{1b}[2C")
        view.updateCursorPosition()
        view.setMarkedText("k")
        let overlay = try #require(view.dictationOverlay)
        let last = try #require(overlay.backgroundRects.last)
        let cellWidth = view.cellDimension.width
        #expect(abs(overlay.frame.minX + last.minX - 2 * cellWidth) < 0.5)
        #expect(abs(overlay.frame.minX + last.maxX - 4 * cellWidth) < 0.5)
    }

    /// Dictation can put a newline in the marked text. The caret's row then
    /// covers its text only, and the line after the newline, which sits on
    /// another terminal row, covers the full width.
    @Test func testANewlineEndsTheCaretRowAtItsText() throws {
        let view = TerminalView.makeForMarkedTextTests()
        view.feed(text: "> existing text\r\u{1b}[2C")
        view.updateCursorPosition()
        view.setMarkedText("ab\ncd")
        let overlay = try #require(view.dictationOverlay)
        let rects = overlay.backgroundRects
        #expect(rects.count == 2)
        let cellWidth = view.cellDimension.width
        let first = try #require(rects.first)
        #expect(abs(overlay.frame.minX + first.minX - 2 * cellWidth) < 0.5)
        #expect(abs(overlay.frame.minX + first.maxX - 4 * cellWidth) < 0.5)
        let last = try #require(rects.last)
        #expect(abs(overlay.frame.minX + last.minX) < 0.5)
        #expect(abs(last.width - overlay.frame.width) < 0.5)
    }
}
#endif
