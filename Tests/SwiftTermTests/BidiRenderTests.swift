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

    final class InvalidationTrackingView: TerminalView {
        var invalidatedRects: [NSRect] = []

        override func setNeedsDisplay(_ invalidRect: NSRect) {
            invalidatedRects.append(invalidRect)
            super.setNeedsDisplay(invalidRect)
        }
    }

    final class CapturingDelegate: TerminalViewDelegate {
        var sent: [UInt8] = []
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            sent.append(contentsOf: data)
        }
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

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
        let bidiText = segmentText(view, row: 0)
        // The visual row must contain the contextually shaped forms, with the
        // initial meem as the rightmost (last visual) non-space character.
        #expect(bidiText.contains("\u{FEE3}"))  // م initial
        #expect(bidiText.contains("\u{FE92}"))  // ب medial
        #expect(bidiText.trimmingCharacters(in: .whitespaces).last == "\u{FEE3}")

        view.bidiHostPolicy = .legacyLeftToRight
        let plainText = segmentText(view, row: 0)
        // Legacy path: logical order, no presentation forms.
        #expect(!plainText.contains("\u{FEE3}"))
        #expect(plainText.hasPrefix("مرحبا"))
    }

    @Test func rendererInputAlwaysPreservesTerminalCellOrder() throws {
        let directionKey = NSAttributedString.Key(kCTWritingDirectionAttributeName as String)
        let view = makeView(feed: "שלום")
        view.bidiHostPolicy = .legacyLeftToRight
        let legacy = view.buildAttributedString(row: 0,
                                                line: view.getTerminal().buffer.lines[0],
                                                cols: view.getTerminal().cols)
        let legacySegment = try #require(legacy.segments.first)
        #expect(legacySegment.attributedString.string.hasPrefix("שלום"))
        #expect((legacySegment.attributedString.attribute(directionKey, at: 0,
                                                          effectiveRange: nil) as? [NSNumber])
                    == [NSNumber(value: 2)])

        let explicit = makeView(feed: "\u{1b}[8l\u{1b}[2 kשלום")
        let explicitText = segmentText(explicit, row: 0)
        #expect(explicitText.hasSuffix("םולש"))
    }

    @Test func explicitRTLStoresApplicationCellsAndReversesThemForDisplay() {
        let source = "321 cba אבג :LTR ticilpxe"
        let view = makeView(feed: "\u{1b}[8l\u{1b}[2 k" + source)
        let terminal = view.getTerminal()
        let stored = terminal.buffer.lines[0].translateToString(
            trimRight: true,
            characterProvider: terminal.getCharacter(for:)
        )
        #expect(stored == source)
        #expect(segmentText(view, row: 0).hasSuffix("explicit RTL: גבא abc 123"))
        _ = render(view)
        let storedAfterRender = terminal.buffer.lines[0].translateToString(
            trimRight: true,
            characterProvider: terminal.getCharacter(for:)
        )
        #expect(storedAfterRender == source)
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

    @Test func coreGraphicsInvalidatesPreviousParagraphRows() throws {
        let view = InvalidationTrackingView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        let terminal = view.getTerminal()
        terminal.buffer.lines[1].isWrapped = true
        terminal.clearUpdateRange()
        terminal.updateRange(1)
        view.invalidatedRects.removeAll()

        view.updateDisplay(notifyAccessibility: false)

        let invalidated = try #require(view.invalidatedRects.last)
        #expect(abs(invalidated.maxY - view.bounds.maxY) < 0.5)
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
        view.bidiHostPolicy = .legacyLeftToRight
        #expect(abs(caret.frame.origin.x - 5 * cellWidth) < 0.5)
    }

    @Test func forcedRTLRightAlignsLatinRow() throws {
        // Forced RTL paragraphs place trailing whitespace at the visual left
        // (UAX #9 L1), so even pure-Latin text right-aligns: a difference the
        // legacy path cannot produce.
        let rtlView = makeView(feed: "\u{1b}[?2501l\u{1b}[2 kabc")
        let rtlText = segmentText(rtlView, row: 0)
        #expect(rtlText.hasSuffix("abc"))
        let rtlRep = try #require(render(rtlView))

        let plainView = makeView(feed: "abc")
        plainView.bidiHostPolicy = .legacyLeftToRight
        let plainRep = try #require(render(plainView))

        #expect(rtlRep.tiffRepresentation != plainRep.tiffRepresentation)
    }

    @Test func emojiAndCombiningCellsRenderInBidiRows() throws {
        // Emoji (astral, multi-scalar) and Hebrew niqqud inside an RTL row
        // take the isolated-segment path.
        let view = makeView(feed: "שָׁלוֹם 🙂 مرحبا")
        _ = try #require(render(view))
    }

    @Test func customBoxRendererUsesTheMirroredCharacter() throws {
        let view = makeView(feed: "\u{1b}[?2500hאב┌")
        let terminal = view.getTerminal()
        let info = view.buildAttributedString(row: 0, line: terminal.buffer.lines[0],
                                              cols: terminal.cols)
        let box = try #require(info.boxDrawings.first)
        #expect(box.codePoint == 0x2510) // ┐
        _ = try #require(render(view))
    }

    @Test func mouseHitMapsVisualColumnToLogicalColumn() {
        let view = makeView(feed: "אב")
        let terminal = view.getTerminal()
        let point = CGPoint(x: (CGFloat(terminal.cols) - 0.5) * view.cellDimension.width,
                            y: view.frame.height - view.cellDimension.height / 2)
        let hit = view.calculateMouseHit(at: point)
        #expect(hit.grid.col == 0)
    }

    @Test func arrowKeysRequireOptInAndFollowTheRuntimeSetting() {
        let view = makeView(feed: "אב")
        let delegate = CapturingDelegate()
        view.terminalDelegate = delegate
        let terminal = view.getTerminal()

        view.sendKeyLeft()
        #expect(delegate.sent == EscapeSequences.moveLeftNormal)

        delegate.sent.removeAll()
        terminal.bidiArrowKeySwap = true
        view.sendKeyLeft()
        #expect(delegate.sent == EscapeSequences.moveRightNormal)
        delegate.sent.removeAll()
        view.sendKeyRight()
        #expect(delegate.sent == EscapeSequences.moveLeftNormal)

        delegate.sent.removeAll()
        terminal.bidiArrowKeySwap = false
        view.sendKeyLeft()
        #expect(delegate.sent == EscapeSequences.moveLeftNormal)
    }

    @Test func forcedDirectionsRenderAllRows() throws {
        let prefixes = ["", "\u{1b}[?2501l\u{1b}[1 k", "\u{1b}[?2501l\u{1b}[2 k"]
        for prefix in prefixes {
            let view = makeView(feed: prefix + "abc מרחבא 123 (x)\r\nمرحبا abc")
            _ = try #require(render(view))
        }
        let legacyView = makeView(feed: "abc מרחבא 123 (x)\r\nمرحبا abc")
        legacyView.bidiHostPolicy = .legacyLeftToRight
        _ = try #require(render(legacyView))
    }
}
#endif
