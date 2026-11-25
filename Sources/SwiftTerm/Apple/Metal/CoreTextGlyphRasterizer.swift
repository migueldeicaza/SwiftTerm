#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics
import CoreText

enum GlyphRasterizationResult {
    case bitmap(GlyphBitmap)
    case empty
    case transientFailure
}

final class CoreTextGlyphRasterizer {
    var fontSmoothing: Bool = true
#if DEBUG
    var forceContextCreationFailureForTesting = false
#endif

    /// OpenType and Apple tables that can supply multi-colour glyph artwork.
    private static let colorTableTags: Set<CTFontTableTag> = [
        CTFontTableTag(kCTFontTableSbix),
        CTFontTableTag(kCTFontTableCBDT),
        CTFontTableTag(kCTFontTableCOLR),
        CTFontTableTag(kCTFontTableSVG),
    ]

    /// True when the font either declares `.traitColorGlyphs` or contains any
    /// colour glyph table (`sbix`, `CBDT`, `COLR`, `SVG`). Such fonts always
    /// take the transparent RGBA path with per-pixel colour detection so a
    /// colour glyph is never flattened to a grayscale mask on a light background.
    static func canContainColorGlyphs(_ font: CTFont) -> Bool {
        if CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) {
            return true
        }
        guard let tables = CTFontCopyAvailableTables(font, []) else {
            return false
        }
        for index in 0..<CFArrayGetCount(tables) {
            let tag = CTFontTableTag(UInt(bitPattern: CFArrayGetValueAtIndex(tables, index)))
            if colorTableTags.contains(tag) {
                return true
            }
        }
        return false
    }

    func rasterize(font: CTFont, glyph: CGGlyph, darkOnLight: Bool = false) -> GlyphRasterizationResult {
        rasterize(font: font, glyph: glyph,
                  metrics: GlyphMetrics.measure(font: font, glyph: glyph),
                  darkOnLight: darkOnLight)
    }

    /// Rasterizes with the same unrounded bounds used by slot fitting.
    /// This path performs no Core Text bounds or advance query.
    func rasterize(font: CTFont,
                   glyph: CGGlyph,
                   metrics: GlyphMetrics,
                   darkOnLight: Bool = false) -> GlyphRasterizationResult {
        var glyphVar = glyph
        let rect = metrics.inkBounds
        if rect.width <= 0 || rect.height <= 0 {
            return .empty
        }

        let minX = floor(rect.origin.x)
        let minY = floor(rect.origin.y)
        let maxX = ceil(rect.origin.x + rect.size.width)
        let maxY = ceil(rect.origin.y + rect.size.height)
        let width = Int(maxX - minX)
        let height = Int(maxY - minY)
        if width <= 0 || height <= 0 {
            return .empty
        }

#if DEBUG
        if forceContextCreationFailureForTesting {
            return .transientFailure
        }
#endif

#if os(macOS)
        let useDarkOnLightSmoothing = fontSmoothing && darkOnLight && !Self.canContainColorGlyphs(font)
#else
        let useDarkOnLightSmoothing = false
#endif

        if useDarkOnLightSmoothing {
            // Draw black onto an opaque white DeviceGray canvas so CoreGraphics
            // applies dark-on-light smoothing uniformly without LCD RGB channel
            // skew (even when CGFontRenderingFontSmoothingDisabled is NO) and
            // without the heavier white-on-black dark-mode stem dilation.
            var gray = Array(repeating: UInt8(255), count: width * height)
            let drew = gray.withUnsafeMutableBytes { raw -> Bool in
                guard let base = raw.baseAddress else {
                    return false
                }
                let colorSpace = CGColorSpaceCreateDeviceGray()
                guard let context = CGContext(data: base,
                                              width: width,
                                              height: height,
                                              bitsPerComponent: 8,
                                              bytesPerRow: width,
                                              space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                    return false
                }

                context.setAllowsAntialiasing(true)
                context.setShouldAntialias(true)
                context.setAllowsFontSubpixelPositioning(true)
                context.setShouldSubpixelPositionFonts(true)
                context.setAllowsFontSubpixelQuantization(false)
                context.setShouldSubpixelQuantizeFonts(false)
                context.setAllowsFontSmoothing(true)
                context.setShouldSmoothFonts(true)

                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.setStrokeColor(CGColor(gray: 0, alpha: 1))

                var positions = [CGPoint(x: -minX, y: -minY)]
                CTFontDrawGlyphs(font, &glyphVar, &positions, 1, context)
                return true
            }
            if !drew {
                return .transientFailure
            }
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for i in 0..<(width * height) {
                let coverage = UInt8(255 - gray[i])
                let offset = i * 4
                pixels[offset] = coverage
                pixels[offset + 1] = coverage
                pixels[offset + 2] = coverage
                pixels[offset + 3] = coverage
            }
            return .bitmap(GlyphBitmap(width: width,
                                      height: height,
                                      bearing: CGPoint(x: minX, y: minY),
                                      pixels: pixels,
                                      isColor: false))
        }

        let bytesPerPixel = 4
        var pixels = Array(repeating: UInt8(0), count: width * height * bytesPerPixel)
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else {
                return false
            }
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                return false
            }
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            guard let context = CGContext(data: base,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * bytesPerPixel,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo) else {
                return false
            }

            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setAllowsFontSubpixelPositioning(true)
            context.setShouldSubpixelPositionFonts(true)
            context.setAllowsFontSubpixelQuantization(false)
            context.setShouldSubpixelQuantizeFonts(false)
#if os(macOS)
            context.setAllowsFontSmoothing(fontSmoothing)
            context.setShouldSmoothFonts(fontSmoothing)
#else
            context.setAllowsFontSmoothing(false)
            context.setShouldSmoothFonts(false)
#endif

            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

            var positions = [CGPoint(x: -minX, y: -minY)]
            CTFontDrawGlyphs(font, &glyphVar, &positions, 1, context)
            return true
        }
        if !drew {
            return .transientFailure
        }

        var isColor = false
        var idx = 0
        while idx < pixels.count {
            let b = pixels[idx]
            let g = pixels[idx + 1]
            let r = pixels[idx + 2]
            if r != g || g != b {
                isColor = true
                break
            }
            idx += 4
        }

        return .bitmap(GlyphBitmap(width: width,
                                  height: height,
                                  bearing: CGPoint(x: minX, y: minY),
                                  pixels: pixels,
                                  isColor: isColor))
    }
}
#endif

#endif // !SWIFTTERM_EMBEDDED
