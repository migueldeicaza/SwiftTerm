#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics
import CoreText
import Foundation

/// A font in which printable ASCII shapes one character to one glyph, its
/// `cmap` glyph, with no shaping feature able to change it. For such a font
/// the Metal renderer maps a row of plain cells straight to glyphs instead of
/// building an attributed string and shaping it, and draws exactly what the
/// shaped path would.
///
/// The proof is the font's own tables. Core Text shapes with AAT `morx` when a
/// font has it and with OpenType otherwise, so a font qualifies only when it
/// has no `morx`, `mort`, `kern` or `GPOS` table and no feature settings, and
/// no `GSUB` lookup that a default-on feature could reach can apply to a run
/// made only of ASCII glyphs (`OpenTypeSubstitutionCheck`).
/// Shaping the repertoire through Core Text then confirms the result: one
/// glyph per character, the `cmap` glyph, on the baseline, in one font.
final class PlainTextFont {
    static let firstCode: UInt32 = 0x20
    static let lastCode: UInt32 = 0x7E

    /// The font Core Text reports for the shaped runs. Rasterizing and
    /// measuring with it gives the same atlas entries as the shaped path.
    let shapedFont: CTFont
    /// `glyphs[code - firstCode]` for every printable ASCII code.
    let glyphs: [CGGlyph]

    private init(shapedFont: CTFont, glyphs: [CGGlyph]) {
        self.shapedFont = shapedFont
        self.glyphs = glyphs
    }

    @inline(__always)
    func glyph(for code: UInt32) -> CGGlyph {
        glyphs[Int(code - Self.firstCode)]
    }

    static func isPlain(_ code: UInt32) -> Bool {
        code >= firstCode && code <= lastCode
    }

    /// The analysis, or nil when the font does not qualify.
    static func analyze(_ font: CTFont) -> PlainTextFont? {
        // The table check counts optional features as off, so a font with
        // feature settings is shaped.
        if let settings = CTFontCopyFeatureSettings(font), CFArrayGetCount(settings) > 0 {
            return nil
        }
        let tables = availableTables(font)
        for excluded in ["morx", "mort", "kern", "GPOS"] where tables.contains(tag(excluded)) {
            return nil
        }
        let count = Int(lastCode - firstCode + 1)
        var characters = (0..<count).map { UniChar(firstCode + UInt32($0)) }
        var glyphs = [CGGlyph](repeating: 0, count: count)
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, count),
              !glyphs.contains(0) else {
            return nil
        }
        if tables.contains(tag("GSUB")) {
            guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableGSUB), []) as Data?,
                  OpenTypeSubstitutionCheck.canChange(runsOf: Set(glyphs), gsub: table) == false else {
                return nil
            }
        }
        // Each character alone, and the whole repertoire in a run, forward
        // and reversed.
        var shapedFont: CTFont?
        let repertoire = String(decoding: characters, as: UTF16.self)
        let samples = characters.map { String(decoding: [$0], as: UTF16.self) }
            + [repertoire, String(repertoire.reversed())]
        for sample in samples {
            let expected = sample.utf16.map { glyphs[Int(UInt32($0) - firstCode)] }
            guard let runFont = shapesOneToOne(sample, font: font, expected: expected) else {
                return nil
            }
            if let shapedFont {
                guard CFEqual(shapedFont, runFont) else { return nil }
            } else {
                shapedFont = runFont
            }
        }
        guard let shapedFont else { return nil }
        return PlainTextFont(shapedFont: shapedFont, glyphs: glyphs)
    }

    /// Shapes `text` as the renderer's shaper does and returns the run font
    /// when the result is `expected`, one glyph per UTF-16 unit, in string
    /// order, on the baseline, in a single font.
    private static func shapesOneToOne(_ text: String, font: CTFont, expected: [CGGlyph]) -> CTFont? {
        let writingDirectionKey = NSAttributedString.Key(kCTWritingDirectionAttributeName as String)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            writingDirectionKey: [NSNumber(value: 2)],
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return nil }
        var runFont: CTFont?
        var index = 0
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName as String] else { return nil }
            let font = value as! CTFont
            if let runFont {
                guard CFEqual(runFont, font) else { return nil }
            } else {
                runFont = font
            }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetStringIndices(run, CFRange(), &indices)
            for i in 0..<count {
                guard index < expected.count, glyphs[i] == expected[index],
                      indices[i] == index, positions[i].y == 0 else {
                    return nil
                }
                index += 1
            }
        }
        return index == expected.count ? runFont : nil
    }

    private static func tag(_ string: String) -> CTFontTableTag {
        string.utf8.reduce(0) { $0 << 8 | CTFontTableTag($1) }
    }

    private static func availableTables(_ font: CTFont) -> Set<CTFontTableTag> {
        var tables = Set<CTFontTableTag>()
        guard let array = CTFontCopyAvailableTables(font, []) else { return tables }
        // The array holds the tags themselves, not CFNumbers.
        for index in 0..<CFArrayGetCount(array) {
            tables.insert(CTFontTableTag(UInt(bitPattern: CFArrayGetValueAtIndex(array, index))))
        }
        return tables
    }
}

