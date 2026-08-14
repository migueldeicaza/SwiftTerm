#if os(macOS)
import CoreText
import Metal
import Testing

@testable import SwiftTerm

struct GlyphMetricsCacheTests {
    private let pointSize: CGFloat = 16

    private func font(_ name: String = "Menlo-Regular", size: CGFloat = 16) -> CTFont {
        CTFontCreateWithName(name as CFString, size, nil)
    }

    private func resolvedFont(for text: String, base: CTFont) -> CTFont {
        CTFontCreateForString(base, text as CFString,
                              CFRange(location: 0, length: (text as NSString).length))
    }

    private func glyph(for character: UniChar, in font: CTFont) throws -> CGGlyph {
        var character = character
        var glyph: CGGlyph = 0
        try #require(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
        return glyph
    }

    private func expectEqual(_ actual: GlyphMetrics, _ expected: GlyphMetrics) {
        #expect(actual.inkBounds == expected.inkBounds)
        #expect(actual.horizontalAdvance == expected.horizontalAdvance)
        #expect(actual.fontSize == expected.fontSize)
        #expect(actual.fitInkSizeScale == expected.fitInkSizeScale)
    }

    @Test func repeatedFontAndGlyphHasOneMissThenOneHit() throws {
        let normal = font()
        let glyph = try glyph(for: 0x57, in: normal)
        let cache = GlyphMetricsCache(maxEntries: 8)
        var token = cache.intern(font: normal)
        let expected = GlyphMetrics.measure(font: normal, glyph: glyph)

        let first = cache.metrics(font: &token, glyph: glyph)
        let second = cache.metrics(font: &token, glyph: glyph)

        #expect(!first.wasHit)
        #expect(second.wasHit)
        expectEqual(first.metrics, expected)
        expectEqual(second.metrics, expected)
        #expect(cache.count == 1)
#if DEBUG
        #expect(cache.missCount == 1)
        #expect(cache.hitCount == 1)
#endif
    }

    @Test func differentGlyphIDsDoNotAlias() throws {
        let normal = font()
        let firstGlyph = try glyph(for: 0x57, in: normal)
        let secondGlyph = try glyph(for: 0x4d, in: normal)
        try #require(firstGlyph != secondGlyph)
        let cache = GlyphMetricsCache(maxEntries: 8)
        var token = cache.intern(font: normal)

        for glyph in [firstGlyph, secondGlyph] {
            let lookup = cache.metrics(font: &token, glyph: glyph)
            #expect(!lookup.wasHit)
            expectEqual(lookup.metrics, GlyphMetrics.measure(font: normal, glyph: glyph))
        }
        #expect(cache.count == 2)
    }

    @Test func distinctFontObjectsDoNotAlias() throws {
        let first = font()
        var matrix = CGAffineTransform(a: 1, b: 0, c: 0.01, d: 1, tx: 0, ty: 0)
        let second = CTFontCreateCopyWithAttributes(first, pointSize, &matrix, nil)
        try #require(ObjectIdentifier(first) != ObjectIdentifier(second))
        let glyph = try glyph(for: 0x57, in: first)
        let cache = GlyphMetricsCache(maxEntries: 8)
        var firstToken = cache.intern(font: first)
        var secondToken = cache.intern(font: second)

        #expect(firstToken.token != secondToken.token)
        #expect(!cache.metrics(font: &firstToken, glyph: glyph).wasHit)
        #expect(!cache.metrics(font: &secondToken, glyph: glyph).wasHit)
        #expect(cache.count == 2)
    }

    @Test func styleFallbackAndVariableFontsDoNotAlias() throws {
        let normal = font()
        let bold = font("Menlo-Bold")
        let italic = font("Menlo-Italic")
        let fallback = resolvedFont(for: "界", base: normal)
        var cases: [(CTFont, CGGlyph)] = [
            (normal, try glyph(for: 0x57, in: normal)),
            (bold, try glyph(for: 0x57, in: bold)),
            (italic, try glyph(for: 0x57, in: italic)),
            (fallback, try glyph(for: 0x754c, in: fallback))
        ]
        if let variable = variableFontPair() {
            cases.append((variable.0, try glyph(for: 0x57, in: variable.0)))
            cases.append((variable.1, try glyph(for: 0x57, in: variable.1)))
        }
        let cache = GlyphMetricsCache(maxEntries: 16)
        var tokens: [UInt32] = []

        for (caseFont, caseGlyph) in cases {
            var token = cache.intern(font: caseFont)
            tokens.append(token.token)
            let lookup = cache.metrics(font: &token, glyph: caseGlyph)
            #expect(!lookup.wasHit)
            expectEqual(lookup.metrics,
                        GlyphMetrics.measure(font: caseFont, glyph: caseGlyph))
        }

        #expect(Set(tokens).count == cases.count)
        #expect(cache.fontRegistryCount == cases.count)
    }

