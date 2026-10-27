#if !SWIFTTERM_EMBEDDED
/// Pixel storage shared by the line slices of one inline image. The host owns
/// the ID and memory budget. Access and eviction require the terminal lock.
public final class TerminalRasterImage {
    public let id: UInt32
    public let width: Int
    public let height: Int
    public private(set) var rgba: [UInt8]

    /// Makes an image from straight-alpha RGBA pixels.
    ///
    /// - Parameters:
    ///   - maxDimension: the largest width or height that the host accepts,
    ///     in pixels. The default is 16,384, the largest texture of most GPUs.
    ///     For tall images, give a larger value. The largest value is 65,535,
    ///     the limit of the bundled views.
    ///   - maxBytes: the largest `rgba` that the host accepts, in bytes. The
    ///     default is 64 MiB. The largest value is 400 MiB, the limit of the
    ///     bundled views.
    /// - Returns: nil if the size is not in the limits, or if `rgba` does not
    ///   have 4 bytes for each pixel.
    public init?(id: UInt32, width: Int, height: Int, rgba: [UInt8],
                 maxDimension: Int? = nil, maxBytes: Int? = nil) {
        let limits = ImageLimits.portable(maxDimension: maxDimension, maxBytes: maxBytes)
        guard ImageLimits.bitmapFits(width: width, height: height, bytesPerPixel: 4,
                                     maxDimension: limits.maxDimension, maxBytes: limits.maxBytes),
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
    ///
    /// - Returns: false if the drawn area is not in the image limits. Then
    ///   the terminal does not change.
    @discardableResult
    public func insertRasterImage(
        _ image: TerminalRasterImage,
        cellWidth: Int, cellHeight: Int,
        width requestedWidth: ImageSizeRequest = .auto,
        height requestedHeight: ImageSizeRequest = .auto,
        preserveAspectRatio: Bool = true
    ) -> Bool {
        guard cellWidth > 0, cellHeight > 0, !image.rgba.isEmpty,
              let area = ImageLimits.area(
                  width: requestedWidth, height: requestedHeight, preserveAspectRatio: preserveAspectRatio,
                  naturalWidth: Double(image.width), naturalHeight: Double(image.height),
                  cellWidth: Double(cellWidth), cellHeight: Double(cellHeight), columns: cols, rows: rows,
                  letterbox: false) else { return false }
        let width = area.width, height = area.height, count = area.rows
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
        return true
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
