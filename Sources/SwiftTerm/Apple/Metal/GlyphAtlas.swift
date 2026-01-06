#if os(macOS)
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

final class GlyphAtlas {
    private let device: MTLDevice
    private let bytesPerPixel = 4
    private(set) var size: Int
    private(set) var texture: MTLTexture
    private var data: [UInt8]
    private var nextX = 0
    private var nextY = 0
    private var rowHeight = 0

    init?(device: MTLDevice, size: Int = 1024) {
        self.device = device
        self.size = max(size, 256)
        guard let texture = GlyphAtlas.makeTexture(device: device, size: self.size) else {
            return nil
        }
        self.texture = texture
        self.data = Array(repeating: UInt8(0), count: self.size * self.size * bytesPerPixel)
    }

    func ensureRegion(width: Int, height: Int) -> AtlasRegion? {
        if let region = reserve(width: width, height: height) {
            return region
        }
        var newSize = size
        while newSize < max(width, height) || !canFit(width: width, height: height, size: newSize) {
            newSize *= 2
        }
        grow(to: newSize)
        return reserve(width: width, height: height)
    }

    func write(region: AtlasRegion, pixels: [UInt8], width: Int, height: Int) {
        guard width == region.width, height == region.height else {
            return
        }
        let atlasStride = size * bytesPerPixel
        let srcStride = width * bytesPerPixel
        for row in 0..<height {
            let srcRow = height - 1 - row
            let srcOffset = srcRow * srcStride
            let dstOffset = ((region.y + row) * atlasStride) + (region.x * bytesPerPixel)
            data[dstOffset..<dstOffset + srcStride] = pixels[srcOffset..<srcOffset + srcStride]
        }
        let regionMTL = MTLRegionMake2D(region.x, region.y, region.width, region.height)
        let offset = (region.y * atlasStride) + (region.x * bytesPerPixel)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: offset)
            texture.replace(region: regionMTL, mipmapLevel: 0, withBytes: base, bytesPerRow: atlasStride)
        }
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
        guard let newTexture = GlyphAtlas.makeTexture(device: device, size: newSize) else {
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

    private static func makeTexture(device: MTLDevice, size: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                   width: size,
                                                                   height: size,
                                                                   mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }
}
#endif
