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

    private func makeView() -> TerminalView {
        TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
    }

    private func mark(_ view: TerminalView, _ text: String) {
        view.setMarkedText(text,
                           selectedRange: NSRange(location: (text as NSString).length, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @Test func testBackgroundCoversOnlyTheMarkedText() throws {
        let view = makeView()
        view.feed(text: "> existing text\r\u{1b}[2C")
        mark(view, "xy")
        let overlay = try #require(view.subviews.lazy.compactMap { $0 as? DictationOverlayTextView }.first)
        let rects = overlay.backgroundRects
        #expect(rects.count == 1)
        let width = try #require(rects.first).width
        #expect(width > 0)
        #expect(width <= 2 * view.cellDimension.width + 1)
        #expect(width < overlay.frame.width / 2)
    }
}
#endif