/// Reads an OpenType `GSUB` table far enough to decide whether glyph
/// substitution could change a run made only of a given set of glyphs.
///
/// Every substitution starts where a lookup's coverage matches a glyph, and a
/// contextual rule also needs each glyph of its context present in the run.
/// So when no lookup reachable from a feature that may be on by default has
/// coverage in the set (or, for a contextual rule, has a context position
/// with no glyph of the set), no substitution can apply. Anything this reader
/// does not understand counts as "could change".
enum OpenTypeSubstitutionCheck {
    /// Features Core Text leaves off unless asked: stylistic sets, character
    /// variants, case and number forms, small caps, vertical forms and the
    /// like. Everything else is treated as possibly on.
    static let optionalFeatures: Set<String> = [
        "aalt", "afrc", "c2pc", "c2sc", "case", "cpsp", "dlig", "dnom", "expt", "frac", "fwid",
        "halt", "hist", "hkna", "hlig", "hngl", "hojo", "hwid", "ital", "jp04", "jp78", "jp83",
        "jp90", "lnum", "mgrk", "nalt", "nlck", "numr", "onum", "ordn", "ornm", "palt", "pcap",
        "pkna", "pnum", "pwid", "qwid", "ruby", "salt", "sinf", "smcp", "smpl", "subs", "sups",
        "swsh", "titl", "tnam", "tnum", "trad", "twid", "unic", "valt", "vert", "vhal", "vkna",
        "vkrn", "vpal", "vrt2", "vrtr", "zero",
    ]

    static func isOptional(_ feature: String) -> Bool {
        if optionalFeatures.contains(feature) { return true }
        // ss01-ss20, cv01-cv99.
        let prefix = feature.prefix(2)
        return (prefix == "ss" || prefix == "cv") && feature.dropFirst(2).allSatisfy(\.isNumber)
    }

    /// True when a substitution could change such a run, false when none can,
    /// nil when the table is malformed.
    static func canChange(runsOf glyphs: Set<CGGlyph>, gsub: Data) -> Bool? {
        let table = Table(bytes: [UInt8](gsub))
        return table.canChange(runsOf: Set(glyphs.map(Int.init)))
    }

    private struct Malformed: Error {}

    private struct Table {
        let bytes: [UInt8]

        func u16(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 2 <= bytes.count else { throw Malformed() }
            return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        }

        func u32(_ offset: Int) throws -> Int {
            try u16(offset) << 16 | u16(offset + 2)
        }

        func tag(_ offset: Int) throws -> String {
            guard offset >= 0, offset + 4 <= bytes.count else { throw Malformed() }
            return String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
        }

