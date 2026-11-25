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

    /// Marked text at a caret in the last column covers that cell only, not the
    /// prompt to its left.
    @Test func testBackgroundCoversACaretInTheLastColumn() throws {
        let view = TerminalView.makeForMarkedTextTests()
        let cols = view.withTerminal { $0.cols }
        view.feed(text: String(repeating: "-", count: cols - 1))
        view.updateCursorPosition()
        view.setMarkedText("x")
        let overlay = try #require(view.dictationOverlay)
        let rects = overlay.backgroundRects
        #expect(rects.count == 1)
        let rect = try #require(rects.first)
        let cellWidth = view.cellDimension.width
        #expect(abs(overlay.frame.minX + rect.minX - CGFloat(cols - 1) * cellWidth) < 0.5)
        #expect(abs(rect.width - cellWidth) < 0.5)
        #expect(abs(overlay.frame.maxY - view.caretView.frame.maxY) < 0.5)
    }

    /// A wide character that does not fit at a caret in the last column starts on
    /// the next row. That row is not the caret's, so its background spans the
    /// full width, and the caret's row stays uncovered.
    @Test func testWideCharacterOnTheNextRowCoversTheFullWidth() throws {
        let view = TerminalView.makeForMarkedTextTests()
        let cols = view.withTerminal { $0.cols }
        view.feed(text: String(repeating: "-", count: cols - 1))
        view.updateCursorPosition()
        view.setMarkedText("日")
        let overlay = try #require(view.dictationOverlay)
        let rects = overlay.backgroundRects
        #expect(rects.count == 1)
        let rect = try #require(rects.first)
        #expect(abs(rect.minX) < 0.5)
        #expect(abs(rect.width - overlay.frame.width) < 0.5)
        #expect(abs(overlay.frame.maxY - view.caretView.frame.minY) < 0.5)
    }

    /// On the bottom row there is no row below the caret in the view, so text
    /// that goes to the next row shows on the caret's row, where the commit's
    /// scroll puts it, instead of below the view.
    @Test func testNextRowTextOnTheBottomRowStaysInTheView() throws {
        let view = TerminalView.makeForMarkedTextTests()
        let (cols, rows) = view.withTerminal { ($0.cols, $0.rows) }
        view.feed(text: String(repeating: "\r\n", count: rows - 1) + String(repeating: "-", count: cols - 1))
        view.updateCursorPosition()
        view.setMarkedText("日")
        let overlay = try #require(view.dictationOverlay)
        #expect(overlay.frame.minY >= view.bounds.minY - 0.5)
        #expect(abs(overlay.frame.maxY - view.caretView.frame.maxY) < 0.5)
        let rect = try #require(overlay.backgroundRects.first)
        #expect(abs(rect.minX) < 0.5)
        #expect(abs(rect.width - overlay.frame.width) < 0.5)
    }

    /// The IME puts its candidate window below `firstRect`, so when the text
    /// starts on the row below the caret, that row is the rect.
    @Test func testFirstRectIsTheNextRowWhenTheTextStartsThere() throws {
        let view = TerminalView.makeForMarkedTextTests()
        let cols = view.withTerminal { $0.cols }
        view.feed(text: String(repeating: "-", count: cols - 1))
        view.updateCursorPosition()
        view.setMarkedText("日")
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(view)
        let cell: CGSize = view.cellDimension
        let caret = view.caretView.frame
        let expected = window.convertToScreen(view.convert(
            NSRect(x: 0, y: caret.minY - cell.height, width: 2 * cell.width, height: cell.height), to: nil))
        let rect = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        #expect(abs(rect.minX - expected.minX) < 0.5)
        #expect(abs(rect.minY - expected.minY) < 0.5)
        #expect(abs(rect.width - expected.width) < 0.5)
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
