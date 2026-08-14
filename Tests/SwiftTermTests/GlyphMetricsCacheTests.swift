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

    private func glyphEntry(marker: Int = 0) -> GlyphEntry {
        GlyphEntry(region: AtlasRegion(x: marker, y: 0, width: 1, height: 1),
                   size: CGSize(width: 1, height: 1),
                   bearing: .zero,
                   isColor: false,
                   atlasKind: .grayscale)
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

    @Test func metricsRolloverDoesNotChangeRasterKey() throws {
        let first = font()
        let equivalent = font()
        let differentFittingFont = font("Menlo-Bold")
        let glyph = try glyph(for: 0x57, in: first)
        let cache = GlyphMetricsCache(maxEntries: 8, maxFonts: 1)
        let rasterFonts = RasterFontRegistry(maxFonts: 8)

        let firstMetricsFont = cache.intern(font: first, fittingFont: first)
        let firstRasterToken = try #require(rasterFonts.intern(first))
        let secondMetricsFont = cache.intern(font: first,
                                             fittingFont: differentFittingFont)
        let secondRasterToken = try #require(rasterFonts.intern(equivalent))

        #expect(firstMetricsFont.token != secondMetricsFont.token)
        #expect(firstRasterToken == secondRasterToken)
        #expect(GlyphKey(rasterFontToken: firstRasterToken, glyph: glyph) ==
                GlyphKey(rasterFontToken: secondRasterToken, glyph: glyph))
    }

    @Test func equivalentMetricsContextsReuseOneToken() {
        let firstRasterFont = font(size: 32)
        let secondRasterFont = font(size: 32)
        let firstFittingFont = font(size: 16)
        let secondFittingFont = font(size: 16)
        let cache = GlyphMetricsCache(maxEntries: 8)

        let first = cache.intern(font: firstRasterFont,
                                 fittingFont: firstFittingFont,
                                 renderingScale: 2)
        let second = cache.intern(font: secondRasterFont,
                                  fittingFont: secondFittingFont,
                                  renderingScale: 2)
        #expect(first.token == second.token)
        #expect(cache.fontRegistryCount == 1)
    }

    @Test func rasterFontTokensReuseEquivalentFonts() throws {
        let normal = font()
        let equivalent = font()
        let registry = RasterFontRegistry(maxFonts: 8)

        let normalToken = try #require(registry.intern(normal))
        #expect(registry.intern(normal) == normalToken)
        #expect(registry.intern(equivalent) == normalToken)
        #expect(registry.count == 1)
    }

    @Test func fittingContextDoesNotChangeRasterFontToken() throws {
        let rasterFont = font(size: 32)
        let fittingContexts: [(font: CTFont, scale: CGFloat)] = [
            (font(size: 16), 2),
            (font("Menlo-Bold", size: 16), 2),
            (font(size: 32), 1),
        ]
        let registry = RasterFontRegistry(maxFonts: 8)
        let expected = try #require(registry.intern(rasterFont))

        for context in fittingContexts {
            // Fitting font and scale belong to the metrics registry only.
            _ = context
            #expect(registry.intern(rasterFont) == expected)
        }
        #expect(registry.count == 1)
    }

    @Test func rasterFontTokensDistinguishRasterConfiguration() throws {
        let normal = font()
        let larger = font(size: 20)
        var matrix = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
        let transformed = CTFontCreateCopyWithAttributes(normal, pointSize, &matrix, nil)
        let registry = RasterFontRegistry(maxFonts: 8)

        let normalToken = try #require(registry.intern(normal))
        #expect(registry.intern(larger) != normalToken)
        #expect(registry.intern(transformed) != normalToken)
        if let variable = variableFontPair() {
            #expect(registry.intern(variable.0) != registry.intern(variable.1))
        }
    }

    @Test func rasterRegistryTeardownDoesNotReuseToken() throws {
        let registry = RasterFontRegistry(maxFonts: 1)
        let firstToken = try #require(registry.intern(font()))
        #expect(registry.intern(font("Menlo-Bold")) == nil)

        registry.removeAll()
        let secondToken = try #require(registry.intern(font("Menlo-Bold")))
        #expect(secondToken != firstToken)
        #expect(GlyphKey(rasterFontToken: firstToken, glyph: 1) !=
                GlyphKey(rasterFontToken: secondToken, glyph: 1))
    }

    @Test func metricsIdentityIncludesFittingContext() throws {
        let rasterFont = font(size: 32)
        let firstFittingFont = font(size: 16)
        let secondFittingFont = font(size: 24)
        let glyph = try glyph(for: 0x57, in: rasterFont)
        let cache = GlyphMetricsCache(maxEntries: 8)
        var first = cache.intern(font: rasterFont,
                                 fittingFont: firstFittingFont,
                                 renderingScale: 2)
        var second = cache.intern(font: rasterFont,
                                  fittingFont: secondFittingFont,
                                  renderingScale: 2)
        var third = cache.intern(font: rasterFont,
                                 fittingFont: firstFittingFont,
                                 renderingScale: 1)

        #expect(first.token != second.token)
        #expect(first.token != third.token)
        let firstLookup = cache.metrics(font: &first, glyph: glyph)
        let secondLookup = cache.metrics(font: &second, glyph: glyph)
        let thirdLookup = cache.metrics(font: &third, glyph: glyph)
        #expect(!firstLookup.wasHit)
        #expect(!secondLookup.wasHit)
        #expect(!thirdLookup.wasHit)
        #expect(firstLookup.metrics.horizontalAdvance != secondLookup.metrics.horizontalAdvance)
        #expect(firstLookup.metrics.horizontalAdvance != thirdLookup.metrics.horizontalAdvance)
        #expect(cache.metrics(font: &first, glyph: glyph).wasHit)
        #expect(cache.metrics(font: &second, glyph: glyph).wasHit)
        #expect(cache.metrics(font: &third, glyph: glyph).wasHit)
    }

    @Test func fittingContextsShareOneBitmapResult() throws {
        let rasterFont = font(size: 32)
        let glyph = try glyph(for: 0x57, in: rasterFont)
        let registry = RasterFontRegistry(maxFonts: 8)
        let token = try #require(registry.intern(rasterFont))
        let key = GlyphKey(rasterFontToken: token, glyph: glyph)
        let bitmapCache = GlyphBitmapResultCache()
        let metricsCache = GlyphMetricsCache(maxEntries: 8)
        var firstMetricsFont = metricsCache.intern(font: rasterFont,
                                                   fittingFont: font(size: 16),
                                                   renderingScale: 2)
        var secondMetricsFont = metricsCache.intern(font: rasterFont,
                                                    fittingFont: font(size: 24),
                                                    renderingScale: 2)
        var rasterizationCount = 0
        var metricsLookupCount = 0

        func resolveBitmap(metricsFont: inout GlyphMetricsFont) -> ResolvedGlyph? {
            switch bitmapCache.lookup(key) {
            case .drawable(let entry):
                return ResolvedGlyph(entry: entry, metricsFromMiss: nil)
            case .permanentEmpty:
                return nil
            case .miss:
                metricsLookupCount += 1
                let metrics = metricsCache.metrics(font: &metricsFont,
                                                   glyph: glyph).metrics
                rasterizationCount += 1
                let entry = glyphEntry(marker: rasterizationCount)
                bitmapCache.storeDrawable(entry, for: key)
                return ResolvedGlyph(entry: entry, metricsFromMiss: metrics)
            }
        }

        let first = try #require(resolveBitmap(metricsFont: &firstMetricsFont))
        let firstFit = first.fitMetrics(columnWidth: 2) {
            metricsLookupCount += 1
            return metricsCache.metrics(font: &firstMetricsFont,
                                        glyph: glyph).metrics
        }
        let second = try #require(resolveBitmap(metricsFont: &secondMetricsFont))
        let secondFit = second.fitMetrics(columnWidth: 2) {
            metricsLookupCount += 1
            return metricsCache.metrics(font: &secondMetricsFont,
                                        glyph: glyph).metrics
        }

        #expect(rasterizationCount == 1)
        #expect(first.entry.region.x == second.entry.region.x)
        #expect(firstFit.origin == .drawableMiss)
        #expect(secondFit.origin == .metricsCache)
        #expect(firstFit.metrics?.horizontalAdvance != secondFit.metrics?.horizontalAdvance)
        // The miss reuses its metrics. The hit gets the second context once.
        #expect(metricsLookupCount == 2)
    }

    @Test func fitMetricsLookupPolicyUsesTheMinimumQueries() {
        let metrics = GlyphMetrics(inkBounds: CGRect(x: 0, y: 0, width: 8, height: 12),
                                   horizontalAdvance: 8,
                                   fontSize: pointSize,
                                   fitInkSizeScale: 1)
        let entry = glyphEntry()
        let drawableHit = ResolvedGlyph(entry: entry, metricsFromMiss: nil)
        let drawableMiss = ResolvedGlyph(entry: entry, metricsFromMiss: metrics)
        var lookupCount = 0
        let lookup: () -> GlyphMetrics = {
            lookupCount += 1
            return metrics
        }

        let narrowHit = drawableHit.fitMetrics(columnWidth: 1, lookup: lookup)
        #expect(narrowHit.metrics == nil)
        #expect(lookupCount == 0)

        let wideHit = drawableHit.fitMetrics(columnWidth: 2, lookup: lookup)
        #expect(wideHit.metrics?.horizontalAdvance == metrics.horizontalAdvance)
        #expect(lookupCount == 1)

        let wideMiss = drawableMiss.fitMetrics(columnWidth: 2, lookup: lookup)
        #expect(wideMiss.metrics?.inkBounds == metrics.inkBounds)
        #expect(lookupCount == 1)
    }

    @Test func emptyResultsSurviveAtlasResetAndClearOnRegistryTeardown() {
        let cache = GlyphBitmapResultCache(maximumEmptyEntries: 2)
        let key = GlyphKey(rasterFontToken: 1, glyph: 10)
        cache.storePermanentEmpty(key)

        if case .permanentEmpty = cache.lookup(key) {
            // Expected for another fitting context with the same raster key.
        } else {
            Issue.record("permanent-empty result was not reused")
        }
        cache.removeDrawables()
        if case .permanentEmpty = cache.lookup(key) {
            // Atlas reset preserves the permanent-empty result.
        } else {
            Issue.record("atlas reset removed a permanent-empty result")
        }
        cache.removeAll()
        if case .miss = cache.lookup(key) {
            // Raster-font registry teardown clears both result caches.
        } else {
            Issue.record("registry teardown kept a permanent-empty result")
        }
    }

    @Test func transientBitmapFailureIsRetried() {
        let cache = GlyphBitmapResultCache()
        let key = GlyphKey(rasterFontToken: 1, glyph: 10)
        var attempts = 0

        func resolveBitmap() -> GlyphEntry? {
            switch cache.lookup(key) {
            case .drawable(let entry):
                return entry
            case .permanentEmpty:
                return nil
            case .miss:
                attempts += 1
                guard attempts > 1 else { return nil }
                let entry = glyphEntry()
                cache.storeDrawable(entry, for: key)
                return entry
            }
        }

        #expect(resolveBitmap() == nil)
        #expect(resolveBitmap() != nil)
        #expect(resolveBitmap() != nil)
        #expect(attempts == 2)
    }

    @Test func permanentEmptyCacheIsBoundedAndFontSpecific() {
        let cache = PermanentEmptyGlyphCache(maxEntries: 2)
        let first = GlyphKey(rasterFontToken: 1, glyph: 10)
        let second = GlyphKey(rasterFontToken: 2, glyph: 10)
        let third = GlyphKey(rasterFontToken: 1, glyph: 11)

        cache.insert(first)
        #expect(cache.contains(first))
        #expect(!cache.contains(second))
        cache.insert(second)
        #expect(cache.count == 2)
        #expect(cache.highWaterCount == 2)

        cache.insert(third)
        #expect(cache.evictionCount == 1)
        #expect(cache.count == 1)
        #expect(cache.contains(third))
        #expect(!cache.contains(first))
        #expect(!cache.contains(second))
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
