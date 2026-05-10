#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics
import Metal

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

    private let device: MTLDevice
    private let format: GlyphAtlasFormat
    private let bytesPerPixel: Int
    private let maxSize: Int
    private(set) var size: Int
    private(set) var texture: MTLTexture
    private var data: [UInt8]
    private var nextX = 0
    private var nextY = 0
    private var rowHeight = 0
    private(set) var didReset = false

    init?(device: MTLDevice, size: Int = 1024, maxSize: Int = 2048, format: GlyphAtlasFormat = .bgra) {
        self.device = device
        self.format = format
        self.bytesPerPixel = format.bytesPerPixel
        let clampedMin = max(size, 256)
        self.maxSize = max(maxSize, clampedMin)
        self.size = clampedMin
        guard let texture = GlyphAtlas.makeTexture(device: device, size: self.size, format: format) else {
            return nil
        }
        self.texture = texture
        self.data = Array(repeating: UInt8(0), count: self.size * self.size * bytesPerPixel)
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
            return reserve(width: paddedWidth, height: paddedHeight).map {
                contentRegion(in: $0, width: width, height: height)
            }
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
        let atlasStride = size * bytesPerPixel
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

        // 1) Bulk-copy the content rows. This is the hot path for color
        //    glyphs and matches the pre-padding behavior.
        for row in 0..<height {
            let srcRow = height - 1 - row
            let srcOffset = srcRow * srcStride
            let dstOffset = ((region.y + row) * atlasStride) + (region.x * bytesPerPixel)
            switch format {
            case .bgra:
                data[dstOffset..<dstOffset + srcStride] = pixels[srcOffset..<srcOffset + srcStride]
            case .grayscale:
                for col in 0..<width {
                    data[dstOffset + col] = pixels[srcOffset + col * 4 + 3]
                }
            }
        }

        // 2) Replicate the first/last content rows into the top/bottom
        //    padding strips.
        let contentRowBytes = width * bytesPerPixel
        let firstRowOffset = (region.y * atlasStride) + (region.x * bytesPerPixel)
        let lastRowOffset = ((region.y + height - 1) * atlasStride) + (region.x * bytesPerPixel)
        for row in paddedY..<region.y {
            let dst = (row * atlasStride) + (region.x * bytesPerPixel)
            for i in 0..<contentRowBytes {
                data[dst + i] = data[firstRowOffset + i]
            }
        }
        for row in (region.y + height)..<paddedBottom {
            let dst = (row * atlasStride) + (region.x * bytesPerPixel)
            for i in 0..<contentRowBytes {
                data[dst + i] = data[lastRowOffset + i]
            }
        }

        // 3) Replicate the left/right edge pixels across the full padded
        //    height. Step 2 already filled column `region.x` of the top
        //    and bottom rows, so the four corners come out correctly.
        for row in paddedY..<paddedBottom {
            let rowBase = row * atlasStride
            let leftSrc = rowBase + (region.x * bytesPerPixel)
            let rightSrc = rowBase + ((region.x + width - 1) * bytesPerPixel)
            for col in paddedX..<region.x {
                let dst = rowBase + (col * bytesPerPixel)
                for b in 0..<bytesPerPixel {
                    data[dst + b] = data[leftSrc + b]
                }
            }
            for col in (region.x + width)..<paddedRight {
                let dst = rowBase + (col * bytesPerPixel)
                for b in 0..<bytesPerPixel {
                    data[dst + b] = data[rightSrc + b]
                }
            }
        }

        let regionMTL = MTLRegionMake2D(paddedX, paddedY, paddedWidth, paddedHeight)
        let offset = (paddedY * atlasStride) + (paddedX * bytesPerPixel)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: offset)
            texture.replace(region: regionMTL, mipmapLevel: 0, withBytes: base, bytesPerRow: atlasStride)
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
            return
        }
        let newData = Array(repeating: UInt8(0), count: newSize * newSize * bytesPerPixel)
        var updatedData = newData
        let oldStride = size * bytesPerPixel
        let newStride = newSize * bytesPerPixel
        for row in 0..<size {
            let srcOffset = row * oldStride
            let dstOffset = row * newStride
            updatedData[dstOffset..<dstOffset + oldStride] = data[srcOffset..<srcOffset + oldStride]
        }
        size = newSize
        data = updatedData
        texture = newTexture
        data.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, size, size),
                            mipmapLevel: 0,
                            withBytes: raw.baseAddress!,
                            bytesPerRow: size * bytesPerPixel)
        }
    }

    private func reset() {
        nextX = 0
        nextY = 0
        rowHeight = 0
        data = Array(repeating: UInt8(0), count: size * size * bytesPerPixel)
        data.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, size, size),
                            mipmapLevel: 0,
                            withBytes: raw.baseAddress!,
                            bytesPerRow: size * bytesPerPixel)
        }
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
