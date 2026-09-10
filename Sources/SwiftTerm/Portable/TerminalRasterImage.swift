#if !SWIFTTERM_EMBEDDED
/// Pixel storage shared by the line slices of one inline image. The host owns
/// the ID and memory budget. Access and eviction require the terminal lock.
public final class TerminalRasterImage {
    public let id: UInt32
    public let width: Int
    public let height: Int
    public private(set) var rgba: [UInt8]

    public init?(id: UInt32, width: Int, height: Int, rgba: [UInt8]) {
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              width <= (64 * 1024 * 1024) / 4 / height,
              rgba.count == width * height * 4 else { return nil }
        self.id = id; self.width = width; self.height = height; self.rgba = rgba
    }

    public func discardPixels() { rgba = [] }
}

public struct TerminalRasterPlacement {
    public let image: TerminalRasterImage
    public let column: Int
    public let row: Int
    public let width: Double
    public let height: Double
    public let sourceY: Double
    public let sourceHeight: Double
}

private final class RasterLineImage: TerminalImage {
    let image: TerminalRasterImage
    let width: Double
    let height: Double
    let sourceY: Double
    let sourceHeight: Double
    var col: Int
    var pixelWidth: Int { Int(width.rounded(.up)) }
    var pixelHeight: Int { Int(height.rounded(.up)) }

    init(image: TerminalRasterImage, column: Int, width: Double, height: Double, sourceY: Double, sourceHeight: Double) {
        self.image = image; col = column; self.width = width; self.height = height
        self.sourceY = sourceY; self.sourceHeight = sourceHeight
    }
}

extension Terminal {
    /// Attach inline image slices to buffer lines so scrolling and erasure use
    /// the same path as native image renderers. Call while holding terminalLock.
    public func insertRasterImage(
        _ image: TerminalRasterImage,
        cellWidth: Int, cellHeight: Int,
        width requestedWidth: ImageSizeRequest = .auto,
        height requestedHeight: ImageSizeRequest = .auto,
        preserveAspectRatio: Bool = true
    ) {
        guard cellWidth > 0, cellHeight > 0, !image.rgba.isEmpty else { return }
        func pixels(_ request: ImageSizeRequest, original: Int, cells: Int, cellSize: Int) -> Double {
            switch request {
            case .auto: return Double(original)
            case .pixels(let value): return Double(value)
            case .cells(let value): return Double(value) * Double(cellSize)
            case .percent(let value): return Double(value) * Double(cells * cellSize) / 100
            }
        }
        var width = pixels(requestedWidth, original: image.width, cells: cols, cellSize: cellWidth)
        var height = pixels(requestedHeight, original: image.height, cells: rows, cellSize: cellHeight)
        if preserveAspectRatio {
            switch (requestedWidth, requestedHeight) {
            case (.auto, .auto): break
            case (_, .auto): height = width * Double(image.height) / Double(image.width)
            case (.auto, _): width = height * Double(image.width) / Double(image.height)
            default:
                let scale = min(width / Double(image.width), height / Double(image.height))
                width = Double(image.width) * scale; height = Double(image.height) * scale
            }
        }
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 65535, height <= 65535 else { return }
        let count = Int((height / Double(cellHeight)).rounded(.up))
        guard count <= 4096 else { return }
        let savedX = buffer.x
        for index in 0..<count {
            let top = Double(index * cellHeight)
            let stripeHeight = min(Double(cellHeight), height - top)
            let stripe = RasterLineImage(
                image: image, column: savedX, width: width, height: stripeHeight,
                sourceY: top * Double(image.height) / height,
                sourceHeight: stripeHeight * Double(image.height) / height
            )
            buffer.attachImage(stripe, toLineAt: buffer.y + buffer.yBase)
            updateRange(buffer.y)
            cmdLineFeed()
            buffer.x = savedX
        }
        updateFullScreen()
    }

    /// Return visible inline image geometry. Read it while holding terminalLock.
    public func rasterImagePlacements() -> [TerminalRasterPlacement] {
        var result: [TerminalRasterPlacement] = []
        let display = displayBuffer
        for row in 0..<rows {
            let index = display.yDisp + row
            guard index < display.lines.count else { continue }
            for value in display.lines[index].images ?? [] {
                guard let stripe = value as? RasterLineImage, !stripe.image.rgba.isEmpty else { continue }
                result.append(TerminalRasterPlacement(
                    image: stripe.image, column: stripe.col, row: row,
                    width: stripe.width, height: stripe.height,
                    sourceY: stripe.sourceY, sourceHeight: stripe.sourceHeight
                ))
            }
        }
        return result
    }
}
#endif