    @Test func atlasResetDoesNotRemoveMetrics() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let atlas = GlyphAtlas(device: device, size: 256, maxSize: 256,
                                     format: .grayscale) else { return }
        let normal = font()
        let glyph = try glyph(for: 0x57, in: normal)
        let cache = GlyphMetricsCache(maxEntries: 8)
        var token = cache.intern(font: normal)
        #expect(!cache.metrics(font: &token, glyph: glyph).wasHit)

        _ = atlas.ensureRegion(width: 200, height: 200)
        _ = atlas.ensureRegion(width: 200, height: 200)
        try #require(atlas.didReset)

        #expect(cache.metrics(font: &token, glyph: glyph).wasHit)
        #expect(cache.count == 1)
    }

    @Test func backingScaleSelectsScaledMetrics() throws {
        let normal = font()
        let glyph = try glyph(for: 0x57, in: normal)
        let cache = GlyphMetricsCache(maxEntries: 8)
        var tokens: [UInt32] = []

        for scale: CGFloat in [1, 2, 3] {
            let scaled = CTFontCreateCopyWithAttributes(
                normal, CTFontGetSize(normal) * scale, nil, nil)
            var token = cache.intern(font: scaled)
            tokens.append(token.token)
            let lookup = cache.metrics(font: &token, glyph: glyph)
            expectEqual(lookup.metrics, GlyphMetrics.measure(font: scaled, glyph: glyph))
            #expect(lookup.metrics.fontSize == pointSize * scale)
        }

        #expect(Set(tokens).count == 3)
    }

    @Test func evictionDoesNotReuseLiveToken() throws {
        let first = font()
        let second = font("Menlo-Bold")
        let cache = GlyphMetricsCache(maxEntries: 2, maxFonts: 4)
        var firstToken = cache.intern(font: first)
        let originalToken = firstToken.token
        let originalGeneration = firstToken.generation

        for glyph in [CGGlyph(1), CGGlyph(2), CGGlyph(3)] {
            _ = cache.metrics(font: &firstToken, glyph: glyph)
        }
        #expect(firstToken.generation != originalGeneration)
        #expect(firstToken.token != originalToken)

        let secondToken = cache.intern(font: second)
        #expect(secondToken.token != originalToken)
        #expect(secondToken.token != firstToken.token)
    }

    @Test func cacheAndRegistryStayWithinBounds() {
        let cache = GlyphMetricsCache(maxEntries: 3, maxFonts: 2)
        let fonts = [font(), font("Menlo-Bold"), font("Menlo-Italic")]

        for (fontIndex, caseFont) in fonts.enumerated() {
            var token = cache.intern(font: caseFont)
            for glyphValue in 1...4 {
                _ = cache.metrics(font: &token,
                                  glyph: CGGlyph(fontIndex * 10 + glyphValue))
                #expect(cache.count <= cache.maxEntries)
                #expect(cache.fontRegistryCount <= cache.maxFonts)
            }
        }
    }

    @Test func metricsRolloverDoesNotChangeAtlasKey() throws {
        let first = font()
        let equivalent = font()
        let glyph = try glyph(for: 0x57, in: first)
        let cache = GlyphMetricsCache(maxEntries: 8, maxFonts: 1)

        let firstMetricsFont = cache.intern(font: first)
        let secondMetricsFont = cache.intern(font: equivalent)

        #expect(firstMetricsFont.token != secondMetricsFont.token)
        #expect(GlyphKey(font: first, glyph: glyph) ==
                GlyphKey(font: equivalent, glyph: glyph))
    }

    private func variableFontPair() -> (CTFont, CTFont)? {
        for name in ["Skia", ".AppleSystemUIFont"] {
            let base = font(name)
            guard let axes = CTFontCopyVariationAxes(base) as? [[CFString: Any]] else {
                continue
            }
            for axis in axes {
                guard let identifier = axis[kCTFontVariationAxisIdentifierKey] as? NSNumber,
                      let minimum = axis[kCTFontVariationAxisMinimumValueKey] as? NSNumber,
                      let maximum = axis[kCTFontVariationAxisMaximumValueKey] as? NSNumber,
                      minimum.doubleValue < maximum.doubleValue else { continue }
                return (variedFont(base: base, axis: identifier, value: minimum),
                        variedFont(base: base, axis: identifier, value: maximum))
            }
        }
        return nil
    }

    private func variedFont(base: CTFont, axis: NSNumber, value: NSNumber) -> CTFont {
        let attributes: [CFString: Any] = [
            kCTFontVariationAttribute: [axis: value] as [NSNumber: NSNumber]
        ]
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base), attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, CTFontGetSize(base), nil)
    }
}
#endif
