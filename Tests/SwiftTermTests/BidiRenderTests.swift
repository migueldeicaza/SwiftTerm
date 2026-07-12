//
//  BidiRenderTests.swift
//
//  Offscreen smoke tests for the BiDi rendering path: feeds RTL content into a
//  real TerminalView and renders it to a bitmap, exercising
//  buildAttributedString/drawTerminalContents with visual reordering, shaped
//  Arabic forms, and the multi-scalar cell isolation branch.
//
#if os(macOS)
import Foundation
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
final class BidiRenderTests {

    func render(_ view: TerminalView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    func makeView(feed text: String) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        view.getTerminal().feed(text: text)
        return view
    }

    @Test func rtlContentRendersWithoutCrashing() throws {
        let view = makeView(feed: "مرحبا بالعالم\r\nשלום עולם\r\n(אב) hello ملف.txt\r\nهذا نص عربي مع English مختلط")
        let rep = try #require(render(view))
        #expect(rep.size.width > 0)
    }

    /// The concatenated text content of all segments of a rendered row.
    func segmentText(_ view: TerminalView, row: Int) -> String {
        let terminal = view.getTerminal()
        let info = view.buildAttributedString(row: row, line: terminal.buffer.lines[row],
                                              cols: terminal.cols)
        return info.segments.map { $0.attributedString.string }.joined()
    }

    @Test func viewEmitsShapedPresentationForms() throws {
        let view = makeView(feed: "مرحبا")
        view.bidiParagraphDirection = .auto
        let bidiText = segmentText(view, row: 0)
        // The visual row must contain the contextually shaped forms, with the
        // initial meem as the rightmost (last visual) non-space character.
        #expect(bidiText.contains("\u{FEE3}"))  // م initial
        #expect(bidiText.contains("\u{FE92}"))  // ب medial
        #expect(bidiText.trimmingCharacters(in: .whitespaces).last == "\u{FEE3}")

        view.bidiParagraphDirection = .off
        let plainText = segmentText(view, row: 0)
        // Legacy path: logical order, no presentation forms.
        #expect(!plainText.contains("\u{FEE3}"))
        #expect(plainText.hasPrefix("مرحبا"))
    }

    @Test func wrappedArabicWordKeepsJoiningAcrossRows() throws {
        // A 12-letter beh run in a 10-column terminal wraps 10 + 2. The last
        // cell of row 0 must render the MEDIAL form (it joins into row 1),
        // and row 1 must open medial and close final.
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let cellWidth = view.cellDimension.width
        let cellHeight = view.cellDimension.height
        view.setFrameSize(NSSize(width: cellWidth * 10 + 1, height: cellHeight * 5 + 1))
        let terminal = view.getTerminal()
        let cols = terminal.cols
        #expect(cols >= 4)

        terminal.feed(text: String(repeating: "ب", count: cols + 2))
        #expect(terminal.buffer.lines[1].isWrapped)

        let row0 = segmentText(view, row: 0).trimmingCharacters(in: .whitespaces)
        let row1 = segmentText(view, row: 1).trimmingCharacters(in: .whitespaces)
        // Visual order: RTL rows read right-to-left, so the logical last cell
        // of row 0 is the leftmost character in the segment text.
        #expect(row0.count == cols)
        #expect(row0.first == "\u{FE92}", "row 0's seam letter must be medial")
        #expect(row0.last == "\u{FE91}", "row 0 starts the word with the initial form")
        #expect(row0.dropFirst().dropLast().allSatisfy { $0 == "\u{FE92}" })
        #expect(row1.count == 2)
        #expect(row1.last == "\u{FE92}", "row 1's first logical letter continues medially")
        #expect(row1.first == "\u{FE90}", "the word's last letter takes the final form")
    }

    @Test func caretIsDrawnAtVisualColumn() throws {
        // After feeding مرحبا (5 cells) the logical cursor is at column 5.
        // In the RTL paragraph the text occupies the right edge, so the caret
        // must be drawn at visual column cols-6 (just left of the text).
        let view = makeView(feed: "مرحبا")
        // The display queue that normally triggers this is throttled and needs
        // a runloop; call it directly for a deterministic test.
        view.updateCursorPosition()
        let terminal = view.getTerminal()
        let caret = try #require(view.caretView)
        let cellWidth = view.cellDimension.width
        let expectedVisualCol = terminal.cols - 6
        #expect(abs(caret.frame.origin.x - CGFloat(expectedVisualCol) * cellWidth) < 0.5)

        // With BiDi off the caret sits at the logical column.
        view.bidiParagraphDirection = .off
        #expect(abs(caret.frame.origin.x - 5 * cellWidth) < 0.5)
    }

    @Test func forcedRTLRightAlignsLatinRow() throws {
        // Forced RTL paragraphs place trailing whitespace at the visual left
        // (UAX #9 L1), so even pure-Latin text right-aligns: a difference the
        // legacy path cannot produce.
        let rtlView = makeView(feed: "abc")
        rtlView.bidiParagraphDirection = .rightToLeft
        let rtlText = segmentText(rtlView, row: 0)
        #expect(rtlText.hasSuffix("abc"))
        let rtlRep = try #require(render(rtlView))

        let plainView = makeView(feed: "abc")
        plainView.bidiParagraphDirection = .off
        let plainRep = try #require(render(plainView))

        #expect(rtlRep.tiffRepresentation != plainRep.tiffRepresentation)
    }

    @Test func emojiAndCombiningCellsRenderInBidiRows() throws {
        // Emoji (astral, multi-scalar) and Hebrew niqqud inside an RTL row
        // take the isolated-segment path.
        let view = makeView(feed: "שָׁלוֹם 🙂 مرحبا")
        _ = try #require(render(view))
    }

    @Test func forcedDirectionsRenderAllRows() throws {
        for direction in [BidiParagraphDirection.auto, .leftToRight, .rightToLeft, .off] {
            let view = makeView(feed: "abc מרחבא 123 (x)\r\nمرحبا abc")
            view.bidiParagraphDirection = direction
            _ = try #require(render(view))
        }
    }
}
#endif
