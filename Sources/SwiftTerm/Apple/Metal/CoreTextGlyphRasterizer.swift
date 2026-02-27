#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics
import CoreText

final class CoreTextGlyphRasterizer {
    func rasterize(font: CTFont, glyph: CGGlyph) -> GlyphBitmap? {
        var glyphVar = glyph
        let rect = CTFontGetBoundingRectsForGlyphs(font, .default, &glyphVar, nil, 1)
        if rect.width <= 0 || rect.height <= 0 {
            return nil
        }

        let minX = floor(rect.origin.x)
        let minY = floor(rect.origin.y)
        let maxX = ceil(rect.origin.x + rect.size.width)
        let maxY = ceil(rect.origin.y + rect.size.height)
        let width = Int(maxX - minX)
        let height = Int(maxY - minY)
        if width <= 0 || height <= 0 {
            return nil
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
            context.setAllowsFontSmoothing(true)
            context.setShouldSmoothFonts(true)

            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

            var positions = [CGPoint(x: -minX, y: -minY)]
            CTFontDrawGlyphs(font, &glyphVar, &positions, 1, context)
            return true
        }
        if !drew {
            return nil
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

        return GlyphBitmap(width: width,
                           height: height,
                           bearing: CGPoint(x: minX, y: minY),
                           pixels: pixels,
                           isColor: isColor)
    }
}
#endif
