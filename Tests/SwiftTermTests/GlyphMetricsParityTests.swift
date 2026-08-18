#if os(macOS)
import CoreText
import Foundation
import Testing

@testable import SwiftTerm

struct GlyphMetricsParityTests {
    private let pointSize: CGFloat = 16
    // Fixed color-bitmap strikes contain 1e-4 Core Text rounding noise when
    // their strike coordinates are converted to the requested pixel space.
    private let tolerance: CGFloat = 0.000_1

    private func font(_ name: String = "Menlo-Regular", size: CGFloat = 16) -> CTFont {
        CTFontCreateWithName(name as CFString, size, nil)
    }

    private func shapedGlyph(_ text: String, base: CTFont) throws -> (CTFont, CGGlyph) {
        let resolved = CTFontCreateForString(base, text as CFString,
                                             CFRange(location: 0,
                                                     length: (text as NSString).length))
        let key = NSAttributedString.Key(kCTFontAttributeName as String)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [key: resolved]))
        let runs = CTLineGetGlyphRuns(line) as NSArray
        let firstRun = try #require(runs.firstObject)
        let run = firstRun as! CTRun
        let count = CTRunGetGlyphCount(run)
        try #require(count > 0)
        var glyph: CGGlyph = 0
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
        let attributes = CTRunGetAttributes(run) as NSDictionary
        let actualFont = attributes[kCTFontAttributeName].map { $0 as! CTFont } ?? resolved
        return (actualFont, glyph)
    }

    private func expectEqual(_ actual: GlyphSlotFit,
                             _ expected: GlyphSlotFit,
                             context: String = "",
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(actual.dx - expected.dx) <= tolerance,
                "\(context): horizontal offset",
                sourceLocation: sourceLocation)
        #expect(abs(actual.dy - expected.dy) <= tolerance,
                "\(context): vertical offset",
                sourceLocation: sourceLocation)
        #expect(abs(actual.scale - expected.scale) <= tolerance,
                "\(context): scale",
                sourceLocation: sourceLocation)
    }

    private func scaledFit(font glyphFont: CTFont,
                           glyph: CGGlyph,
                           columnWidth: Int,
                           cellDimension: CGSize,
                           normalFont: CTFont,
                           renderingScale: CGFloat) -> GlyphSlotFit {
        let scaledFont = CTFontCreateCopyWithAttributes(
            glyphFont, CTFontGetSize(glyphFont) * renderingScale, nil, nil)
        let metrics = GlyphMetrics.measure(font: scaledFont, glyph: glyph,
                                           fittingFont: glyphFont,
                                           renderingScale: renderingScale)
        return GlyphSlotFit.calculate(
            metrics: metrics,
            columnWidth: columnWidth,
            cellDimension: cellDimension,
            baselineFromBottom: ceil(CTFontGetDescent(normalFont) +
                                     CTFontGetLeading(normalFont)),
            renderingScale: renderingScale)
    }

    @Test func scaledMetricsFitMatchesCoreTextReference() throws {
        let normal = font()
        var cases: [(String, CTFont, CGGlyph)] = []
        for (label, text, base) in [
            ("normal", "W", normal),
            ("bold", "W", font("Menlo-Bold")),
            ("italic", "W", font("Menlo-Italic")),
            ("cjk", "界", normal),
            ("emoji", "😀", normal)
        ] {
            let shaped = try shapedGlyph(text, base: base)
            cases.append((label, shaped.0, shaped.1))
        }
        if let pair = variableFontPair() {
            let first = try shapedGlyph("W", base: pair.0)
            let second = try shapedGlyph("W", base: pair.1)
            cases.append(("variable-min", first.0, first.1))
            cases.append(("variable-max", second.0, second.1))
        }

        let dimensions = [
            CGSize(width: 10, height: 20),
            CGSize(width: 7.5, height: 15),
            CGSize(width: 20, height: 11)
        ]
        for (label, caseFont, glyph) in cases {
            for width in [2, 3] {
                for dimension in dimensions {
                    for scale: CGFloat in [1, 1.5, 2, 3] {
                        let expected = GlyphSlotFit.calculate(
                            font: caseFont,
                            glyph: glyph,
                            columnWidth: width,
                            cellDimension: dimension,
                            normalFont: normal)
                        let actual = scaledFit(font: caseFont,
                                               glyph: glyph,
                                               columnWidth: width,
                                               cellDimension: dimension,
                                               normalFont: normal,
                                               renderingScale: scale)
                        expectEqual(actual, expected,
                                    context: "\(label), width=\(width), cell=\(dimension), scale=\(scale)",
                                    sourceLocation: #_sourceLocation)
                    }
                }
            }
        }
    }

    @Test func identityHorizontalAndVerticalScalingMatchReference() throws {
        let normal = font()
        let shaped = try shapedGlyph("W", base: normal)
        let cases = [
            CGSize(width: 100, height: 100),
            CGSize(width: 1, height: 100),
            CGSize(width: 100, height: 2)
        ]
        var scales: [CGFloat] = []

        for dimension in cases {
            let expected = GlyphSlotFit.calculate(font: shaped.0,
                                                  glyph: shaped.1,
                                                  columnWidth: 2,
                                                  cellDimension: dimension,
                                                  normalFont: normal)
            let actual = scaledFit(font: shaped.0,
                                   glyph: shaped.1,
                                   columnWidth: 2,
                                   cellDimension: dimension,
                                   normalFont: normal,
                                   renderingScale: 2)
            expectEqual(actual, expected)
            scales.append(actual.scale)
        }

        #expect(scales[0] == 1)
        #expect(scales[1] < 1)
        #expect(scales[2] < 1)
    }

    @Test func normalFontBaselineChangesVerticalOffset() throws {
        let glyphFont = font(size: 28)
        let shaped = try shapedGlyph("W", base: glyphFont)
        let firstNormal = font(size: 14)
        let secondNormal = font(size: 24)
        let cell = CGSize(width: 6, height: 8)
        var offsets: [CGFloat] = []

        for normal in [firstNormal, secondNormal] {
            let expected = GlyphSlotFit.calculate(font: shaped.0,
                                                  glyph: shaped.1,
                                                  columnWidth: 2,
                                                  cellDimension: cell,
                                                  normalFont: normal)
            let actual = scaledFit(font: shaped.0,
                                   glyph: shaped.1,
                                   columnWidth: 2,
                                   cellDimension: cell,
                                   normalFont: normal,
                                   renderingScale: 3)
            expectEqual(actual, expected)
            offsets.append(actual.dy)
        }
        #expect(offsets[0] != offsets[1])
    }

    @Test func metricsRasterizerMatchesCompatibilityWrapper() throws {
        let rasterizer = CoreTextGlyphRasterizer()
        let normal = font()
        var cases: [(CTFont, CGGlyph)] = []
        for (text, base) in [
            ("W", normal),
            ("W", font("Menlo-Bold")),
            ("W", font("Menlo-Italic")),
            ("界", normal),
            ("😀", normal),
            (" ", normal)
        ] {
            cases.append(try shapedGlyph(text, base: base))
        }

        var matrix = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
        let matrixFont = CTFontCreateCopyWithAttributes(normal, pointSize, &matrix, nil)
        cases.append(try shapedGlyph("W", base: matrixFont))
        if let variable = variableFontPair() {
            cases.append(try shapedGlyph("W", base: variable.0))
            cases.append(try shapedGlyph("W", base: variable.1))
        }

        for (caseFont, glyph) in cases {
            let expected = rasterizer.rasterize(font: caseFont, glyph: glyph)
            let metrics = GlyphMetrics.measure(font: caseFont, glyph: glyph)
            let actual = rasterizer.rasterize(font: caseFont,
                                              glyph: glyph,
                                              metrics: metrics)
            switch (actual, expected) {
            case (.empty, .empty), (.transientFailure, .transientFailure):
                break
            case (.bitmap(let actualBitmap), .bitmap(let expectedBitmap)):
                #expect(actualBitmap.width == expectedBitmap.width)
                #expect(actualBitmap.height == expectedBitmap.height)
                #expect(actualBitmap.bearing == expectedBitmap.bearing)
                #expect(actualBitmap.isColor == expectedBitmap.isColor)
                #expect(actualBitmap.pixels == expectedBitmap.pixels)
            default:
                Issue.record("metrics rasterizer result did not match compatibility wrapper")
            }
        }
    }

    @Test func emptyAndTransientRasterizationResultsAreDistinct() throws {
        let rasterizer = CoreTextGlyphRasterizer()
        let normal = font()
        let space = try shapedGlyph(" ", base: normal)
        let visible = try shapedGlyph("W", base: normal)

        if case .empty = rasterizer.rasterize(font: space.0, glyph: space.1) {
            // Expected.
        } else {
            Issue.record("space glyph was not classified as permanently empty")
        }

#if DEBUG
        rasterizer.forceContextCreationFailureForTesting = true
        if case .transientFailure = rasterizer.rasterize(font: visible.0, glyph: visible.1) {
            // Expected.
        } else {
            Issue.record("forced context failure was not transient")
        }
        rasterizer.forceContextCreationFailureForTesting = false
#endif
        if case .bitmap = rasterizer.rasterize(font: visible.0, glyph: visible.1) {
            // Expected.
        } else {
            Issue.record("visible glyph did not rasterize after a transient failure")
        }
    }

    @Test func roundedZeroBitmapDimensionIsEmpty() {
        let rasterizer = CoreTextGlyphRasterizer()
        let normal = font()
        // At this magnitude, adding 0.5 does not change the represented x
        // coordinate. The unrounded width is positive, but the stable rounded
        // bitmap rectangle has zero width.
        let metrics = GlyphMetrics(
            inkBounds: CGRect(x: CGFloat(1 << 54), y: 0, width: 0.5, height: 1),
            horizontalAdvance: 1,
            fontSize: pointSize,
            fitInkSizeScale: 1)

        if case .empty = rasterizer.rasterize(font: normal,
                                              glyph: CGGlyph(1),
                                              metrics: metrics) {
            // Expected.
        } else {
            Issue.record("zero rounded bitmap width was not classified as empty")
        }
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
