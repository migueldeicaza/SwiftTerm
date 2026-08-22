//
//  IndicWidthTests.swift
//
//  Spacing combining marks occupy a column. Non-spacing and enclosing marks do not.
//

#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

struct IndicWidthTests {

    /// Unicode general category Mc is a *spacing* combining mark: it advances the
    /// cursor. Grouping it with Mn and Me gives every Indic script zero width for its
    /// dependent vowel signs, so the glyphs overprint the base character instead of
    /// following it.
    @Test func spacingCombiningMarksOccupyAColumn() {
        let spacingMarks: [(UInt32, String)] = [
            (0x093E, "DEVANAGARI VOWEL SIGN AA"),
            (0x09BE, "BENGALI VOWEL SIGN AA"),
            (0x0982, "BENGALI SIGN ANUSVARA"),
            (0x0A3E, "GURMUKHI VOWEL SIGN AA"),
            (0x0ABE, "GUJARATI VOWEL SIGN AA"),
            (0x0B3E, "ORIYA VOWEL SIGN AA"),
            (0x0BBE, "TAMIL VOWEL SIGN AA"),
            (0x0C41, "TELUGU VOWEL SIGN U"),
            (0x0CBE, "KANNADA VOWEL SIGN AA"),
            (0x0D3E, "MALAYALAM VOWEL SIGN AA"),
        ]
        for (value, name) in spacingMarks {
            let scalar = Unicode.Scalar(value)!
            #expect(UnicodeUtil.columnWidth(rune: scalar) == 1,
                    "U+\(String(value, radix: 16, uppercase: true)) \(name) is Mc and should occupy one column")
        }
    }

    @Test func nonSpacingAndEnclosingMarksOccupyNothing() {
        let zeroWidth: [(UInt32, String)] = [
            (0x0300, "COMBINING GRAVE ACCENT"),           // Mn
            (0x0951, "DEVANAGARI STRESS SIGN UDATTA"),    // Mn
            (0x09CD, "BENGALI SIGN VIRAMA"),              // Mn
            (0x20DD, "COMBINING ENCLOSING CIRCLE"),       // Me
        ]
        for (value, name) in zeroWidth {
            let scalar = Unicode.Scalar(value)!
            #expect(UnicodeUtil.columnWidth(rune: scalar) == 0,
                    "U+\(String(value, radix: 16, uppercase: true)) \(name) should occupy no column")
        }
    }

    /// The whole point, end to end: a Bengali word must advance the cursor by one
    /// column per spacing character, so a following character is not drawn on top of it.
    @Test func bengaliWordAdvancesTheCursor() {
        // বাংলা — ব (base) া (Mc) ং (Mc) ল (base) া (Mc) = five columns.
        let word: [UInt32] = [0x09AC, 0x09BE, 0x0982, 0x09B2, 0x09BE]
        let width = word.reduce(0) { $0 + UnicodeUtil.columnWidth(rune: Unicode.Scalar($1)!) }
        #expect(width == 5, "expected five columns for বাংলা, got \(width)")
    }
}
#endif

/// A grapheme cluster may hold more than one spacing mark, and the whole cluster is
/// still worth one column for all of them together.
///
/// TAMIL VOWEL SIGN O is the case that shows it:
///
///     0BCA;TAMIL VOWEL SIGN O;Mc;0;L;0BC6 0BBE;;;;N;;;;;
///
/// Both scalars it decomposes to are `Mc`. Measuring per scalar makes the decomposed
/// form a column wider than the composed one, so the same text lands in different
/// places depending on how it was normalised — canonical equivalence broken.
@Suite struct CanonicalEquivalenceOfSpacingMarks {

    static func columns(after text: String) -> Int {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let terminal = h.terminal!
        terminal.feed(text: text)
        return terminal.getCursorLocation().x
    }

    /// Each of these consumes exactly one cell, composed or not.
    @Test func aLoneVowelSignTakesOneCell() {
        #expect(Self.columns(after: "\u{0BCA}") == 1)
        #expect(Self.columns(after: "\u{0BC6}") == 1)
        #expect(Self.columns(after: "\u{0BBE}") == 1)
        #expect(Self.columns(after: "\u{0BC6}\u{0BBE}") == 1)
    }

    @Test func composedAndDecomposedAgree() {
        // TAMIL VOWEL SIGN O, TAMIL VOWEL SIGN AU, MALAYALAM VOWEL SIGN O.
        let pairs = [("\u{0BCA}", "\u{0BC6}\u{0BBE}"),
                     ("\u{0BCC}", "\u{0BC6}\u{0BD7}"),
                     ("\u{0D4A}", "\u{0D46}\u{0D3E}")]
        for (composed, decomposed) in pairs {
            #expect(Self.columns(after: composed) == Self.columns(after: decomposed),
                    "composed and decomposed forms measured differently")
            #expect(Self.columns(after: "\u{0B95}" + composed)
                    == Self.columns(after: "\u{0B95}" + decomposed))
        }
    }

    /// The bug this whole change exists for: a consonant and its vowel sign are one
    /// glyph needing two columns, not one column with the glyphs on top of each other.
    @Test func aConsonantAndItsVowelSignTakeTwoCells() {
        #expect(Self.columns(after: "\u{0B95}") == 1)
        #expect(Self.columns(after: "\u{0B95}\u{0BCA}") == 2)
        #expect(Self.columns(after: "\u{0B95}\u{0BC6}\u{0BBE}") == 2)
        #expect(Self.columns(after: "\u{09AC}\u{09BE}") == 2)
    }

    @Test func ordinaryTextIsUntouched() {
        #expect(Self.columns(after: "ab") == 2)
        #expect(Self.columns(after: "世界") == 4)
    }

    /// The rule, without a terminal in the way.
    @Test func clusterWidthIsBasePlusOneForItsMarks() {
        #expect(UnicodeUtil.clusterWidth("\u{0BCA}") == 1)
        #expect(UnicodeUtil.clusterWidth("\u{0B95}\u{0BCA}") == 2)
        #expect(UnicodeUtil.clusterWidth("a") == 1)
        #expect(UnicodeUtil.clusterWidth("世") == 2)
        // Nonspacing marks add nothing, as before.
        #expect(UnicodeUtil.clusterWidth("e\u{0301}") == 1)
    }
}
