//
//  KittyUnicodeTests.swift
//
#if os(macOS)
import XCTest
import CoreGraphics
@testable import SwiftTerm

final class KittyUnicodeTests: XCTestCase {

    private func decodePlaceholders(line: BufferLine, row: Int, cols: Int) -> [KittyPlaceholderCell] {
        var placeholders: [KittyPlaceholderCell] = []
        var previous: KittyPlaceholderCell?
        var previousAttribute: Attribute?
        var col = 0
        while col < cols {
            let ch = line[col]
            let width = max(1, Int(ch.width))
            let character = ch.code == 0 ? " " : ch.getCharacter()
            if let placeholder = KittyPlaceholderDecoder.decode(character: character,
                                                                attribute: ch.attribute,
                                                                row: row,
                                                                col: col,
                                                                previous: previous,
                                                                previousAttribute: previousAttribute) {
                placeholders.append(placeholder)
                previous = placeholder
                previousAttribute = ch.attribute
            } else {
                previous = nil
                previousAttribute = nil
            }
            col += width
        }
        return placeholders
    }

    private struct PlaceholderRun {
        let imageId: UInt32
        let placementId: UInt32
        let placeholderRow: Int
        let placeholderCol: Int
        let col: Int
        let width: Int
    }

    private func placeholders(in terminal: Terminal, row: Int = 0) -> [KittyPlaceholderCell] {
        guard let line = terminal.getLine(row: row) else {
            return []
        }
        return decodePlaceholders(line: line, row: row, cols: terminal.cols)
    }

    private func placeholderRuns(in terminal: Terminal, row: Int = 0) -> [PlaceholderRun] {
        let cells = placeholders(in: terminal, row: row).sorted { $0.col < $1.col }
        guard !cells.isEmpty else {
            return []
        }
        var runs: [PlaceholderRun] = []
        var current: PlaceholderRun?
        var lastCol = 0
        var lastPlaceholderCol = 0

        for cell in cells {
            if let cur = current,
               cell.imageId == cur.imageId,
               cell.placementId == cur.placementId,
               cell.placeholderRow == cur.placeholderRow,
               cell.col == lastCol + 1,
               cell.placeholderCol == lastPlaceholderCol + 1 {
                current = PlaceholderRun(imageId: cur.imageId,
                                         placementId: cur.placementId,
                                         placeholderRow: cur.placeholderRow,
                                         placeholderCol: cur.placeholderCol,
                                         col: cur.col,
                                         width: cur.width + 1)
                lastCol = cell.col
                lastPlaceholderCol = cell.placeholderCol
            } else {
                if let cur = current {
                    runs.append(cur)
                }
                current = PlaceholderRun(imageId: cell.imageId,
                                         placementId: cell.placementId,
                                         placeholderRow: cell.placeholderRow,
                                         placeholderCol: cell.placeholderCol,
                                         col: cell.col,
                                         width: 1)
                lastCol = cell.col
                lastPlaceholderCol = cell.placeholderCol
            }
        }
        if let cur = current {
            runs.append(cur)
        }
        return runs
    }

    func testUnicodeDiacriticsSorted() {
        let list = KittyPlaceholder.diacritics
        for idx in 1..<list.count {
            XCTAssertLessThan(list[idx - 1], list[idx])
        }
    }

    func testUnicodeDiacriticIndex() {
        XCTAssertEqual(KittyPlaceholder.diacriticIndex[0x0483], 30)
        XCTAssertEqual(KittyPlaceholder.diacriticIndex[0x1D242], 294)
    }

