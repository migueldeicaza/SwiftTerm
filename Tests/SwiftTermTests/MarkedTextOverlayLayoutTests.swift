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

    /// The position of each character (grapheme cluster) in the overlay.
    private func characterPositions(_ view: TerminalView) throws -> [CGPoint] {
        let overlay = try #require(view.dictationOverlay)
        let layoutManager = try #require(overlay.layoutManager)
        let string = overlay.string as NSString
        var positions: [CGPoint] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length),
                                   options: .byComposedCharacterSequences) { _, range, _, _ in
            // A cluster's first glyph is not always its leftmost; Devanagari reorders the vowel sign of कि.
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let x = (glyphs.lowerBound..<glyphs.upperBound).map { glyph in
                layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
                    + layoutManager.location(forGlyphAt: glyph).x
            }.min() ?? .nan
            positions.append(CGPoint(x: x, y: line.minY))
        }
        return positions
    }

    /// Checks that each character of `text` starts at the given column.
    private func expectColumns(_ text: String, _ columns: [Int],
                               in view: TerminalView = TerminalView.makeForMarkedTextTests(),
                               sourceLocation: SourceLocation = #_sourceLocation) throws {
        view.setMarkedText(text)
        let positions = try characterPositions(view).map(\.x)
        #expect(positions.count == columns.count, sourceLocation: sourceLocation)
        guard let start = positions.first else { return }
        let cell = view.cellDimension.width
        for (position, column) in zip(positions, columns) {
            #expect(abs(position - start - CGFloat(column) * cell) < 0.5,
                    "\(text): column \(column) at \(position - start), cell \(cell)",
                    sourceLocation: sourceLocation)
        }
    }

    /// The terminal cell (row, column) where each character of `text` starts when
    /// it is marked with the caret in the first column.
    private func cells(_ text: String, in view: TerminalView) throws -> [(row: Int, column: Int)] {
        view.setMarkedText(text)
        let overlay = try #require(view.dictationOverlay)
        return try characterPositions(view).map { position in
            (row: Int((position.y / view.cellDimension.height).rounded()),
             column: Int(((overlay.frame.minX + position.x) / view.cellDimension.width).rounded()))
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

    /// Glyphs wider than their cells, such as emoji, must not push the text after them.
    @Test func testGlyphsWiderThanTheirCellsStayOnTheGrid() throws {
        try expectColumns("a😀b", [0, 1, 3])
        try expectColumns(String(repeating: "a", count: 30), Array(0..<30))
    }

    /// The terminal sizes a cell from its whole grapheme, not from the first scalar.
    @Test func testCharactersTakeTheColumnsOfTheirWholeGrapheme() throws {
        try expectColumns("a❤️b", [0, 1, 3])
        try expectColumns("aकिb", [0, 1, 3])
    }

    /// The terminal writes no cell for a zero-width character.
    @Test func testZeroWidthCharactersTakeNoCell() throws {
        try expectColumns("a\u{200B}b", [0, 1, 1])
    }

    /// The overlay reuses the advances it measured until the font changes.
    @Test func testCharactersStayOnTheGridAfterTheFontChanges() throws {
        let view = TerminalView.makeForMarkedTextTests()
        try expectColumns("a日本b", [0, 1, 3, 5], in: view)
        view.font = NSFont.monospacedSystemFont(ofSize: 24, weight: .regular)
        try expectColumns("a日本b", [0, 1, 3, 5], in: view)
    }

    /// A kern on a trailing combining mark has no effect.
    @Test func testDecomposedCharactersTakeOneCell() throws {
        try expectColumns("ae\u{301}b", [0, 1, 2])
    }

    /// The terminal wraps per character at its last column, not at a word boundary.
    @Test func testTextWrapsAtTheLastColumn() throws {
        let view = TerminalView.makeForMarkedTextTests()
        let cols = view.withTerminal { $0.cols }
        let cells = try cells(String(repeating: "x", count: cols - 2) + " yyyy", in: view)
        #expect(cells.count == cols + 3)
        #expect(cells[cols - 1] == (row: 0, column: cols - 1))
        #expect(cells[cols] == (row: 1, column: 0))
    }

    /// Puts the caret on the first row at `column`, after a prompt that fills the
    /// columns to its left, and marks `text`. Returns the terminal cell where each
    /// character of `text` shows, as (row below the caret's row, column).
    private func cellsAfterPrompt(_ text: String, caretColumn column: Int,
                                  in view: TerminalView) throws -> [(row: Int, column: Int)] {
        view.feed(text: String(repeating: "-", count: column))
        // The caret follows the cursor in the frame paths, which do not run without a window.
        view.updateCursorPosition()
        view.setMarkedText(text)
        let overlay = try #require(view.dictationOverlay)
        let origin = overlay.textContainerOrigin
        let cell: CGSize = view.cellDimension
        return try characterPositions(view).map { position in
            let y = view.caretView.frame.maxY - overlay.frame.maxY + origin.y + position.y
            return (row: Int((y / cell.height).rounded()),
                    column: Int(((overlay.frame.minX + origin.x + position.x) / cell.width).rounded()))
        }
    }

    /// TextKit drops an exclusion-path line fragment narrower than 15 points, so
    /// the overlay once drew a caret's text in the last column at the first column.
    @Test func testTextStartsAtACaretInTheLastColumn() throws {
        let view = TerminalView.makeForMarkedTextTests()
        let cols = view.withTerminal { $0.cols }
        let cells = try cellsAfterPrompt("xy", caretColumn: cols - 1, in: view)
        #expect(cells.count == 2)
        #expect(cells.first.map { $0 == (row: 0, column: cols - 1) } == true)
        #expect(cells.last.map { $0 == (row: 1, column: 0) } == true)
    }

    /// A wide character at a caret in the last column goes to the next row, as
    /// it does when the terminal writes it.
    @Test func testWideCharacterAtACaretInTheLastColumnStartsOnTheNextRow() throws {
        let view = TerminalView.makeForMarkedTextTests()
        let cols = view.withTerminal { $0.cols }
        let cells = try cellsAfterPrompt("日b", caretColumn: cols - 1, in: view)
        #expect(cells.count == 2)
        #expect(cells.first.map { $0 == (row: 1, column: 0) } == true)
        #expect(cells.last.map { $0 == (row: 1, column: 2) } == true)
    }

    /// Only the caret's row starts at the caret; the line after a newline in
    /// dictated text starts at the first column.
    @Test func testLineAfterANewlineStartsAtTheFirstColumn() throws {
        let view = TerminalView.makeForMarkedTextTests()
        let cells = try cellsAfterPrompt("ab\ncd", caretColumn: 10, in: view)
        let visible = cells.enumerated().filter { $0.offset != 2 }.map(\.element)
        #expect(visible.count == 4)
        #expect(visible.map(\.row) == [0, 0, 1, 1])
        #expect(visible.map(\.column) == [10, 11, 0, 1])
    }

    /// A wide character that does not fit in the last column goes to the next row.
    @Test func testWideCharacterMovesToTheNextRowWhenOneColumnRemains() throws {
        let view = TerminalView.makeForMarkedTextTests()
        let cols = view.withTerminal { $0.cols }
        let cells = try cells(String(repeating: "x", count: cols - 1) + "日b", in: view)
        #expect(cells.count == cols + 1)
        #expect(cells[cols - 1] == (row: 1, column: 0))
        #expect(cells[cols] == (row: 1, column: 2))
    }
}
#endif
