//
//  MarkedTextOverlayLayoutTests.swift
//
//  The IME / dictation marked-text overlay lays its characters on the terminal
//  grid, so composed text does not shift when it is committed.
//
#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

@MainActor
final class MarkedTextOverlayLayoutTests {

    private func makeView() -> TerminalView {
        TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
    }

    private func mark(_ view: TerminalView, _ text: String) {
        view.setMarkedText(text,
                           selectedRange: NSRange(location: (text as NSString).length, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// The x position of each glyph in the overlay, for text with one glyph per UTF-16 unit.
    private func glyphPositions(_ view: TerminalView) throws -> [CGFloat] {
        let overlay = try #require(view.subviews.lazy.compactMap { $0 as? DictationOverlayTextView }.first)
        let layoutManager = try #require(overlay.layoutManager)
        return (0..<layoutManager.numberOfGlyphs).map { glyph in
            layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
                + layoutManager.location(forGlyphAt: glyph).x
        }
    }

    private func steps(_ positions: [CGFloat]) -> [CGFloat] {
        zip(positions.dropFirst(), positions).map { $0 - $1 }
    }

    @Test func testNarrowCharactersTakeOneCellEach() throws {
        let view = makeView()
        mark(view, "abc")
        for step in steps(try glyphPositions(view)) {
            #expect(abs(step - view.cellDimension.width) < 0.5)
        }
    }

    /// CJK glyphs are narrower than the two cells the terminal gives them.
    @Test func testWideCharactersTakeTwoCellsEach() throws {
        let view = makeView()
        mark(view, "a日本b")
        let cell = view.cellDimension.width
        let expected: [CGFloat] = [cell, 2 * cell, 2 * cell]
        for (step, want) in zip(steps(try glyphPositions(view)), expected) {
            #expect(abs(step - want) < 0.5)
        }
    }
}
#endif
