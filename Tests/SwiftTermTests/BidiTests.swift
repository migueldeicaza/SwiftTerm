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

    func makeTerminal(cols: Int, state: BidiPresentationState = .default,
                      feed text: String) -> Terminal {
        let options = TerminalOptions(cols: cols, rows: 4, initialBidiState: state)
        let terminal = Terminal(delegate: self, options: options)
        terminal.feed(text: text)
        return terminal
    }

    func layoutRow0(cols: Int, _ text: String,
                    state: BidiPresentationState = .default,
                    hostPolicy: BidiHostPolicy = .respectTerminal) -> BidiRowLayout? {
        let terminal = makeTerminal(cols: cols, state: state, feed: text)
        return TerminalBidi.layout(row: 0, buffer: terminal.buffer, cols: cols,
                                   terminal: terminal, font: font,
                                   hostPolicy: hostPolicy)
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
        #expect(layoutRow0(cols: 10, "שלום", hostPolicy: .legacyLeftToRight) == nil)
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

    @Test func continuationRowUsesTheFirstRowsParagraphContext() throws {
        let terminal = makeTerminal(cols: 3, feed: "אבג---")
        #expect(terminal.buffer.lines[1].isWrapped)
        let layout = try #require(TerminalBidi.layout(
            row: 1, buffer: terminal.buffer, cols: 3, terminal: terminal,
            font: font, hostPolicy: .respectTerminal))
        #expect(layout.logicalToVisualCol[0] == 2)
        #expect(layout.logicalToVisualCol[2] == 0)
    }

    @Test func eraseAndDeleteKeepContinuationParagraphContext() throws {
        let edits = [
            "\u{1b}[1;3H\u{1b}[K",
            "\u{1b}[1;2H\u{1b}[P",
        ]
        for edit in edits {
            let terminal = makeTerminal(cols: 3, feed: "אבג---")
            terminal.feed(text: edit)

            #expect(terminal.buffer.lines[1].isWrapped)
            let layout = try #require(TerminalBidi.layout(
                row: 1, buffer: terminal.buffer, cols: 3, terminal: terminal,
                font: font, hostPolicy: .respectTerminal))
            #expect(layout.baseDirection == .rightToLeft)
        }
    }

    @Test func paragraphRowCapUsesExplicitFallback() {
        let options = TerminalOptions(cols: 3, rows: 4, maximumBidiParagraphRows: 1)
        let terminal = Terminal(delegate: self, options: options)
        terminal.feed(text: "אבג---")
        #expect(TerminalBidi.layout(row: 1, buffer: terminal.buffer, cols: 3,
                                    terminal: terminal, font: font,
                                    hostPolicy: .respectTerminal) == nil)
    }

    @Test func renderingDependencyRangeIncludesTheWholeParagraph() {
        let terminal = makeTerminal(cols: 3, feed: "אבג---")
        #expect(terminal.buffer.lines[1].isWrapped)
        let range = TerminalBidi.renderingDependencyRange(
            rows: 1...1, buffer: terminal.buffer, maximumRows: 10)
        #expect(range == 0...1)
    }

    @Test func oversizedParagraphKeepsDependencyWorkBounded() {
        let buffer = Buffer(cols: 1, rows: 200, tabStopWidth: 8, scrollback: nil)
        buffer.fillViewportRows()
        for row in 1..<buffer.lines.count {
            buffer.lines[row].isWrapped = true
        }
        let range = TerminalBidi.renderingDependencyRange(
            rows: 100...100, buffer: buffer, maximumRows: 16)
        #expect(range == 100...100)
        #expect(TerminalBidi.layoutRevision(
            row: 100, buffer: buffer, maximumRows: 16) == 0)
    }

    @Test func forcedRTLParagraphReversesNeutralOnlyContext() throws {
        // With a forced RTL paragraph the row is right-aligned even though
        // it contains RTL content in an otherwise LTR context.
        let cols = 8
        let state = BidiPresentationState(autodetectDirection: false,
                                          fallbackDirection: .rightToLeft)
        let layout = try #require(layoutRow0(cols: cols, "אב 12", state: state))
        #expect(layout.logicalToVisualCol[0] == 7)  // א rightmost
        #expect(layout.logicalToVisualCol[1] == 6)  // ב
        // Numbers read left-to-right even inside RTL text.
        #expect(layout.logicalToVisualCol[3] < layout.logicalToVisualCol[4])
    }

    @Test func explicitRTLReversesCellsWithoutImplicitProcessing() throws {
        let cols = 8
        let state = BidiPresentationState(supportMode: .explicit,
                                          autodetectDirection: true,
                                          fallbackDirection: .rightToLeft)
        let layout = try #require(layoutRow0(cols: cols, "abאב", state: state))
        #expect(layout.baseDirection == .rightToLeft)
        #expect(layout.logicalToVisualCol[0] == 7)
        #expect(layout.logicalToVisualCol[1] == 6)
        #expect(layout.logicalToVisualCol[2] == 5)
        #expect(layout.logicalToVisualCol[3] == 4)

        let source = Array("abאב")
        let visual = layout.visualCells.map { cell in
            if let display = cell.display { return String(display) }
            return cell.logicalCol < source.count ? String(source[cell.logicalCol]) : " "
        }.joined()
        #expect(visual == "    באba")
    }

    @Test func explicitLTRAndLegacyPolicyDoNotCreateLayouts() {
        let explicitLTR = BidiPresentationState(supportMode: .explicit,
                                                autodetectDirection: true,
                                                fallbackDirection: .leftToRight)
        #expect(layoutRow0(cols: 8, "שלום", state: explicitLTR) == nil)

        let explicitRTL = BidiPresentationState(supportMode: .explicit,
                                                autodetectDirection: true,
                                                fallbackDirection: .rightToLeft)
        #expect(layoutRow0(cols: 8, "שלום", state: explicitRTL,
                           hostPolicy: .legacyLeftToRight) == nil)
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

    @Test func unicode17FormsCoverExtendedArabicLetters() {
        let shaped = TerminalBidi.shapeArabic(cells: cells("\u{067A}\u{067A}"))
        #expect(shaped[0] == Character(UnicodeScalar(0xFB60)!))
        #expect(shaped[1] == Character(UnicodeScalar(0xFB5F)!))
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
        let alef = TerminalBidi.Cell(logicalCol: 1, width: 1,
                                     text: "\u{0627}\u{0650}")
        let ligated = TerminalBidi.shapeArabic(cells: [lam, alef])
        let ligScalars = Array(String(ligated[0]!).unicodeScalars)
        #expect(ligScalars[0].value == 0xFEFB)
        #expect(ligScalars.contains { $0.value == 0x064E })
        #expect(ligScalars.contains { $0.value == 0x0650 })
    }

    @Test func fullParagraphPreservesJoiningAcrossWrapPoint() {
        let shaped = TerminalBidi.shapeArabic(cells: cells("بببب"))
        #expect(shaped[0] == Character(UnicodeScalar(0xFE91)!))
        #expect(shaped[1] == Character(UnicodeScalar(0xFE92)!))
        #expect(shaped[2] == Character(UnicodeScalar(0xFE92)!))
        #expect(shaped[3] == Character(UnicodeScalar(0xFE90)!))
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
