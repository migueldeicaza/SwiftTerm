//
//  ImageStripes.swift
//
// Draws each row of an inline image or a Sixel image into its own bitmap.
//
#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics

/// Draws the rows of an image. The view attaches each row to one buffer line.
///
/// Each stripe has ``ImageLimits/stripeWidth(_:scale:)`` of the area width and
/// ``ImageLimits/pixels(_:scale:)`` of the cell height.
/// ``ImageLimits/stripesFit(_:cellHeight:scale:)`` uses the same values, so
/// the check and the allocation agree.
enum ImageStripes {
    /// Draws one row of the area into a new bitmap.
    ///
    /// - Parameters:
    ///   - image: the pixels, in the orientation of the file.
    ///   - orientation: the EXIF orientation of `image`, from 1 to 8.
    ///   - area: the area of the image on the screen, in points.
    ///   - row: the row to draw, from 0 to `area.rows - 1`.
    ///   - cellHeight: the height of one row, in points.
    ///   - scale: the number of pixels for each point.
    /// - Returns: the stripe, upright, or nil if the image is not in this row
    ///   (an empty row of a letterbox), or if the bitmap cannot be made. The
    ///   stripe has `scale` pixels for each point, from the left edge of the
    ///   area. A stripe of ``ImageLimits/maxStripeWidth`` does not have the
    ///   right part of a very wide area.
    static func draw(_ image: CGImage, orientation: Int, area: ImageArea, row: Int,
                     cellHeight: Double, scale: Double) -> CGImage? {
        let top = Double(row) * cellHeight
        let imageRect = CGRect(x: area.imageX, y: area.imageY, width: area.imageWidth, height: area.imageHeight)
        guard imageRect.minY < top + cellHeight, imageRect.maxY > top else {
            return nil
        }
        let width = ImageLimits.stripeWidth(area.width, scale: scale)
        let height = ImageLimits.pixels(cellHeight, scale: scale)
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        // Use points, with the y axis down from the top of this row. Core
        // Graphics draws only the part of the image in the bitmap.
        //
        // Draw the full image, not a crop of the rows for this stripe. Then
        // the stripes have the same pixels as one draw of the image. When the
        // image is scaled down, Core Graphics filters a crop in a different
        // way: values change by up to 61 of 255, also at the stripe edges. A
        // crop of a rotated image is also slower, because Core Graphics keeps
        // the rotated full image between the stripes, but not a new crop.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: Double(height) / scale)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -top)
        context.concatenate(ImageDecoder.orientationTransform(orientation, in: imageRect))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()
    }
}
#endif
#endif
