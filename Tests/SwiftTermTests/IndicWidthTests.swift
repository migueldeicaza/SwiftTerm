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
