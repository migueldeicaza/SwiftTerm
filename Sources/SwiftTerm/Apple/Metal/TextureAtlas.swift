//
// From https://github.com/schwa/MetalTerminal
//
//  Created by Jonathan Wight
//

import AppKit
import Metal

class TextureAtlas {
    var texture: MTLTexture
    var atlasSize: CGSize
    var charSizeInPoints: CGSize
    private var font: NSFont
    private let device: MTLDevice
    private(set) var fontSize: CGFloat

    var index: [Character: (minU: Float, minV: Float, maxU: Float, maxV: Float)] = [:]

    private var asciiLookup: [(minU: Float, minV: Float, maxU: Float, maxV: Float)?] = Array(repeating: nil, count: 95)

    let numberOfColumns = 16
    let numberOfRows = 8
    var numberOfCells: Int { numberOfColumns * numberOfRows }

    private var scratchTexture: MTLTexture?
    private var scratchContext: CGContext?
    private var commandQueue: MTLCommandQueue?

    init(device: MTLDevice, fontSize: CGFloat = 15, fontName: String = "Hack") {
        self.device = device
        self.fontSize = fontSize
        let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0
        font = NSFont(name: fontName, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        let attributes: [NSAttributedString.Key: Any] = [.font: font]

        let sampleChar = "M"
        let charBounds = sampleChar.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude), options: [], attributes: attributes, context: nil)

        let padding: CGFloat = 2

        let cellSizeInPoints = CGSize(width: charBounds.width + padding, height: font.capHeight + font.descender.magnitude + padding)

        let atlasCharSize = CGSize(width: cellSizeInPoints.width * scaleFactor, height: cellSizeInPoints.height * scaleFactor)

        atlasSize = CGSize(width: atlasCharSize.width * CGFloat(numberOfColumns), height: atlasCharSize.height * CGFloat(numberOfRows))

