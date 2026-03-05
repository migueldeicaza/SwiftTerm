//
//  GlyphAtlas.swift
//
//  Manages a texture atlas of pre-rendered glyphs for Metal rendering.
//  Glyphs are rasterized via CoreText and packed into a single MTLTexture
//  so the GPU can render terminal text with minimal draw calls.
//

#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import Metal
import CoreText
import CoreGraphics

// MARK: - Supporting Types

/// Identifies a font style variant for glyph lookup.
public enum GlyphStyle: UInt8, Hashable {
    case normal
    case bold
    case italic
    case boldItalic
}

/// Hashable key for glyph cache lookup.
public struct GlyphKey: Hashable {
    public let codePoint: UInt32
    public let style: GlyphStyle

    public init(codePoint: UInt32, style: GlyphStyle) {
        self.codePoint = codePoint
        self.style = style
    }
}

/// Atlas position and metrics for a rasterized glyph.
public struct GlyphInfo {
    public let atlasX: Int
    public let atlasY: Int
    public let width: Int
    public let height: Int
    public let bearingX: Float
    public let bearingY: Float
    public let isWide: Bool

    public var u0: Float { Float(atlasX) / Float(GlyphAtlas.atlasSize) }
    public var v0: Float { Float(atlasY) / Float(GlyphAtlas.atlasSize) }
    public var u1: Float { Float(atlasX + width) / Float(GlyphAtlas.atlasSize) }
    public var v1: Float { Float(atlasY + height) / Float(GlyphAtlas.atlasSize) }
}

/// A set of CTFont references for each style variant used by the atlas.
public struct GlyphAtlasFontSet {
    public let normal: CTFont
    public let bold: CTFont
    public let italic: CTFont
    public let boldItalic: CTFont

    public init(normal: CTFont, bold: CTFont, italic: CTFont, boldItalic: CTFont) {
        self.normal = normal
        self.bold = bold
        self.italic = italic
        self.boldItalic = boldItalic
    }

    /// Returns the CTFont for the given style.
    public func font(for style: GlyphStyle) -> CTFont {
        switch style {
        case .normal:    return normal
        case .bold:      return bold
        case .italic:    return italic
        case .boldItalic: return boldItalic
        }
    }
}

// MARK: - GlyphAtlas

/// Pre-renders glyphs into an MTLTexture atlas for efficient GPU text rendering.
public class GlyphAtlas {
    /// Atlas texture dimensions (square).
    public static let atlasSize = 2048

    public let device: MTLDevice
    public private(set) var atlasTexture: MTLTexture

    /// Cached glyph entries keyed by code point + style.
    public private(set) var glyphMap: [GlyphKey: GlyphInfo] = [:]

    // Shelf-packing state
    private var currentX: Int = 0
    private var currentY: Int = 0
    private var rowHeight: Int = 0

    /// Terminal cell dimensions in pixels.
    public let cellWidth: Int
    public let cellHeight: Int

    /// Font set used for rasterization.
    public var fonts: GlyphAtlasFontSet

    /// Backing scale factor for HiDPI rasterization.
    public let rasterScale: CGFloat

    // MARK: - Initializer

