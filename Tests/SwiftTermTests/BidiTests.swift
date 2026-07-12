//
//  BidiTests.swift
//
//  Tests for cell-level BiDi support: UAX #9 visual reordering, Arabic
//  contextual shaping to presentation forms, lam-alef ligatures, and
//  bracket mirroring.
//
#if os(macOS)
import Foundation
import AppKit
import Testing

@testable import SwiftTerm

final class BidiTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    func makeTerminal(cols: Int, feed text: String) -> Terminal {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: 4))
        terminal.feed(text: text)
        return terminal
    }

    func layoutRow0(cols: Int, _ text: String,
                    direction: BidiParagraphDirection = .auto) -> BidiRowLayout? {
        let terminal = makeTerminal(cols: cols, feed: text)
        return TerminalBidi.layout(line: terminal.buffer.lines[0], cols: cols,
                                   terminal: terminal, direction: direction, font: font)
    }

    func cells(_ text: String) -> [TerminalBidi.Cell] {
        text.enumerated().map { TerminalBidi.Cell(logicalCol: $0.offset, width: 1, text: $0.element) }
    }

    // MARK: Fast path

    @Test func pureLTRRowNeedsNoLayout() {
        #expect(layoutRow0(cols: 10, "hello") == nil)
        #expect(layoutRow0(cols: 10, "café 123!") == nil)
    }

    @Test func bidiOffReturnsNoLayout() {
        #expect(layoutRow0(cols: 10, "שלום", direction: .off) == nil)
    }

    // MARK: Ordering

    @Test func hebrewRowIsReversedToRightEdge() throws {
        let cols = 10
        let layout = try #require(layoutRow0(cols: cols, "שלום"))
        // First strong character is RTL, so the row is an RTL paragraph:
        // the text hugs the right edge, reading right-to-left.
        #expect(layout.logicalToVisualCol[0] == 9)  // ש rightmost
        #expect(layout.logicalToVisualCol[1] == 8)  // ל
        #expect(layout.logicalToVisualCol[2] == 7)  // ו
        #expect(layout.logicalToVisualCol[3] == 6)  // ם
        #expect(layout.visualToLogicalCol[9] == 0)
        #expect(layout.visualToLogicalCol[6] == 3)
        // The permutation must be a bijection over all columns.
        #expect(Set(layout.visualToLogicalCol).count == cols)
    }

    @Test func mixedLineKeepsLatinAndReversesHebrew() throws {
        let cols = 15
        let layout = try #require(layoutRow0(cols: cols, "abc שלום xyz"))
        // LTR paragraph (first strong is 'a'): Latin stays, Hebrew segment
        // is reversed in place.
        #expect(layout.logicalToVisualCol[0] == 0)   // a
        #expect(layout.logicalToVisualCol[2] == 2)   // c
        #expect(layout.logicalToVisualCol[4] == 7)   // ש takes the right end of its segment
        #expect(layout.logicalToVisualCol[5] == 6)   // ל
        #expect(layout.logicalToVisualCol[6] == 5)   // ו
        #expect(layout.logicalToVisualCol[7] == 4)   // ם
        #expect(layout.logicalToVisualCol[9] == 9)   // x
        #expect(layout.logicalToVisualCol[11] == 11) // z
    }

    @Test func forcedRTLParagraphReversesNeutralOnlyContext() throws {
        // With a forced RTL paragraph the row is right-aligned even though
        // it contains RTL content in an otherwise LTR context.
        let cols = 8
        let layout = try #require(layoutRow0(cols: cols, "אב 12", direction: .rightToLeft))
        #expect(layout.logicalToVisualCol[0] == 7)  // א rightmost
        #expect(layout.logicalToVisualCol[1] == 6)  // ב
        // Numbers read left-to-right even inside RTL text.
        #expect(layout.logicalToVisualCol[3] < layout.logicalToVisualCol[4])
    }

    // MARK: Arabic shaping

    @Test func arabicContextualForms() {
        // مرحبا: meem joins forward to reh; reh does not join forward, so hah
        // starts a new joined group with beh medial and alef final.
        let shaped = TerminalBidi.shapeArabic(cells: cells("مرحبا"))
        #expect(shaped[0] == Character(UnicodeScalar(0xFEE3)!))  // م initial
        #expect(shaped[1] == Character(UnicodeScalar(0xFEAE)!))  // ر final
        #expect(shaped[2] == Character(UnicodeScalar(0xFEA3)!))  // ح initial
        #expect(shaped[3] == Character(UnicodeScalar(0xFE92)!))  // ب medial
        #expect(shaped[4] == Character(UnicodeScalar(0xFE8E)!))  // ا final
    }

    @Test func isolatedLettersStayIsolated() {
        let shaped = TerminalBidi.shapeArabic(cells: cells("ء د"))
        #expect(shaped[0] == Character(UnicodeScalar(0xFE80)!))  // ء isolated
        #expect(shaped[2] == Character(UnicodeScalar(0xFEA9)!))  // د isolated
    }

    @Test func lamAlefLigature() {
        // Standalone lam+alef: isolated ligature in the lam cell, blank alef cell.
        var shaped = TerminalBidi.shapeArabic(cells: cells("لا"))
        #expect(shaped[0] == Character(UnicodeScalar(0xFEFB)!))
        #expect(shaped[1] == " ")
        // Preceded by a dual-joining letter: final ligature form.
        shaped = TerminalBidi.shapeArabic(cells: cells("بلا"))
        #expect(shaped[0] == Character(UnicodeScalar(0xFE91)!))  // ب initial
        #expect(shaped[1] == Character(UnicodeScalar(0xFEFC)!))  // لا final
        #expect(shaped[2] == " ")
    }

    @Test func latinTextIsNotShaped() {
        let shaped = TerminalBidi.shapeArabic(cells: cells("hello"))
        #expect(shaped.allSatisfy { $0 == nil })
    }

    @Test func harakatPreservedThroughShaping() {
        // A cell holding beh + fatha: the shaped display keeps the mark
        // after the presentation form.
        let cell = TerminalBidi.Cell(logicalCol: 0, width: 1, text: "\u{0628}\u{064E}")
        let next = TerminalBidi.Cell(logicalCol: 1, width: 1, text: "ب")
        let shaped = TerminalBidi.shapeArabic(cells: [cell, next])
        let display = shaped[0]!
        let scalars = Array(String(display).unicodeScalars)
        #expect(scalars.count == 2)
        #expect(scalars[0].value == 0xFE91)  // ب initial
        #expect(scalars[1].value == 0x064E)  // fatha retained

        // Lam-alef with a mark on the lam keeps the mark on the ligature.
        let lam = TerminalBidi.Cell(logicalCol: 0, width: 1, text: "\u{0644}\u{064E}")
        let alef = TerminalBidi.Cell(logicalCol: 1, width: 1, text: "ا")
        let ligated = TerminalBidi.shapeArabic(cells: [lam, alef])
        let ligScalars = Array(String(ligated[0]!).unicodeScalars)
        #expect(ligScalars[0].value == 0xFEFB)
        #expect(ligScalars.contains { $0.value == 0x064E })
    }

    @Test func wrappedRowContextPreservesJoining() {
        // A row ending mid-word: with a dual-joining letter following on the
        // wrapped row, the last beh must take its medial (not final) form.
        var shaped = TerminalBidi.shapeArabic(cells: cells("بب"),
                                              followingScalar: 0x0628)
        #expect(shaped[0] == Character(UnicodeScalar(0xFE91)!))  // ب initial
        #expect(shaped[1] == Character(UnicodeScalar(0xFE92)!))  // ب medial (joins into next row)

        // The continuation row: preceded by a dual-joining letter on the
        // previous row, its first beh is medial and its last is final.
        shaped = TerminalBidi.shapeArabic(cells: cells("بب"),
                                          precedingScalar: 0x0628)
        #expect(shaped[0] == Character(UnicodeScalar(0xFE92)!))  // ب medial
        #expect(shaped[1] == Character(UnicodeScalar(0xFE90)!))  // ب final

        // Right-joining context letters do not join forward across the seam.
        shaped = TerminalBidi.shapeArabic(cells: cells("بب"),
                                          precedingScalar: 0x0627)  // ا
        #expect(shaped[0] == Character(UnicodeScalar(0xFE91)!))  // ب initial (alef doesn't connect)
    }

    // MARK: Mirroring

    @Test func bracketsMirrorInRTLRuns() throws {
        let layout = try #require(layoutRow0(cols: 8, "(אב)"))
        // RTL paragraph: brackets resolve to RTL levels and must be mirrored.
        var overrides: [Int: Character] = [:]
        for cell in layout.visualCells where cell.display != nil {
            overrides[cell.logicalCol] = cell.display
        }
        #expect(overrides[0] == ")")
        #expect(overrides[3] == "(")
        // Reading the visual row left to right yields correctly balanced text.
        let logicalChars = Array("(אב)")
        let visualText = layout.visualCells.map { cell -> String in
            if let display = cell.display { return String(display) }
            return cell.logicalCol < logicalChars.count ? String(logicalChars[cell.logicalCol]) : " "
        }.joined()
        #expect(visualText.trimmingCharacters(in: .whitespaces) == "(בא)")
    }

    // MARK: Full pipeline

    @Test func arabicRowShapesAndReorders() throws {
        let cols = 10
        let layout = try #require(layoutRow0(cols: cols, "مرحبا"))
        // RTL paragraph: م is the rightmost cell.
        #expect(layout.logicalToVisualCol[0] == 9)
        #expect(layout.logicalToVisualCol[4] == 5)
        // The rightmost visual cell carries the shaped initial meem.
        let rightmost = try #require(layout.visualCells.last)
        #expect(rightmost.logicalCol == 0)
        #expect(rightmost.display == Character(UnicodeScalar(0xFEE3)!))
    }
}
#endif
