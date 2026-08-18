//
//  MetalRowCacheTests.swift
//
//  What the row cache is worth when output scrolls — the case a terminal
//  spends most of its life in.
//

#if os(macOS) && canImport(MetalKit)
import XCTest
import Foundation
import MetalKit
@testable import SwiftTerm

final class MetalRowCacheTests: XCTestCase {
    /// A view and a renderer with no window: neither `updateDisplay` nor
    /// `buildDrawData` needs one, and a window is exactly what a test cannot
    /// have.
    ///
    /// The renderer is the view's own rather than one built beside it: the
    /// dirty range is written by `updateDisplay` only when the view is in
    /// Metal mode, so a renderer the view does not know about is never told
    /// what changed.
    private func makeRenderer(rows: Int, cols: Int) throws -> (TerminalView, MetalTerminalRenderer) {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("no Metal device on this machine")
        }
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        try view.setUseMetal(true)
        guard let renderer = view.metalRenderer else {
            throw XCTSkip("the view did not take the Metal renderer")
        }

        view.getTerminal().resize(cols: cols, rows: rows)
        return (view, renderer)
    }

    private func feed(_ view: TerminalView, lines: Int) {
        for i in 0..<lines {
            view.feed(text: "line \(i) — the quick brown fox jumps over the lazy dog\r\n")
        }
    }

    /// One frame, driven the way the view drives it.
    ///
    /// `buildDrawData` on its own is not a frame: the dirty range is worked out
    /// by `updateDisplay`, and a test that skips it measures the cache against
    /// a range nobody ever filled in.
    @discardableResult
    private func frame(_ view: TerminalView, _ renderer: MetalTerminalRenderer) -> DrawData {
        view.updateDisplay(notifyAccessibility: false)
        return renderer.buildDrawData(scale: 2)
    }

    private func sendKitty(_ view: TerminalView, control: String, payload: [UInt8]) {
        let base64 = Data(payload).base64EncodedString()
        view.feed(text: "\u{1b}_G\(control);\(base64)\u{1b}\\")
    }

    /// Scrolling must not throw the cache away.
    ///
    /// The rows are the same rows; only the place they occupy has changed. This
    /// used to rebuild every visible row on every scrolled frame — the vertices
    /// were written in screen coordinates, so `yDisp` was part of the cache
    /// signature, and the cache was keyed by a row number that stops meaning
    /// the same line once the scrollback starts rotating.
    func testScrollingKeepsTheRowsItAlreadyBuilt() throws {
        let (view, renderer) = try makeRenderer(rows: 24, cols: 80)

        // Fill the screen and the scrollback, so that further output rotates
        // the circular list rather than merely appending to it.
        feed(view, lines: 400)
        frame(view, renderer)

        // One more line: one row changes, the rest scroll.
        view.feed(text: "one more line\r\n")
        frame(view, renderer)

        XCTAssertLessThanOrEqual(
            renderer.rowsRebuiltLastFrame, 3,
            "a one-line scroll rebuilt \(renderer.rowsRebuiltLastFrame) rows of "
            + "\(renderer.rowsRebuiltLastFrame + renderer.rowsReusedLastFrame)")
        XCTAssertGreaterThan(renderer.rowsReusedLastFrame, 20)
    }

    /// A frame in which nothing happened must rebuild nothing at all.
    func testAnIdleFrameRebuildsNothing() throws {
        let (view, renderer) = try makeRenderer(rows: 24, cols: 80)
        feed(view, lines: 100)
        frame(view, renderer)

        frame(view, renderer)
        XCTAssertEqual(renderer.rowsRebuiltLastFrame, 0)
    }

    /// The row that changed is the row that is rebuilt — the cache must not
    /// hand back stale geometry for a line that was written over.
    func testAnEditedRowIsRebuilt() throws {
        let (view, renderer) = try makeRenderer(rows: 24, cols: 80)
        feed(view, lines: 100)
        frame(view, renderer)

        // Overwrite the current line in place: no scroll, one dirty row.
        view.feed(text: "\roverwritten")
        frame(view, renderer)

        XCTAssertGreaterThanOrEqual(renderer.rowsRebuiltLastFrame, 1)
        XCTAssertLessThanOrEqual(renderer.rowsRebuiltLastFrame, 3)
    }

    /// A row is drawn differently when it is selected, and selecting it does
    /// not touch the line's contents — so the generation the cache checks does
    /// not move. Before the presentation revision, the selected row kept its
    /// unselected geometry.
    func testSelectingARowRebuildsIt() throws {
        let (view, renderer) = try makeRenderer(rows: 24, cols: 80)
        feed(view, lines: 40)
        frame(view, renderer)
        frame(view, renderer)
        XCTAssertEqual(renderer.rowsRebuiltLastFrame, 0, "the second frame should have rebuilt nothing")

        view.selection.setSelection(start: Position(col: 0, row: 20),
                                    end: Position(col: 10, row: 20))
        frame(view, renderer)

        XCTAssertGreaterThanOrEqual(renderer.rowsRebuiltLastFrame, 1,
                                    "the selected row has to be built again")
        XCTAssertLessThanOrEqual(renderer.rowsRebuiltLastFrame, 2,
                                 "and only that row: \(renderer.rowsRebuiltLastFrame) were")
    }

    /// The blink phase turns over twice a second and changes nothing about the
    /// line's contents. A row with something blinking on it must follow; a row
    /// without must not be dragged along with it.
    func testBlinkRebuildsOnlyTheBlinkingRow() throws {
        let (view, renderer) = try makeRenderer(rows: 24, cols: 80)
        feed(view, lines: 20)
        view.feed(text: "\u{1b}[5mblinking\u{1b}[0m\r\n")
        feed(view, lines: 2)
        frame(view, renderer)
        frame(view, renderer)
        XCTAssertEqual(renderer.rowsRebuiltLastFrame, 0)

        view.setTextBlinkVisibleForTesting(!view.textBlinkVisible)
        frame(view, renderer)

        XCTAssertEqual(renderer.rowsRebuiltLastFrame, 1,
                       "exactly the blinking row, not the whole screen")
    }

    /// Replacing the palette changes how every row draws, and moves no line's
    /// generation either.
    func testChangingTheColoursRebuildsEverything() throws {
        let (view, renderer) = try makeRenderer(rows: 24, cols: 80)
        feed(view, lines: 40)
        frame(view, renderer)
        frame(view, renderer)
        XCTAssertEqual(renderer.rowsRebuiltLastFrame, 0)

        view.nativeForegroundColor = TTColor.make(red: 0.9, green: 0.2, blue: 0.2, alpha: 1)
        frame(view, renderer)

        XCTAssertGreaterThan(renderer.rowsRebuiltLastFrame, 20,
                             "a new palette means every visible row")
    }


    /// Custom block glyphs are drawn by the renderer rather than by the font,
    /// so turning them off changes the geometry of every row that has one — and
    /// the setter asks for a full redraw without moving any line's generation.
    func testTogglingCustomBlockGlyphsRebuildsEverything() throws {
        let (view, renderer) = try makeRenderer(rows: 24, cols: 80)
        for i in 0..<24 {
            view.feed(text: "┌──────┐ ▀▄█▌▐ row \(i)\r\n")
        }
        frame(view, renderer)
        frame(view, renderer)
        XCTAssertEqual(renderer.rowsRebuiltLastFrame, 0, "the second frame should have rebuilt nothing")

        view.customBlockGlyphs.toggle()
        frame(view, renderer)

        XCTAssertGreaterThan(renderer.rowsRebuiltLastFrame, 20,
                             "box drawing is drawn differently now: every row holds some")
    }

    /// The colour the selection is painted in belongs to the view, not to a
    /// line. Replacing it asks for a full redraw and moves no generation, so a
    /// cache that trusts the generation alone keeps the old colour on screen.
    func testChangingTheSelectionBackgroundRebuildsTheSelectedRows() throws {
        let (view, renderer) = try makeRenderer(rows: 24, cols: 80)
        feed(view, lines: 40)
        view.selection.setSelection(start: Position(col: 0, row: 18),
                                    end: Position(col: 40, row: 20))
        frame(view, renderer)
        frame(view, renderer)
        XCTAssertEqual(renderer.rowsRebuiltLastFrame, 0, "the second frame should have rebuilt nothing")

        view.selectedTextBackgroundColor = TTColor.make(red: 0.8, green: 0.1, blue: 0.5, alpha: 1)
        frame(view, renderer)

        XCTAssertGreaterThanOrEqual(renderer.rowsRebuiltLastFrame, 1,
                                    "the selected rows are painted in a different colour now")
    }

    /// The same for the foreground: selected text is drawn in its own colour,
    /// and that colour is a property of the view.
    func testChangingTheSelectionForegroundRebuildsTheSelectedRows() throws {
        let (view, renderer) = try makeRenderer(rows: 24, cols: 80)
        feed(view, lines: 40)
        view.selection.setSelection(start: Position(col: 0, row: 18),
                                    end: Position(col: 40, row: 20))
        frame(view, renderer)
        frame(view, renderer)
        XCTAssertEqual(renderer.rowsRebuiltLastFrame, 0, "the second frame should have rebuilt nothing")

        view.selectedTextForegroundColor = TTColor.make(red: 0.1, green: 0.9, blue: 0.4, alpha: 1)
        frame(view, renderer)

        XCTAssertGreaterThanOrEqual(renderer.rowsRebuiltLastFrame, 1,
                                    "the selected text is drawn in a different colour now")
    }

    /// A kitty image can be replaced under an id that is already placed: the
    /// number of images does not change, neither does the next id, and no
    /// line's generation moves — but the row holds a texture built from the
    /// bytes that have just been thrown away.
    func testReplacingAKittyImageRebuildsTheRowItIsPlacedOn() throws {
        let (view, renderer) = try makeRenderer(rows: 24, cols: 80)
        let terminal = view.getTerminal()
        feed(view, lines: 10)
        sendKitty(view, control: "a=T,f=24,s=2,v=2,t=d,c=2,r=1,i=1",
                  payload: [UInt8](repeating: 0x20, count: 12))
        frame(view, renderer)
        frame(view, renderer)
        XCTAssertEqual(renderer.rowsRebuiltLastFrame, 0, "the second frame should have rebuilt nothing")

        let imagesBefore = terminal.kittyGraphicsState.imagesById.count
        let placementsBefore = terminal.kittyGraphicsState.placementsByKey.count
        let nextIdBefore = terminal.kittyGraphicsState.nextImageId

        // Transmit only: the same id, different pixels, the placement left
        // exactly as it was.
        sendKitty(view, control: "a=t,f=24,s=2,v=2,t=d,i=1",
                  payload: [UInt8](repeating: 0xF0, count: 12))

        XCTAssertEqual(terminal.kittyGraphicsState.imagesById.count, imagesBefore,
                       "the stamp this used to be keyed on cannot see the replacement")
        XCTAssertEqual(terminal.kittyGraphicsState.placementsByKey.count, placementsBefore)
        XCTAssertEqual(terminal.kittyGraphicsState.nextImageId, nextIdBefore)

        frame(view, renderer)
        XCTAssertGreaterThanOrEqual(renderer.rowsRebuiltLastFrame, 1,
                                    "the row draws a texture made from bytes that no longer exist")
    }
    /// The alternate screen has no scrollback, so a scroll there cannot be a
    /// blit: `refreshScrolledRegion` records the whole region as genuinely
    /// dirty rather than as moved. This is what that costs — the number to
    /// compare against the normal buffer below.
    func testScrollingInTheAlternateBuffer() throws {
        let (view, renderer) = try makeRenderer(rows: 48, cols: 120)
        view.feed(text: "\u{1b}[?1049h")
        feed(view, lines: 48)
        frame(view, renderer)

        var rebuilt = 0
        var elapsed: TimeInterval = 0
        for i in 0..<200 {
            view.feed(text: "\u{1b}[1;32mscrolled line \(i)\u{1b}[0m — "
                      + "\u{1b}[38;5;244mthe quick brown fox jumps over the lazy dog\u{1b}[0m\r\n")
            view.updateDisplay(notifyAccessibility: false)
            let started = Date()
            _ = renderer.buildDrawData(scale: 2)
            elapsed += Date().timeIntervalSince(started)
            rebuilt += renderer.rowsRebuiltLastFrame
        }
        print(String(format: "alternate buffer: %.3f ms per frame, %.1f rows rebuilt per frame",
                     elapsed / 200 * 1000, Double(rebuilt) / 200))
    }

    /// What the change is for, in wall-clock terms.
    func testScrollingIsCheap() throws {
        let (view, renderer) = try makeRenderer(rows: 48, cols: 120)
        feed(view, lines: 600)
        frame(view, renderer)

        var rebuilt = 0
        let started = Date()
        for i in 0..<200 {
            // Colour and bold, as an agent's output has: a plain ASCII line is
            // not what this costs money on.
            view.feed(text: "\u{1b}[1;32mscrolled line \(i)\u{1b}[0m — "
                      + "\u{1b}[38;5;244mthe quick brown fox jumps over the lazy dog\u{1b}[0m\r\n")
            frame(view, renderer)
            rebuilt += renderer.rowsRebuiltLastFrame
        }
        let each = Date().timeIntervalSince(started) / 200 * 1000
        print(String(format: "buildDrawData while scrolling: %.3f ms per frame, %.1f rows rebuilt per frame",
                     each, Double(rebuilt) / 200))
    }
}
#endif
