#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics
import Foundation
import Metal
import os

struct AtlasRegion {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

struct GlyphBitmap {
    let width: Int
    let height: Int
    let bearing: CGPoint
    let pixels: [UInt8]
    let isColor: Bool
}

enum GlyphAtlasFormat {
    case grayscale
    case bgra

    var label: String {
        switch self {
        case .grayscale:
            return "grayscale"
        case .bgra:
            return "bgra"
        }
    }

    var bytesPerPixel: Int {
        switch self {
        case .grayscale:
            return 1
        case .bgra:
            return 4
        }
    }

    var pixelFormat: MTLPixelFormat {
        switch self {
        case .grayscale:
            return .r8Unorm
        case .bgra:
            return .bgra8Unorm
        }
    }
}

final class GlyphAtlas {
    private static let glyphPadding = 1
    static let log = Logger(subsystem: "org.tirania.SwiftTerm", category: "MetalAtlas")

    private let device: MTLDevice
    private let format: GlyphAtlasFormat
    private let bytesPerPixel: Int
    private let maxSize: Int
    private(set) var size: Int
    private(set) var texture: MTLTexture
    private var nextX = 0
    private var nextY = 0
    private var rowHeight = 0
    private(set) var didReset = false
    /// While frozen, `ensureRegion` never grows or resets the atlas: a
    /// request that does not fit simply returns nil. The renderer freezes the
    /// atlases on its final rebuild pass so an overflowing working set
    /// degrades to skipped glyphs instead of invalidating regions that the
    /// frame being built already references.
    var frozen = false
    /// One-shot guards for the overflow diagnostics. They are armed on a
    /// genuine capacity gain (a successful `grow`) and disarmed once logged, so
    /// a sustained overflow logs once per episode rather than every frame.
    private var loggedFrozenMiss = false
    private var loggedResetOverflow = false

    /// The largest 2D texture dimension the device supports.
    static func maxTextureDimension(of device: MTLDevice) -> Int {
        // Apple3 (A9)+ and all modern Macs support 16384; older families 8192.
        if device.supportsFamily(.apple3) || device.supportsFamily(.mac2) {
            return 16384
        }
        return 8192
    }

    /// The maximum atlas size to use for a given device and format, balancing
    /// CJK-sized glyph working sets against memory (an atlas costs
    /// size^2 * bytesPerPixel).
    /// `SWIFTTERM_ATLAS_MAX` overrides the cap for testing.
    static func recommendedMaxSize(device: MTLDevice, format: GlyphAtlasFormat) -> Int {
        if let raw = ProcessInfo.processInfo.environment["SWIFTTERM_ATLAS_MAX"], let value = Int(raw) {
            return min(max(256, value), maxTextureDimension(of: device))
        }
        #if os(iOS)
        let cap = format == .grayscale ? 4096 : 2048
        #else
        let cap = format == .grayscale ? 8192 : 4096
        #endif
        return min(cap, maxTextureDimension(of: device))
    }

    init?(device: MTLDevice, size: Int = 1024, maxSize: Int = 2048, format: GlyphAtlasFormat = .bgra) {
        self.device = device
        self.format = format
        self.bytesPerPixel = format.bytesPerPixel
        // The starting size never exceeds maxSize (a small maxSize is used by
        // tests and the SWIFTTERM_ATLAS_MAX override), and never drops below
        // a useful minimum.
        let clampedMin = max(min(size, maxSize), 256)
        self.maxSize = max(maxSize, clampedMin)
        self.size = clampedMin
        guard let texture = GlyphAtlas.makeTexture(device: device, size: self.size, format: format) else {
            return nil
        }
        self.texture = texture
    }

    func ensureRegion(width: Int, height: Int) -> AtlasRegion? {
        didReset = false
        if width <= 0 || height <= 0 {
            return nil
        }
        let paddedWidth = width + (Self.glyphPadding * 2)
        let paddedHeight = height + (Self.glyphPadding * 2)
        if let region = reserve(width: paddedWidth, height: paddedHeight) {
            return contentRegion(in: region, width: width, height: height)
        }
        if frozen {
            if !loggedFrozenMiss {
                loggedFrozenMiss = true
                Self.log.fault("glyph atlas (\(self.format.label, privacy: .public)) frozen and full; glyphs will be skipped this frame")
            }
            return nil
        }
        if paddedWidth > maxSize || paddedHeight > maxSize {
            return nil
        }
        var newSize = size
        while newSize < maxSize && (newSize < max(paddedWidth, paddedHeight) || !canFit(width: paddedWidth, height: paddedHeight, size: newSize)) {
            newSize *= 2
        }
        if newSize > maxSize {
            newSize = maxSize
        }
        if newSize > size {
            grow(to: newSize)
            if let region = reserve(width: paddedWidth, height: paddedHeight) {
                return contentRegion(in: region, width: width, height: height)
            }
        }
        if !loggedResetOverflow {
            loggedResetOverflow = true
            Self.log.error("glyph atlas (\(self.format.label, privacy: .public)) reset at size \(self.size): glyph working set exceeds capacity")
        }
        reset()
        didReset = true
        return reserve(width: paddedWidth, height: paddedHeight).map {
            contentRegion(in: $0, width: width, height: height)
        }
    }

