//
//  ImageLimits.swift
//
// The size limits that all the image paths share: Kitty graphics, iTerm2
// inline images (OSC 1337 File=), Sixel bitmaps, and the portable raster
// path.
//
#if !SWIFTTERM_EMBEDDED

/// The size limits that all the image paths share.
///
/// A small file can declare a large image, and a small image can request a
/// large drawn area. Each image path checks these limits before it allocates
/// a bitmap.
enum ImageLimits {
    /// The largest bitmap, in bytes. This applies to one decoded image, and on
    /// Apple platforms to all the stripes of one drawn image. kitty uses
    /// almost the same limit (4 × 10⁸ bytes).
    static let maxBitmapBytes = 400 * 1024 * 1024

    /// The largest width or height of a Kitty graphics image, in pixels. This
    /// is the limit of kitty, which is the reference for the protocol.
    static let kittyMaxDimension = 10_000

    /// The largest width or height of an inline image or a Sixel image. This
    /// applies to the source, in pixels, and to the drawn area, in points or
    /// pixels. Most image formats keep the size in 16 bits. A tall image, for
    /// example a screenshot of a full web page, is in this limit.
    static let maxDimension = 65_535

    /// The largest number of frames in an image file. The view draws only the
    /// first or the primary frame, but ImageIO reads every frame of some
    /// formats when it opens the file. See ``ImageContainer``.
    static let maxFrames = 10_000

    /// The largest number of items in a HEIF file (HEIC or AVIF). ImageIO
    /// takes more time for each item than for a frame of the other formats.
    /// On macOS 27, a HEIC file with 10,000 items takes 309 ms to open. A
    /// TIFF or a GIF file with 10,000 frames takes 24 to 29 ms. A HEIC file
    /// with 2,048 items takes 61 ms. A photo from an iPhone has about 100
    /// items, because the encoder divides the image into tiles.
    static let maxHeifItems = 2_048

    /// The largest number of rows of one inline image or Sixel image. Each row
    /// is one line feed. With a cell height of 8 or more, an image with the
    /// height ``maxDimension`` is in this limit.
    static let maxRows = 8_192

    /// The largest width of one stripe, in pixels. The Apple views keep only
    /// this part of each row, from the left edge of the image.
    ///
    /// The Metal renderer makes a texture from each stripe. A Mac GPU permits
    /// textures of up to 16,384 pixels. The A8 GPU of the iPads that run
    /// iPadOS 15 permits 8,192 pixels. A wider texture can stop the process with
    /// a Metal validation error. At 2 pixels for each point, this width is
    /// 4,096 points, which is more than a window on the largest displays.
    static let maxStripeWidth = 8_192

    /// The default largest width or height of the public portable API
    /// (``Terminal/decodeTerminalImage(_:maxDimension:maxBytes:)`` and
    /// ``TerminalRasterImage``), in pixels. This is the largest canvas or
    /// texture of most browsers and GPUs.
    static let portableMaxDimension = 16_384

    /// The default largest RGBA bitmap of the public portable API, in bytes.
    static let portableMaxBytes = 64 * 1024 * 1024

    /// Returns the limits of the public portable API for the values that a
    /// host gave. A nil value gives the default. A value cannot be more than
    /// the limit of the bundled views.
    static func portable(maxDimension: Int?, maxBytes: Int?) -> (maxDimension: Int, maxBytes: Int) {
        (min(maxDimension ?? portableMaxDimension, self.maxDimension),
         min(maxBytes ?? portableMaxBytes, maxBitmapBytes))
    }

    /// Returns true if a bitmap with this size is in the limits.
    static func bitmapFits(width: Int, height: Int, bytesPerPixel: Int,
                           maxDimension: Int, maxBytes: Int = maxBitmapBytes) -> Bool {
        guard width >= 1, width <= maxDimension, height >= 1, height <= maxDimension,
              bytesPerPixel >= 1,
              let bytes = product(width, height, bytesPerPixel) else {
            return false
        }
        return bytes <= maxBytes
    }

