//
//  KittyUnicodeTests.swift
//
#if os(macOS)
import Testing
import CoreGraphics
@testable import SwiftTerm

final class KittyUnicodeTests {

    private func decodePlaceholders(line: BufferLine, row: Int, cols: Int, terminal: Terminal) -> [KittyPlaceholderCell] {
        var placeholders: [KittyPlaceholderCell] = []
        var previous: KittyPlaceholderCell?
        var previousAttribute: Attribute?
        var col = 0
        while col < cols {
            let ch = line[col]
            let width = max(1, Int(ch.width))
            let character = ch.code == 0 ? " " : terminal.getCharacter(for: ch)
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
        return decodePlaceholders(line: line, row: row, cols: terminal.cols, terminal: terminal)
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

    @Test func testUnicodeDiacriticsSorted() {
        let list = KittyPlaceholder.diacritics
        for idx in 1..<list.count {
            #expect(list[idx - 1] < list[idx])
        }
    }

    @Test func testUnicodeDiacriticIndex() {
        #expect(KittyPlaceholder.diacriticIndex[0x0483] == 30)
        #expect(KittyPlaceholder.diacriticIndex[0x1D242] == 294)
    }

    @Test func testUnicodePlacementNone() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 5, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "hello\r\nworld\r\n1\r\n2")
        #expect(placeholderRuns(in: t).isEmpty)
    }