    func testUnicodePlacementNone() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 5, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "hello\r\nworld\r\n1\r\n2")
        XCTAssertTrue(placeholderRuns(in: t).isEmpty)
    }

    func testUnicodePlacementSingleRowCol() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 5, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "\u{10EEEE}\u{0305}\u{0305}")
        let runs = placeholderRuns(in: t)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].imageId, 0)
        XCTAssertEqual(runs[0].placementId, 0)
        XCTAssertEqual(runs[0].placeholderRow, 0)
        XCTAssertEqual(runs[0].placeholderCol, 0)
        XCTAssertEqual(runs[0].width, 1)
    }

    func testUnicodePlacementContinuationBreak() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 10, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "\u{10EEEE}\u{0305}\u{0305}")
        t.feed(text: "\u{10EEEE}\u{0305}\u{030E}")
        let runs = placeholderRuns(in: t)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].imageId, 0)
        XCTAssertEqual(runs[0].placementId, 0)
        XCTAssertEqual(runs[0].placeholderRow, 0)
        XCTAssertEqual(runs[0].placeholderCol, 0)
        XCTAssertEqual(runs[0].width, 1)
        XCTAssertEqual(runs[1].imageId, 0)
        XCTAssertEqual(runs[1].placementId, 0)
        XCTAssertEqual(runs[1].placeholderRow, 0)
        XCTAssertEqual(runs[1].placeholderCol, 2)
        XCTAssertEqual(runs[1].width, 1)
    }

    func testUnicodePlacementContinuationWithDiacritics() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 10, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "\u{10EEEE}\u{0305}\u{0305}")
        t.feed(text: "\u{10EEEE}\u{0305}\u{030D}")
        t.feed(text: "\u{10EEEE}\u{0305}\u{030E}")
        let runs = placeholderRuns(in: t)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].imageId, 0)
        XCTAssertEqual(runs[0].placementId, 0)
        XCTAssertEqual(runs[0].placeholderRow, 0)
        XCTAssertEqual(runs[0].placeholderCol, 0)
        XCTAssertEqual(runs[0].width, 3)
    }

    func testUnicodePlacementContinuationNoCol() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 10, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "\u{10EEEE}\u{0305}")
        t.feed(text: "\u{10EEEE}\u{0305}")
        t.feed(text: "\u{10EEEE}\u{0305}")
        let runs = placeholderRuns(in: t)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].imageId, 0)
        XCTAssertEqual(runs[0].placementId, 0)
        XCTAssertEqual(runs[0].placeholderRow, 0)
        XCTAssertEqual(runs[0].placeholderCol, 0)
        XCTAssertEqual(runs[0].width, 3)
    }

    func testUnicodePlacementContinuationNoDiacritics() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 10, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "\u{10EEEE}")
        t.feed(text: "\u{10EEEE}")
        t.feed(text: "\u{10EEEE}")
        let runs = placeholderRuns(in: t)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].imageId, 0)
        XCTAssertEqual(runs[0].placementId, 0)
        XCTAssertEqual(runs[0].placeholderRow, 0)
        XCTAssertEqual(runs[0].placeholderCol, 0)
        XCTAssertEqual(runs[0].width, 3)
    }

    func testUnicodePlacementRunEnding() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 10, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "\u{10EEEE}\u{0305}\u{0305}")
        t.feed(text: "\u{10EEEE}\u{0305}\u{030D}")
        t.feed(text: "ABC")
        let runs = placeholderRuns(in: t)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].imageId, 0)
        XCTAssertEqual(runs[0].placementId, 0)
        XCTAssertEqual(runs[0].placeholderRow, 0)
        XCTAssertEqual(runs[0].placeholderCol, 0)
        XCTAssertEqual(runs[0].width, 2)
    }

    func testUnicodePlacementRunStartingMiddle() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 10, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "ABC")
        t.feed(text: "\u{10EEEE}\u{0305}\u{0305}")
        t.feed(text: "\u{10EEEE}\u{0305}\u{030D}")
        let runs = placeholderRuns(in: t)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].imageId, 0)
        XCTAssertEqual(runs[0].placementId, 0)
        XCTAssertEqual(runs[0].col, 3)
        XCTAssertEqual(runs[0].placeholderRow, 0)
        XCTAssertEqual(runs[0].placeholderCol, 0)
        XCTAssertEqual(runs[0].width, 2)
    }

    func testUnicodePlacementImageIdPalette() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 5, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "\u{1b}[38;5;42m\u{10EEEE}\u{0305}\u{0305}")
        let runs = placeholderRuns(in: t)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].imageId, 42)
        XCTAssertEqual(runs[0].placementId, 0)
        XCTAssertEqual(runs[0].placeholderRow, 0)
        XCTAssertEqual(runs[0].placeholderCol, 0)
    }

    func testUnicodePlacementImageIdHighBits() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 5, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "\u{1b}[38;5;42m\u{10EEEE}\u{0305}\u{0305}\u{030E}")
        let runs = placeholderRuns(in: t)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].imageId, 33554474)
        XCTAssertEqual(runs[0].placementId, 0)
        XCTAssertEqual(runs[0].placeholderRow, 0)
        XCTAssertEqual(runs[0].placeholderCol, 0)
    }

    func testUnicodePlacementPlacementIdPalette() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 5, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "\u{1b}[38;5;42m\u{1b}[58;5;21m\u{10EEEE}\u{0305}\u{0305}")
        let runs = placeholderRuns(in: t)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].imageId, 42)
        XCTAssertEqual(runs[0].placementId, 21)
        XCTAssertEqual(runs[0].placeholderRow, 0)
        XCTAssertEqual(runs[0].placeholderCol, 0)
    }

    func testUnicodeRenderPlacementDog4x2() {
        let placement = KittyPlaceholderRenderPlacement.compute(imageSize: CGSize(width: 500, height: 306),
                                                                placementCols: 4,
                                                                placementRows: 2,
                                                                cellSize: CGSize(width: 36, height: 80),
                                                                col: 0,
                                                                row: 0,
                                                                width: 4,
                                                                height: 1)
        XCTAssertEqual(placement?.offsetX, 0)
        XCTAssertEqual(placement?.offsetY, 36)
        XCTAssertEqual(placement?.sourceX, 0)
        XCTAssertEqual(placement?.sourceY, 0)
        XCTAssertEqual(placement?.sourceWidth, 500)
        XCTAssertEqual(placement?.sourceHeight, 153)
        XCTAssertEqual(placement?.destWidth, 144)
        XCTAssertEqual(placement?.destHeight, 44)

        let placement2 = KittyPlaceholderRenderPlacement.compute(imageSize: CGSize(width: 500, height: 306),
                                                                 placementCols: 4,
                                                                 placementRows: 2,
                                                                 cellSize: CGSize(width: 36, height: 80),
                                                                 col: 0,
                                                                 row: 1,
                                                                 width: 4,
                                                                 height: 1)
        XCTAssertEqual(placement2?.offsetX, 0)
        XCTAssertEqual(placement2?.offsetY, 0)
        XCTAssertEqual(placement2?.sourceX, 0)
        XCTAssertEqual(placement2?.sourceY, 153)
        XCTAssertEqual(placement2?.sourceWidth, 500)
        XCTAssertEqual(placement2?.sourceHeight, 153)
        XCTAssertEqual(placement2?.destWidth, 144)
        XCTAssertEqual(placement2?.destHeight, 44)
    }

    func testUnicodeRenderPlacementDog2x2BlankCells() {
        let placement = KittyPlaceholderRenderPlacement.compute(imageSize: CGSize(width: 500, height: 306),
                                                                placementCols: 2,
                                                                placementRows: 2,
                                                                cellSize: CGSize(width: 36, height: 80),
                                                                col: 0,
                                                                row: 0,
                                                                width: 4,
                                                                height: 1)
        XCTAssertEqual(placement?.offsetX, 0)
        XCTAssertEqual(placement?.offsetY, 58)
        XCTAssertEqual(placement?.sourceX, 0)
        XCTAssertEqual(placement?.sourceY, 0)
        XCTAssertEqual(placement?.sourceWidth, 500)
        XCTAssertEqual(placement?.sourceHeight, 153)
        XCTAssertEqual(placement?.destWidth, 72)
        XCTAssertEqual(placement?.destHeight, 22)

        let placement2 = KittyPlaceholderRenderPlacement.compute(imageSize: CGSize(width: 500, height: 306),
                                                                 placementCols: 2,
                                                                 placementRows: 2,
                                                                 cellSize: CGSize(width: 36, height: 80),
                                                                 col: 0,
                                                                 row: 1,
                                                                 width: 4,
                                                                 height: 1)
        XCTAssertEqual(placement2?.offsetX, 0)
        XCTAssertEqual(placement2?.offsetY, 0)
        XCTAssertEqual(placement2?.sourceX, 0)
        XCTAssertEqual(placement2?.sourceY, 153)
        XCTAssertEqual(placement2?.sourceWidth, 500)
        XCTAssertEqual(placement2?.sourceHeight, 153)
        XCTAssertEqual(placement2?.destWidth, 72)
        XCTAssertEqual(placement2?.destHeight, 22)
    }

    func testUnicodeRenderPlacementDog1x1() {
        let placement = KittyPlaceholderRenderPlacement.compute(imageSize: CGSize(width: 500, height: 306),
                                                                placementCols: 1,
                                                                placementRows: 1,
                                                                cellSize: CGSize(width: 36, height: 80),
                                                                col: 0,
                                                                row: 0,
                                                                width: 4,
                                                                height: 1)
        XCTAssertEqual(placement?.offsetX, 0)
        XCTAssertEqual(placement?.offsetY, 29)
        XCTAssertEqual(placement?.sourceX, 0)
        XCTAssertEqual(placement?.sourceY, 0)
        XCTAssertEqual(placement?.sourceWidth, 500)
        XCTAssertEqual(placement?.sourceHeight, 306)
        XCTAssertEqual(placement?.destWidth, 36)
        XCTAssertEqual(placement?.destHeight, 22)
    }
}
#endif