    /// Returns the size from the header (IHDR) of a PNG file, if the decoded
    /// samples and the RGBA output are in the limits. A PNG decoder calls
    /// this before it allocates from the header.
    ///
    /// - Parameters:
    ///   - bytes: the file.
    ///   - maxDimension: the largest width or height, in pixels.
    ///   - maxOutputBytes: the largest RGBA output, in bytes.
    static func pngSize(_ bytes: UnsafeRawBufferPointer, maxDimension: Int,
                        maxOutputBytes: Int) -> (width: Int, height: Int)? {
        guard let header = ImageContainer.pngHeader(bytes),
              bitmapFits(width: header.width, height: header.height, bytesPerPixel: header.bytesPerPixel,
                         maxDimension: maxDimension),
              bitmapFits(width: header.width, height: header.height, bytesPerPixel: 4,
                         maxDimension: maxDimension, maxBytes: maxOutputBytes) else {
            return nil
        }
        return (header.width, header.height)
    }

    /// Returns the sum of the values, or nil if it does not fit in an Int.
    static func sum(_ values: Int...) -> Int? {
        var result = 0
        for value in values {
            let (next, overflow) = result.addingReportingOverflow(value)
            if overflow {
                return nil
            }
            result = next
        }
        return result
    }

    /// Returns the product of the values, or nil if it does not fit in an Int.
    static func product(_ values: Int...) -> Int? {
        var result = 1
        for value in values {
            let (next, overflow) = result.multipliedReportingOverflow(by: value)
            if overflow {
                return nil
            }
            result = next
        }
        return result
    }

    /// Calculates the area that an inline image uses, and checks it against the
    /// limits. Returns nil if the area is not in the limits.
    ///
    /// The units are points on Apple platforms and pixels in the portable path.
    ///
    /// - Parameters:
    ///   - width: the requested width.
    ///   - height: the requested height.
    ///   - preserveAspectRatio: keep the aspect ratio of the image.
    ///   - naturalWidth: the width for `.auto`.
    ///   - naturalHeight: the height for `.auto`.
    ///   - cellWidth: the width of one cell.
    ///   - cellHeight: the height of one cell. It must be 1 or more.
    ///   - columns: the width of the screen, in cells, for `.percent`.
    ///   - rows: the height of the screen, in cells, for `.percent`.
    ///   - letterbox: this applies when both sizes are requested and the aspect
    ///     ratio is kept. If true, the area has the requested size and the image
    ///     is in the center of the area. If false, the area has the size of the
    ///     image.
    static func area(width: ImageSizeRequest, height: ImageSizeRequest, preserveAspectRatio: Bool,
                     naturalWidth: Double, naturalHeight: Double,
                     cellWidth: Double, cellHeight: Double, columns: Int, rows: Int,
                     letterbox: Bool) -> ImageArea? {
        func resolve(_ request: ImageSizeRequest, natural: Double, cell: Double, cells: Int) -> Double {
            switch request {
            case .auto: return natural
            case .cells(let count): return Double(count) * cell
            case .pixels(let count): return Double(count)
            case .percent(let percent): return Double(percent) * Double(cells) * cell / 100
            }
        }
        // A comparison with NaN is false, so these checks also reject NaN.
        guard naturalWidth > 0, naturalHeight > 0, naturalWidth.isFinite, naturalHeight.isFinite else {
            return nil
        }
        var areaWidth = resolve(width, natural: naturalWidth, cell: cellWidth, cells: columns)
        var areaHeight = resolve(height, natural: naturalHeight, cell: cellHeight, cells: rows)
        var imageWidth = areaWidth
        var imageHeight = areaHeight
        if preserveAspectRatio {
            switch (width, height) {
            case (.auto, .auto):
                break
            case (_, .auto):
                areaHeight = areaWidth * naturalHeight / naturalWidth
                imageHeight = areaHeight
            case (.auto, _):
                areaWidth = areaHeight * naturalWidth / naturalHeight
                imageWidth = areaWidth
            default:
                let fit = aspectFit(width: naturalWidth, height: naturalHeight, inWidth: areaWidth, height: areaHeight)
                imageWidth = fit.width
                imageHeight = fit.height
                if !letterbox {
                    areaWidth = imageWidth
                    areaHeight = imageHeight
                }
            }
        }
        let limit = Double(maxDimension)
        guard areaWidth > 0, areaWidth <= limit, areaHeight > 0, areaHeight <= limit,
              imageWidth > 0, imageHeight > 0,
              cellHeight >= 1, cellHeight <= limit else {
            return nil
        }
        // The height limit and a cell height of 1 or more keep this value in
        // an Int.
        let rows = Int((areaHeight / cellHeight).rounded(.up))
        guard rows <= maxRows else {
            return nil
        }
        return ImageArea(width: areaWidth, height: areaHeight,
                         imageX: (areaWidth - imageWidth) / 2, imageY: (areaHeight - imageHeight) / 2,
                         imageWidth: imageWidth, imageHeight: imageHeight, rows: rows)
    }