    @Test func testUnicodePlacementSingleRowCol() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 5, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "\u{10EEEE}\u{0305}\u{0305}")
        let runs = placeholderRuns(in: t)
        #expect(runs.count == 1)
        #expect(runs[0].imageId == 0)
        #expect(runs[0].placementId == 0)
        #expect(runs[0].placeholderRow == 0)
        #expect(runs[0].placeholderCol == 0)
        #expect(runs[0].width == 1)
    }

    @Test func testUnicodePlacementContinuationBreak() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 10, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "\u{10EEEE}\u{0305}\u{0305}")
        t.feed(text: "\u{10EEEE}\u{0305}\u{030E}")
        let runs = placeholderRuns(in: t)
        #expect(runs.count == 2)
        #expect(runs[0].imageId == 0)
        #expect(runs[0].placementId == 0)
        #expect(runs[0].placeholderRow == 0)
        #expect(runs[0].placeholderCol == 0)
        #expect(runs[0].width == 1)
        #expect(runs[1].imageId == 0)
        #expect(runs[1].placementId == 0)
        #expect(runs[1].placeholderRow == 0)
        #expect(runs[1].placeholderCol == 2)
        #expect(runs[1].width == 1)
    }

    @Test func testUnicodePlacementContinuationWithDiacritics() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 10, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "\u{10EEEE}\u{0305}\u{0305}")
        t.feed(text: "\u{10EEEE}\u{0305}\u{030D}")
        t.feed(text: "\u{10EEEE}\u{0305}\u{030E}")
        let runs = placeholderRuns(in: t)
        #expect(runs.count == 1)
        #expect(runs[0].imageId == 0)
        #expect(runs[0].placementId == 0)
        #expect(runs[0].placeholderRow == 0)
        #expect(runs[0].placeholderCol == 0)
        #expect(runs[0].width == 3)
    }

    @Test func testUnicodePlacementContinuationNoCol() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 10, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "\u{10EEEE}\u{0305}")
        t.feed(text: "\u{10EEEE}\u{0305}")
        t.feed(text: "\u{10EEEE}\u{0305}")
        let runs = placeholderRuns(in: t)
        #expect(runs.count == 1)
        #expect(runs[0].imageId == 0)
        #expect(runs[0].placementId == 0)
        #expect(runs[0].placeholderRow == 0)
        #expect(runs[0].placeholderCol == 0)
        #expect(runs[0].width == 3)
    }

    @Test func testUnicodePlacementContinuationNoDiacritics() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 10, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "\u{10EEEE}")
        t.feed(text: "\u{10EEEE}")
        t.feed(text: "\u{10EEEE}")
        let runs = placeholderRuns(in: t)
        #expect(runs.count == 1)
        #expect(runs[0].imageId == 0)
        #expect(runs[0].placementId == 0)
        #expect(runs[0].placeholderRow == 0)
        #expect(runs[0].placeholderCol == 0)
        #expect(runs[0].width == 3)
    }

    @Test func testUnicodePlacementRunEnding() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 10, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "\u{10EEEE}\u{0305}\u{0305}")
        t.feed(text: "\u{10EEEE}\u{0305}\u{030D}")
        t.feed(text: "ABC")
        let runs = placeholderRuns(in: t)
        #expect(runs.count == 1)
        #expect(runs[0].imageId == 0)
        #expect(runs[0].placementId == 0)
        #expect(runs[0].placeholderRow == 0)
        #expect(runs[0].placeholderCol == 0)
        #expect(runs[0].width == 2)
    }

    @Test func testUnicodePlacementRunStartingMiddle() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 10, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "ABC")
        t.feed(text: "\u{10EEEE}\u{0305}\u{0305}")
        t.feed(text: "\u{10EEEE}\u{0305}\u{030D}")
        let runs = placeholderRuns(in: t)
        #expect(runs.count == 1)
        #expect(runs[0].imageId == 0)
        #expect(runs[0].placementId == 0)
        #expect(runs[0].col == 3)
        #expect(runs[0].placeholderRow == 0)
        #expect(runs[0].placeholderCol == 0)
        #expect(runs[0].width == 2)
    }

    @Test func testUnicodePlacementImageIdPalette() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 5, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "\u{1b}[38;5;42m\u{10EEEE}\u{0305}\u{0305}")
        let runs = placeholderRuns(in: t)
        #expect(runs.count == 1)
        #expect(runs[0].imageId == 42)
        #expect(runs[0].placementId == 0)
        #expect(runs[0].placeholderRow == 0)
        #expect(runs[0].placeholderCol == 0)
    }

    @Test func testUnicodePlacementImageIdHighBits() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 5, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "\u{1b}[38;5;42m\u{10EEEE}\u{0305}\u{0305}\u{030E}")
        let runs = placeholderRuns(in: t)
        #expect(runs.count == 1)
        #expect(runs[0].imageId == 33554474)
        #expect(runs[0].placementId == 0)
        #expect(runs[0].placeholderRow == 0)
        #expect(runs[0].placeholderCol == 0)
    }

    @Test func testUnicodePlacementPlacementIdPalette() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 5, rows: 5)) { _ in }
        let t = h.terminal!
        t.feed(text: "\u{1b}[38;5;42m\u{1b}[58;5;21m\u{10EEEE}\u{0305}\u{0305}")
        let runs = placeholderRuns(in: t)
        #expect(runs.count == 1)
        #expect(runs[0].imageId == 42)
        #expect(runs[0].placementId == 21)
        #expect(runs[0].placeholderRow == 0)
        #expect(runs[0].placeholderCol == 0)
    }

    @Test func testUnicodeRenderPlacementDog4x2() {
        let placement = KittyPlaceholderRenderPlacement.compute(imageSize: CGSize(width: 500, height: 306),
                                                                placementCols: 4,
                                                                placementRows: 2,
                                                                cellSize: CGSize(width: 36, height: 80),
                                                                col: 0,
                                                                row: 0,
                                                                width: 4,
                                                                height: 1)
        #expect(placement?.offsetX == 0)
        #expect(placement?.offsetY == 36)
        #expect(placement?.sourceX == 0)
        #expect(placement?.sourceY == 0)
        #expect(placement?.sourceWidth == 500)
        #expect(placement?.sourceHeight == 153)
        #expect(placement?.destWidth == 144)
        #expect(placement?.destHeight == 44)

        let placement2 = KittyPlaceholderRenderPlacement.compute(imageSize: CGSize(width: 500, height: 306),
                                                                 placementCols: 4,
                                                                 placementRows: 2,
                                                                 cellSize: CGSize(width: 36, height: 80),
                                                                 col: 0,
                                                                 row: 1,
                                                                 width: 4,
                                                                 height: 1)
        #expect(placement2?.offsetX == 0)
        #expect(placement2?.offsetY == 0)
        #expect(placement2?.sourceX == 0)
        #expect(placement2?.sourceY == 153)
        #expect(placement2?.sourceWidth == 500)
        #expect(placement2?.sourceHeight == 153)
        #expect(placement2?.destWidth == 144)
        #expect(placement2?.destHeight == 44)
    }

    @Test func testUnicodeRenderPlacementDog2x2BlankCells() {
        let placement = KittyPlaceholderRenderPlacement.compute(imageSize: CGSize(width: 500, height: 306),
                                                                placementCols: 2,
                                                                placementRows: 2,
                                                                cellSize: CGSize(width: 36, height: 80),
                                                                col: 0,
                                                                row: 0,
                                                                width: 4,
                                                                height: 1)
        #expect(placement?.offsetX == 0)
        #expect(placement?.offsetY == 58)
        #expect(placement?.sourceX == 0)
        #expect(placement?.sourceY == 0)
        #expect(placement?.sourceWidth == 500)
        #expect(placement?.sourceHeight == 153)
        #expect(placement?.destWidth == 72)
        #expect(placement?.destHeight == 22)

        let placement2 = KittyPlaceholderRenderPlacement.compute(imageSize: CGSize(width: 500, height: 306),
                                                                 placementCols: 2,
                                                                 placementRows: 2,
                                                                 cellSize: CGSize(width: 36, height: 80),
                                                                 col: 0,
                                                                 row: 1,
                                                                 width: 4,
                                                                 height: 1)
        #expect(placement2?.offsetX == 0)
        #expect(placement2?.offsetY == 0)
        #expect(placement2?.sourceX == 0)
        #expect(placement2?.sourceY == 153)
        #expect(placement2?.sourceWidth == 500)
        #expect(placement2?.sourceHeight == 153)
        #expect(placement2?.destWidth == 72)
        #expect(placement2?.destHeight == 22)
    }

    @Test func testUnicodeRenderPlacementDog1x1() {
        let placement = KittyPlaceholderRenderPlacement.compute(imageSize: CGSize(width: 500, height: 306),
                                                                placementCols: 1,
                                                                placementRows: 1,
                                                                cellSize: CGSize(width: 36, height: 80),
                                                                col: 0,
                                                                row: 0,
                                                                width: 4,
                                                                height: 1)
        #expect(placement?.offsetX == 0)
        #expect(placement?.offsetY == 29)
        #expect(placement?.sourceX == 0)
        #expect(placement?.sourceY == 0)
        #expect(placement?.sourceWidth == 500)
        #expect(placement?.sourceHeight == 306)
        #expect(placement?.destWidth == 36)
        #expect(placement?.destHeight == 22)
    }
}
#endif