        func canChange(runsOf glyphs: Set<Int>) -> Bool? {
            do {
                let minor = try u16(2)
                // Feature variations swap lookups in by font variation
                // coordinates; not worth reading.
                if minor >= 1, try u32(10) != 0 { return true }
                let scriptList = try u16(4)
                let featureList = try u16(6)
                let lookupList = try u16(8)
                var features = Set<Int>()
                for script in 0..<(try u16(scriptList)) {
                    let scriptTable = scriptList + (try u16(scriptList + 2 + script * 6 + 4))
                    var languageSystems: [Int] = []
                    let defaultOffset = try u16(scriptTable)
                    if defaultOffset != 0 { languageSystems.append(scriptTable + defaultOffset) }
                    for language in 0..<(try u16(scriptTable + 2)) {
                        languageSystems.append(scriptTable + (try u16(scriptTable + 4 + language * 6 + 4)))
                    }
                    for system in languageSystems {
                        let required = try u16(system + 2)
                        if required != 0xFFFF { features.insert(required) }
                        for index in 0..<(try u16(system + 4)) {
                            features.insert(try u16(system + 6 + index * 2))
                        }
                    }
                }
                var lookups = Set<Int>()
                let featureCount = try u16(featureList)
                for feature in features {
                    guard feature < featureCount else { throw Malformed() }
                    let record = featureList + 2 + feature * 6
                    if isOptional(try tag(record)) { continue }
                    let featureTable = featureList + (try u16(record + 4))
                    for index in 0..<(try u16(featureTable + 2)) {
                        lookups.insert(try u16(featureTable + 4 + index * 2))
                    }
                }
                let lookupCount = try u16(lookupList)
                for lookup in lookups {
                    guard lookup < lookupCount else { throw Malformed() }
                    let lookupTable = lookupList + (try u16(lookupList + 2 + lookup * 2))
                    let type = try u16(lookupTable)
                    for index in 0..<(try u16(lookupTable + 4)) {
                        let subtable = lookupTable + (try u16(lookupTable + 6 + index * 2))
                        if try subtableCanApply(type: type, at: subtable, glyphs: glyphs) {
                            return true
                        }
                    }
                }
                return false
            } catch {
                return nil
            }
        }

        private func subtableCanApply(type: Int, at subtable: Int, glyphs: Set<Int>) throws -> Bool {
            let format = try u16(subtable)
            switch type {
            case 1, 2, 3, 4:
                return try coverage(at: subtable + (try u16(subtable + 2)), intersects: glyphs)
            case 5 where format == 3:
                let count = try u16(subtable + 2)
                for index in 0..<count {
                    if !(try coverage(at: subtable + (try u16(subtable + 6 + index * 2)), intersects: glyphs)) {
                        return false
                    }
                }
                return true
            case 6 where format == 3:
                var offset = subtable + 2
                for _ in 0..<3 {
                    let count = try u16(offset)
                    for index in 0..<count {
                        if !(try coverage(at: subtable + (try u16(offset + 2 + index * 2)), intersects: glyphs)) {
                            return false
                        }
                    }
                    offset += 2 + count * 2
                }
                return true
            case 5, 6:
                // Glyph- and class-based rules: their first glyph's coverage.
                return try coverage(at: subtable + (try u16(subtable + 2)), intersects: glyphs)
            case 7:
                guard format == 1 else { return true }
                let extensionType = try u16(subtable + 2)
                guard extensionType != 7 else { throw Malformed() }
                return try subtableCanApply(type: extensionType, at: subtable + (try u32(subtable + 4)),
                                            glyphs: glyphs)
            case 8:
                return try coverage(at: subtable + (try u16(subtable + 2)), intersects: glyphs)
            default:
                return true
            }
        }

        private func coverage(at offset: Int, intersects glyphs: Set<Int>) throws -> Bool {
            switch try u16(offset) {
            case 1:
                for index in 0..<(try u16(offset + 2)) where glyphs.contains(try u16(offset + 4 + index * 2)) {
                    return true
                }
                return false
            case 2:
                for index in 0..<(try u16(offset + 2)) {
                    let record = offset + 4 + index * 6
                    let start = try u16(record)
                    let end = try u16(record + 2)
                    guard start <= end else { throw Malformed() }
                    if glyphs.contains(where: { $0 >= start && $0 <= end }) { return true }
                }
                return false
            default:
                throw Malformed()
            }
        }
    }
}
#endif

#endif // !SWIFTTERM_EMBEDDED