    /// Creates a new glyph atlas backed by an `.r8Unorm` Metal texture.
    ///
    /// - Parameters:
    ///   - device: The Metal device to create the texture on.
    ///   - cellWidth: Width of a single terminal cell in backing pixels.
    ///   - cellHeight: Height of a single terminal cell in backing pixels.
    ///   - fonts: The font set containing normal, bold, italic, and boldItalic variants.
    ///   - scale: Backing scale factor (e.g. 2.0 on Retina). The CGContext is scaled
    ///     so fonts render with full HiDPI detail.
    public init(device: MTLDevice, cellWidth: Int, cellHeight: Int, fonts: GlyphAtlasFontSet, scale: CGFloat = 1) {
        self.device = device
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.fonts = fonts
        self.rasterScale = scale

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: GlyphAtlas.atlasSize,
            height: GlyphAtlas.atlasSize,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .managed

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("GlyphAtlas: failed to create \(GlyphAtlas.atlasSize)×\(GlyphAtlas.atlasSize) atlas texture")
        }
        self.atlasTexture = texture
    }

    // MARK: - Public API

    /// Returns the cached `GlyphInfo` for the given code point and style, rasterizing
    /// and uploading the glyph to the atlas on a cache miss.
    ///
    /// - Parameters:
    ///   - codePoint: Unicode code point to render.
    ///   - style: Font style variant.
    /// - Returns: The glyph's atlas position and metrics, or `nil` if the atlas is full.
    @discardableResult
    public func getOrCreate(codePoint: UInt32, style: GlyphStyle) -> GlyphInfo? {
        let key = GlyphKey(codePoint: codePoint, style: style)
        if let existing = glyphMap[key] {
            return existing
        }

        let font = fonts.font(for: style)
        guard let (pixelData, rasterWidth, rasterHeight, bearingX, bearingY) = rasterize(codePoint: codePoint, font: font) else {
            return nil
        }

        let wide = isWideCodePoint(codePoint)

        guard let (atlasX, atlasY) = pack(width: rasterWidth, height: rasterHeight) else {
            return nil // atlas full
        }

        upload(pixelData: pixelData, width: rasterWidth, height: rasterHeight, toX: atlasX, toY: atlasY)

        let info = GlyphInfo(
            atlasX: atlasX,
            atlasY: atlasY,
            width: rasterWidth,
            height: rasterHeight,
            bearingX: bearingX,
            bearingY: bearingY,
            isWide: wide
        )
        glyphMap[key] = info
        return info
    }

    /// Clears all cached glyphs and resets the packing state.
    /// Call this when fonts change and glyphs need to be re-rasterized.
    public func invalidateAll() {
        glyphMap.removeAll()
        currentX = 0
        currentY = 0
        rowHeight = 0
    }

    // MARK: - Rasterization

    /// Rasterizes a single glyph into an 8-bit grayscale bitmap.
    ///
    /// - Parameters:
    ///   - codePoint: Unicode code point.
    ///   - font: CTFont to use for rendering.
    /// - Returns: Tuple of (pixel data, width, height, bearingX, bearingY) or `nil` on failure.
    private func rasterize(codePoint: UInt32, font: CTFont) -> (Data, Int, Int, Float, Float)? {
        guard let scalar = Unicode.Scalar(codePoint) else { return nil }

        // Map code point to glyph
        var characters = [UniChar]()
        for utf16Unit in String(scalar).utf16 {
            characters.append(utf16Unit)
        }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count) else {
            return nil
        }

        // Determine glyph bounding box for metrics
        var boundingRect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &glyphs, &boundingRect, 1)

        let wide = isWideCodePoint(codePoint)
        let rasterWidth = wide ? cellWidth * 2 : cellWidth
        let rasterHeight = cellHeight

        guard rasterWidth > 0 && rasterHeight > 0 else { return nil }

        let bytesPerRow = rasterWidth
        var pixelData = Data(count: rasterHeight * bytesPerRow)

        let success = pixelData.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return false }

            guard let cgContext = CGContext(
                data: baseAddress,
                width: rasterWidth,
                height: rasterHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }

            // Scale context for HiDPI rasterization; font metrics are in logical points
            let scale = rasterScale
            cgContext.scaleBy(x: scale, y: scale)

            // Disable font smoothing — it creates wide halos in grayscale contexts
            // that look washed-out when used as alpha in the shader.
            // Keep anti-aliasing on so the atlas captures the full glyph shape;
            // the shader applies a binary threshold for sharp edges.
            cgContext.setAllowsAntialiasing(true)
            cgContext.setShouldAntialias(true)
            cgContext.setShouldSmoothFonts(false)

            // Clear to black (transparent in our shader)
            cgContext.setFillColor(CGColor(gray: 0, alpha: 1))
            cgContext.fill(CGRect(x: 0, y: 0, width: CGFloat(rasterWidth) / scale, height: CGFloat(rasterHeight) / scale))

            // Draw glyph in white
            cgContext.setFillColor(CGColor(gray: 1, alpha: 1))

            let ascent = CTFontGetAscent(font)
            let descent = CTFontGetDescent(font)
            let leading = CTFontGetLeading(font)
            let lineHeight = ascent + descent + leading

            // Position baseline so the glyph is vertically centered in the cell
            // (coordinates are in logical points since the context is scaled)
            let logicalHeight = CGFloat(rasterHeight) / scale
            let baselineY = descent + (logicalHeight - lineHeight) / 2.0

            var position = CGPoint(x: 0, y: baselineY)
            CTFontDrawGlyphs(font, &glyphs, &position, 1, cgContext)

            return true
        }

        guard success else { return nil }

        // Bearing is (0,0) because glyphs are rasterized into full cell-sized
        // rectangles with correct baseline positioning already applied.
        return (pixelData, rasterWidth, rasterHeight, 0, 0)
    }

    // MARK: - Atlas Packing

    /// Finds space in the atlas for a glyph of the given size using shelf packing.
    ///
    /// - Parameters:
    ///   - width: Glyph width in pixels.
    ///   - height: Glyph height in pixels.
    /// - Returns: The (x, y) origin in the atlas, or `nil` if there is no room.
    private func pack(width: Int, height: Int) -> (Int, Int)? {
        let atlasSize = GlyphAtlas.atlasSize

        // Wrap to next row if this glyph doesn't fit horizontally
        if currentX + width > atlasSize {
            currentY += rowHeight
            currentX = 0
            rowHeight = 0
        }

        // Check vertical overflow
        if currentY + height > atlasSize {
            return nil
        }

        let x = currentX
        let y = currentY

        currentX += width
        rowHeight = max(rowHeight, height)

        return (x, y)
    }

    // MARK: - Texture Upload

    /// Copies rasterized pixel data into the atlas texture.
    private func upload(pixelData: Data, width: Int, height: Int, toX x: Int, toY y: Int) {
        let region = MTLRegion(
            origin: MTLOrigin(x: x, y: y, z: 0),
            size: MTLSize(width: width, height: height, depth: 1)
        )
        pixelData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            atlasTexture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: width
            )
        }
    }

    // MARK: - Helpers

    /// Heuristic for detecting wide (double-width) characters such as CJK ideographs.
    private func isWideCodePoint(_ codePoint: UInt32) -> Bool {
        // CJK Unified Ideographs
        if (0x4E00...0x9FFF).contains(codePoint) { return true }
        // CJK Unified Ideographs Extension A
        if (0x3400...0x4DBF).contains(codePoint) { return true }
        // CJK Compatibility Ideographs
        if (0xF900...0xFAFF).contains(codePoint) { return true }
        // Fullwidth Forms
        if (0xFF01...0xFF60).contains(codePoint) { return true }
        if (0xFFE0...0xFFE6).contains(codePoint) { return true }
        // CJK Unified Ideographs Extension B–F
        if (0x20000...0x2FA1F).contains(codePoint) { return true }
        // Hangul Syllables
        if (0xAC00...0xD7AF).contains(codePoint) { return true }
        // CJK Radicals, Kangxi Radicals, CJK Symbols
        if (0x2E80...0x303F).contains(codePoint) { return true }
        return false
    }
}
#endif
