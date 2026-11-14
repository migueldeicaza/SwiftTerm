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

    /// The x position of each character (grapheme cluster) in the overlay.
    private func characterPositions(_ view: TerminalView) throws -> [CGFloat] {
        let overlay = try #require(view.dictationOverlay)
        let layoutManager = try #require(overlay.layoutManager)
        let string = overlay.string as NSString
        var positions: [CGFloat] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length),
                                   options: .byComposedCharacterSequences) { _, range, _, _ in
            let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
            positions.append(layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
                             + layoutManager.location(forGlyphAt: glyph).x)
        }
        return positions
    }

    /// Checks that each character of `text` starts at the given column.
    private func expectColumns(_ text: String, _ columns: [Int],
                               sourceLocation: SourceLocation = #_sourceLocation) throws {
        let view = TerminalView.makeForMarkedTextTests()
        view.setMarkedText(text)
        let positions = try characterPositions(view)
        #expect(positions.count == columns.count, sourceLocation: sourceLocation)
        guard let start = positions.first else { return }
        let cell = view.cellDimension.width
        for (position, column) in zip(positions, columns) {
            #expect(abs(position - start - CGFloat(column) * cell) < 0.5,
                    "\(text): column \(column) at \(position - start), cell \(cell)",
                    sourceLocation: sourceLocation)
        }
    }

    @Test func testNarrowCharactersTakeOneCellEach() throws {
        try expectColumns("abc", [0, 1, 2])
    }

    /// CJK glyphs are narrower than the two cells the terminal gives them.
    @Test func testWideCharactersTakeTwoCellsEach() throws {
        try expectColumns("a日本b", [0, 1, 3, 5])
    }

    /// A kern on one half of a surrogate pair breaks the layout of the text after it.
    @Test func testCharactersOutsideTheBMPKeepTheirWidth() throws {
        try expectColumns("a𠮷b", [0, 1, 3])
    }

    /// A kern on a trailing combining mark has no effect.
    @Test func testDecomposedCharactersTakeOneCell() throws {
        try expectColumns("ae\u{301}b", [0, 1, 2])
    }
}
#endif