    /// Returns the largest size with the aspect ratio of the image that fits
    /// in the box, and the position of that size in the center of the box.
    /// All the values must be more than zero.
    static func aspectFit(width: Double, height: Double,
                          inWidth boxWidth: Double, height boxHeight: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        let fit = min(boxWidth / width, boxHeight / height)
        let fitWidth = width * fit
        let fitHeight = height * fit
        return ((boxWidth - fitWidth) / 2, (boxHeight - fitHeight) / 2, fitWidth, fitHeight)
    }

    /// Returns true if the stripes of an area fit in the bitmap limit.
    ///
    /// The Apple views draw each row of the area into its own bitmap. Each
    /// bitmap has ``stripeWidth(_:scale:)`` of the area width and
    /// ``pixels(_:scale:)`` of the cell height, at 4 bytes for each pixel.
    static func stripesFit(_ area: ImageArea, cellHeight: Double, scale: Double) -> Bool {
        guard scale > 0, scale.isFinite, cellHeight > 0, cellHeight.isFinite, area.width.isFinite else {
            return false
        }
        // Use Double: the values are not yet known to fit in an Int.
        let width = min(max(1, (area.width * scale).rounded(.up)), Double(maxStripeWidth))
        let height = max(1, (cellHeight * scale).rounded(.up))
        return width * height * 4 * Double(area.rows) <= Double(maxBitmapBytes)
    }

    /// Returns the width of a stripe, in pixels: ``pixels(_:scale:)`` of the
    /// area width, but not more than ``maxStripeWidth``.
    ///
    /// Call this only for values that ``stripesFit(_:cellHeight:scale:)``
    /// accepted.
    static func stripeWidth(_ areaWidth: Double, scale: Double) -> Int {
        min(pixels(areaWidth, scale: scale), maxStripeWidth)
    }

    /// Returns the number of pixels for a length, at `scale` pixels for each
    /// unit. The result is 1 or more.
    ///
    /// Call this only for values that ``stripesFit(_:cellHeight:scale:)``
    /// accepted.
    static func pixels(_ length: Double, scale: Double) -> Int {
        max(1, Int((length * scale).rounded(.up)))
    }
}

/// The area that an inline image uses on the screen.
///
/// The units are points on Apple platforms and pixels in the portable path.
struct ImageArea: Equatable {
    /// The width of the area.
    var width: Double
    /// The height of the area.
    var height: Double
    /// The horizontal position of the image in the area.
    var imageX: Double
    /// The vertical position of the image in the area, from the top.
    var imageY: Double
    /// The width of the image. It is less than the area width only when the
    /// image is in the center of a larger area.
    var imageWidth: Double
    /// The height of the image. It is less than the area height only when the
    /// image is in the center of a larger area.
    var imageHeight: Double
    /// The number of rows that the area uses.
    var rows: Int
}
#endif
