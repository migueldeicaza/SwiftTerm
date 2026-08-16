//
//  MetalRowCacheTests.swift
//
//  What the row cache is worth when output scrolls — the case a terminal
//  spends most of its life in.
//

#if os(macOS) && canImport(MetalKit)
import XCTest
import MetalKit
@testable import SwiftTerm

final class MetalRowCacheTests: XCTestCase {
    /// A view and a renderer with no window: `buildDrawData` needs neither, and
    /// a window is exactly what a test cannot have.
    private func makeRenderer(rows: Int, cols: Int) throws -> (TerminalView, MetalTerminalRenderer) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device on this machine")
        }
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let mtkView = MTKView(frame: view.bounds, device: device)
        let renderer = try MetalTerminalRenderer(view: mtkView, terminalView: view)

        view.getTerminal().resize(cols: cols, rows: rows)
        return (view, renderer)
    }

    private func feed(_ view: TerminalView, lines: Int) {
        for i in 0..<lines {
            view.feed(text: "line \(i) — the quick brown fox jumps over the lazy dog\r\n")
        }
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
        _ = renderer.buildDrawData(scale: 2)

        // One more line: one row changes, the rest scroll.
        view.feed(text: "one more line\r\n")
        _ = renderer.buildDrawData(scale: 2)

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
        _ = renderer.buildDrawData(scale: 2)

        _ = renderer.buildDrawData(scale: 2)
        XCTAssertEqual(renderer.rowsRebuiltLastFrame, 0)
    }

    /// The row that changed is the row that is rebuilt — the cache must not
    /// hand back stale geometry for a line that was written over.
    func testAnEditedRowIsRebuilt() throws {
        let (view, renderer) = try makeRenderer(rows: 24, cols: 80)
        feed(view, lines: 100)
        _ = renderer.buildDrawData(scale: 2)

        // Overwrite the current line in place: no scroll, one dirty row.
        view.feed(text: "\roverwritten")
        _ = renderer.buildDrawData(scale: 2)

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
        _ = renderer.buildDrawData(scale: 2)
        _ = renderer.buildDrawData(scale: 2)
        XCTAssertEqual(renderer.rowsRebuiltLastFrame, 0, "the second frame should have rebuilt nothing")

        view.selection.setSelection(start: Position(col: 0, row: 20),
                                    end: Position(col: 10, row: 20))
        _ = renderer.buildDrawData(scale: 2)

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
        _ = renderer.buildDrawData(scale: 2)
        _ = renderer.buildDrawData(scale: 2)
        XCTAssertEqual(renderer.rowsRebuiltLastFrame, 0)

        view.textBlinkVisible.toggle()
        _ = renderer.buildDrawData(scale: 2)

        XCTAssertEqual(renderer.rowsRebuiltLastFrame, 1,
                       "exactly the blinking row, not the whole screen")
    }

    /// Replacing the palette changes how every row draws, and moves no line's
    /// generation either.
    func testChangingTheColoursRebuildsEverything() throws {
        let (view, renderer) = try makeRenderer(rows: 24, cols: 80)
        feed(view, lines: 40)
        _ = renderer.buildDrawData(scale: 2)
        _ = renderer.buildDrawData(scale: 2)
        XCTAssertEqual(renderer.rowsRebuiltLastFrame, 0)

        view.nativeForegroundColor = TTColor.make(red: 0.9, green: 0.2, blue: 0.2, alpha: 1)
        _ = renderer.buildDrawData(scale: 2)

        XCTAssertGreaterThan(renderer.rowsRebuiltLastFrame, 20,
                             "a new palette means every visible row")
    }

    /// What the change is for, in wall-clock terms.
    func testScrollingIsCheap() throws {
        let (view, renderer) = try makeRenderer(rows: 48, cols: 120)
        feed(view, lines: 600)
        _ = renderer.buildDrawData(scale: 2)

        var rebuilt = 0
        let started = Date()
        for i in 0..<200 {
            // Colour and bold, as an agent's output has: a plain ASCII line is
            // not what this costs money on.
            view.feed(text: "\u{1b}[1;32mscrolled line \(i)\u{1b}[0m — "
                      + "\u{1b}[38;5;244mthe quick brown fox jumps over the lazy dog\u{1b}[0m\r\n")
            _ = renderer.buildDrawData(scale: 2)
            rebuilt += renderer.rowsRebuiltLastFrame
        }
        let each = Date().timeIntervalSince(started) / 200 * 1000
        print(String(format: "buildDrawData while scrolling: %.3f ms per frame, %.1f rows rebuilt per frame",
                     each, Double(rebuilt) / 200))
    }
}
#endif