    func write(region: AtlasRegion, pixels: [UInt8], width: Int, height: Int) {
        guard width == region.width, height == region.height else {
            return
        }
        let srcStride = width * 4
        let padding = Self.glyphPadding

        // ensureRegion guarantees `padding` of slack on every side; the
        // clamps below are defensive against direct misuse.
        let paddedX = max(0, region.x - padding)
        let paddedY = max(0, region.y - padding)
        let paddedRight = min(size, region.x + width + padding)
        let paddedBottom = min(size, region.y + height + padding)
        let paddedWidth = paddedRight - paddedX
        let paddedHeight = paddedBottom - paddedY
        // The padded block, with the content `left` and `top` pixels in.
        let blockStride = paddedWidth * bytesPerPixel
        let left = region.x - paddedX
        let top = region.y - paddedY
        var block = [UInt8](repeating: 0, count: blockStride * paddedHeight)
        pixels.withUnsafeBufferPointer { source in
            block.withUnsafeMutableBufferPointer { block in
                let base = block.baseAddress!
                // 1) Copy the content rows, flipped: the bitmap is bottom-up.
                //    This is the hot path for color glyphs.
                for row in 0..<height {
                    let srcOffset = (height - 1 - row) * srcStride
                    let dstOffset = ((top + row) * blockStride) + (left * bytesPerPixel)
                    switch format {
                    case .bgra:
                        (base + dstOffset).update(from: source.baseAddress! + srcOffset, count: srcStride)
                    case .grayscale:
                        for col in 0..<width {
                            block[dstOffset + col] = source[srcOffset + col * 4 + 3]
                        }
                    }
                }

                // 2) Replicate the first/last content rows into the top/bottom
                //    padding strips.
                let contentRowBytes = width * bytesPerPixel
                let firstRowOffset = (top * blockStride) + (left * bytesPerPixel)
                let lastRowOffset = ((top + height - 1) * blockStride) + (left * bytesPerPixel)
                for row in 0..<top {
                    (base + (row * blockStride) + (left * bytesPerPixel)).update(from: base + firstRowOffset, count: contentRowBytes)
                }
                for row in (top + height)..<paddedHeight {
                    (base + (row * blockStride) + (left * bytesPerPixel)).update(from: base + lastRowOffset, count: contentRowBytes)
                }

                // 3) Replicate the left/right edge pixels across the full padded
                //    height. Step 2 already filled the edge columns of the top
                //    and bottom rows, so the four corners come out correctly.
                for row in 0..<paddedHeight {
                    let rowBase = row * blockStride
                    let leftSrc = rowBase + (left * bytesPerPixel)
                    let rightSrc = rowBase + ((left + width - 1) * bytesPerPixel)
                    for col in 0..<left {
                        (base + rowBase + (col * bytesPerPixel)).update(from: base + leftSrc, count: bytesPerPixel)
                    }
                    for col in (left + width)..<paddedWidth {
                        (base + rowBase + (col * bytesPerPixel)).update(from: base + rightSrc, count: bytesPerPixel)
                    }
                }
            }
        }

        block.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(paddedX, paddedY, paddedWidth, paddedHeight),
                            mipmapLevel: 0,
                            withBytes: raw.baseAddress!,
                            bytesPerRow: blockStride)
        }
    }

    private func contentRegion(in paddedRegion: AtlasRegion, width: Int, height: Int) -> AtlasRegion {
        AtlasRegion(
            x: paddedRegion.x + Self.glyphPadding,
            y: paddedRegion.y + Self.glyphPadding,
            width: width,
            height: height
        )
    }

    private func reserve(width: Int, height: Int) -> AtlasRegion? {
        guard width <= size, height <= size else {
            return nil
        }
        if nextX + width > size {
            nextX = 0
            nextY += rowHeight
            rowHeight = 0
        }
        guard nextY + height <= size else {
            return nil
        }
        let region = AtlasRegion(x: nextX, y: nextY, width: width, height: height)
        nextX += width
        rowHeight = max(rowHeight, height)
        return region
    }

    private func canFit(width: Int, height: Int, size: Int) -> Bool {
        if width > size || height > size {
            return false
        }
        if nextY + height <= size {
            return true
        }
        return false
    }

    private func grow(to newSize: Int) {
        guard newSize > size else {
            return
        }
        guard let newTexture = GlyphAtlas.makeTexture(device: device, size: newSize, format: format) else {
            Self.log.error("glyph atlas (\(self.format.label, privacy: .public)) grow to \(newSize) failed: texture allocation")
            return
        }
        Self.log.info("glyph atlas (\(self.format.label, privacy: .public)) grow: \(self.size) -> \(newSize)")
        // Glyphs keep their pixel coordinates, as the renderer keeps its glyph
        // cache across a grow: the old texture is read back into the new one's
        // corner, through a buffer that lives only for the copy. The rest of the
        // new texture is written glyph by glyph before any frame samples it.
        let copied = MTLRegionMake2D(0, 0, size, size)
        let stride = size * bytesPerPixel
        let count = stride * size
        let oldTexture = texture
        let pixels = [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
            oldTexture.getBytes(buffer.baseAddress!, bytesPerRow: stride, from: copied, mipmapLevel: 0)
            initialized = count
        }
        pixels.withUnsafeBytes { raw in
            newTexture.replace(region: copied, mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: stride)
        }
        size = newSize
        texture = newTexture
        // Capacity actually increased: re-arm the overflow diagnostics so a
        // later, genuinely-new overflow episode is logged once more.
        loggedFrozenMiss = false
        loggedResetOverflow = false
    }

    private func reset() {
        // Packing starts over from the origin. Every region handed out from here
        // on is written whole, padding included, before a frame samples it, so
        // the old pixels need no clearing.
        nextX = 0
        nextY = 0
        rowHeight = 0
    }

    private static func makeTexture(device: MTLDevice, size: Int, format: GlyphAtlasFormat) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format.pixelFormat,
                                                                   width: size,
                                                                   height: size,
                                                                   mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }
}
#endif

#endif // !SWIFTTERM_EMBEDDED