        charSizeInPoints = cellSizeInPoints

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: Int(atlasSize.width), height: Int(atlasSize.height), mipmapped: false)
        textureDescriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            fatalError("Failed to create texture")
        }
        self.texture = texture

        setupScratchResources()
        generateAtlas()
    }

    func regenerate(with newFontSize: CGFloat, fontName: String = "Hack") {
        fontSize = newFontSize
        let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0
        font = NSFont(name: fontName, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let sampleChar = "M"
        let charBounds = sampleChar.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude), options: [], attributes: attributes, context: nil)

        let padding: CGFloat = 2
        let cellSizeInPoints = CGSize(width: charBounds.width + padding, height: font.capHeight + font.descender.magnitude + padding)

        let atlasCharSize = CGSize(width: cellSizeInPoints.width * scaleFactor, height: cellSizeInPoints.height * scaleFactor)

        atlasSize = CGSize(width: atlasCharSize.width * CGFloat(numberOfColumns), height: atlasCharSize.height * CGFloat(numberOfRows))
        charSizeInPoints = cellSizeInPoints

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: Int(atlasSize.width), height: Int(atlasSize.height), mipmapped: false)
        textureDescriptor.usage = [.shaderRead]

        guard let newTexture = device.makeTexture(descriptor: textureDescriptor) else {
            fatalError("Failed to create texture")
        }
        self.texture = newTexture

        setupScratchResources()
        generateAtlas()
    }

    private func setupScratchResources() {
        let cellWidth = Int(atlasSize.width / CGFloat(numberOfColumns))
        let cellHeight = Int(atlasSize.height / CGFloat(numberOfRows))

        guard let queue = device.makeCommandQueue() else {
            fatalError("Failed to create command queue")
        }
        self.commandQueue = queue

        let bytesPerPixel = 4
        let unalignedBytesPerRow = cellWidth * bytesPerPixel
        let bytesPerRow = ((unalignedBytesPerRow + 15) / 16) * 16
        let totalBytes = cellHeight * bytesPerRow

        guard let buffer = device.makeBuffer(length: totalBytes, options: [.storageModeShared]) else {
            fatalError("Failed to create scratch buffer")
        }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: cellWidth, height: cellHeight, mipmapped: false)
        textureDescriptor.storageMode = .shared

        guard let texture = buffer.makeTexture(descriptor: textureDescriptor, offset: 0, bytesPerRow: bytesPerRow) else {
            fatalError("Failed to create scratch texture")
        }
        self.scratchTexture = texture

        guard let context = CGContext(data: buffer.contents(), width: cellWidth, height: cellHeight, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Failed to create scratch CGContext")
        }
        self.scratchContext = context
    }

    private func generateAtlas() {
        index.removeAll()
        asciiLookup = Array(repeating: nil, count: 95)

        let pixelCount = Int(atlasSize.width * atlasSize.height)
        var clearColor = [UInt8](repeating: 0, count: pixelCount * 4)
        for i in 0..<pixelCount {
            let pixelIndex = i * 4
            clearColor[pixelIndex] = 255
            clearColor[pixelIndex + 1] = 0
            clearColor[pixelIndex + 2] = 255
            clearColor[pixelIndex + 3] = 255
        }
        texture.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: Int(atlasSize.width), height: Int(atlasSize.height), depth: 1)), mipmapLevel: 0, withBytes: clearColor, bytesPerRow: Int(atlasSize.width) * 4)

        for i in 32..<127 {
            if let scalar = UnicodeScalar(i) {
                let character = Character(scalar)
                addCharacter(character)
            }
        }

        let emojis = "🌍⚡💻🎨🌈🚀🎉✨😀🔥💡🎮🌟💎🏆🎯🎪🎭🎸🎺🌺🌸🍕🍔🍟🍿🎂🍰☕🍺⚽🏀🏈⚾🎾🏐🏓🏸️"
        for emoji in emojis {
            addCharacter(emoji)
        }
    }

    func getTexCoords(for character: Character) -> (minU: Float, minV: Float, maxU: Float, maxV: Float) {
        if let scalar = character.unicodeScalars.first {
            let value = Int(scalar.value)
            if value >= 32 && value <= 126 {
                let index = value - 32
                if let coords = asciiLookup[index] {
                    return coords
                }
            }
        }

        return index[character] ?? (0, 0, 0, 0)
    }

    private func cellIndexToGridCoords(_ cellIndex: Int) -> (x: Int, y: Int) {
        let x = cellIndex % numberOfColumns
        let y = cellIndex / numberOfColumns
        return (x, y)
    }

    func addCharacter(_ character: Character) {
        if index[character] != nil {
            return
        }

        let cellIndex = index.count
        guard cellIndex < numberOfCells else {
            return
        }

        let gridCoords = cellIndexToGridCoords(cellIndex)
        let gridX = gridCoords.x
        let gridY = gridCoords.y

        let cellWidth = Int(atlasSize.width / CGFloat(numberOfColumns))
        let cellHeight = Int(atlasSize.height / CGFloat(numberOfRows))

        scratchContext?.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        scratchContext?.fill(CGRect(x: 0, y: 0, width: cellWidth, height: cellHeight))

        let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0
        let scaledFont = NSFont(name: font.fontName, size: font.pointSize * scaleFactor) ?? NSFont.monospacedSystemFont(ofSize: font.pointSize * scaleFactor, weight: .regular)

        scratchContext?.setFillColor(NSColor.black.cgColor)
        scratchContext?.fill(CGRect(x: 0, y: 0, width: cellWidth, height: cellHeight))

        let isEmoji = character.unicodeScalars.first.map { $0.value > 127 && $0.properties.isEmoji } ?? false

        let charString = String(character)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: scaledFont,
            .foregroundColor: isEmoji ? nil : NSColor.white,
            .backgroundColor: NSColor.clear
        ].compactMapValues { $0 }

        let scaledPadding = CGFloat(2) * scaleFactor
        var textSize = charString.size(withAttributes: attributes)

        if isEmoji {
            let maxWidth = CGFloat(cellWidth) - scaledPadding
            let maxHeight = CGFloat(cellHeight) - scaledPadding

            if textSize.width > maxWidth || textSize.height > maxHeight {
                let widthScale = maxWidth / textSize.width
                let heightScale = maxHeight / textSize.height
                let scale = min(widthScale, heightScale)

                let emojiFont = NSFont(name: scaledFont.fontName, size: scaledFont.pointSize * scale) ?? NSFont.systemFont(ofSize: scaledFont.pointSize * scale)
                attributes[.font] = emojiFont

                textSize = charString.size(withAttributes: attributes)
            }
        }

        let textRect: CGRect
        if isEmoji {
            let centeredX = (CGFloat(cellWidth) - textSize.width) / 2
            let centeredY = (CGFloat(cellHeight) - textSize.height) / 2
            textRect = CGRect(x: centeredX, y: centeredY, width: textSize.width, height: textSize.height)
        } else {
            let baselineY = CGFloat(cellHeight) - scaledPadding / 2 - scaledFont.descender.magnitude
            let centeredX = (CGFloat(cellWidth) - textSize.width) / 2
            textRect = CGRect(x: centeredX, y: baselineY - scaledFont.capHeight, width: textSize.width, height: textSize.height)
        }

        guard let scratchContext else {
            return
        }
        let nsContext = NSGraphicsContext(cgContext: scratchContext, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        charString.draw(in: textRect, withAttributes: attributes)

        NSGraphicsContext.restoreGraphicsState()

        guard let commandBuffer = commandQueue?.makeCommandBuffer() else {
            return
        }
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return
        }

        let blitX = gridX * cellWidth
        let blitY = gridY * cellHeight

        if let scratchTexture {
            blitEncoder.copy(from: scratchTexture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: cellWidth, height: cellHeight, depth: 1), to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: blitX, y: blitY, z: 0))
        }

        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let minU = Float(blitX) / Float(atlasSize.width)
        let minV = Float(blitY) / Float(atlasSize.height)
        let maxU = Float(blitX + cellWidth) / Float(atlasSize.width)
        let maxV = Float(blitY + cellHeight) / Float(atlasSize.height)

        let coords = (minU, minV, maxU, maxV)

        index[character] = coords

        if let scalar = character.unicodeScalars.first {
            let value = Int(scalar.value)
            if value >= 32 && value <= 126 {
                asciiLookup[value - 32] = coords
            }
        }
    }
}
