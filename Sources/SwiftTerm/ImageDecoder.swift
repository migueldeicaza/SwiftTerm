//
//  ImageDecoder.swift
//
// Opens an image file with ImageIO after the container, the frame count and
// the size are checked, and decodes one frame.
//
#if !SWIFTTERM_EMBEDDED && canImport(ImageIO) && canImport(CoreGraphics)
import Foundation
import CoreGraphics
import ImageIO

/// One frame of an image file that passed the checks of ``ImageDecoder``.
///
/// The pixels are not decoded yet. Use the size to check the drawn area, then
/// call ``decode()``.
struct ImageFrame {
    private let source: CGImageSource
    private let index: Int
    /// The width of the stored pixels.
    let width: Int
    /// The height of the stored pixels.
    let height: Int
    /// The EXIF orientation, from 1 to 8. The value 1 is upright.
    let orientation: Int
    /// The horizontal and the vertical resolution, in dots per inch.
    let resolution: (x: Double, y: Double)

    fileprivate init(source: CGImageSource, index: Int, width: Int, height: Int,
                     orientation: Int, resolution: (x: Double, y: Double)) {
        self.source = source
        self.index = index
        self.width = width
        self.height = height
        self.orientation = orientation
        self.resolution = resolution
    }

    /// The width and the height after the orientation is applied, in pixels.
    var orientedSize: (width: Int, height: Int) {
        oriented(width, height)
    }

    /// The size after the orientation is applied, in pixels.
    var pixelSize: CGSize {
        CGSize(width: orientedSize.width, height: orientedSize.height)
    }

    /// The size after the orientation is applied, in points, from the
    /// resolution. This is the size that NSImage gives the file.
    var pointSize: CGSize {
        let size = oriented(Double(width) * 72 / resolution.x, Double(height) * 72 / resolution.y)
        return CGSize(width: size.width, height: size.height)
    }

    /// Swaps the width and the height if the orientation turns the image by
    /// 90 degrees (orientations 5 to 8).
    private func oriented<T>(_ width: T, _ height: T) -> (width: T, height: T) {
        orientation >= 5 ? (height, width) : (width, height)
    }

    /// Decodes the frame. The image keeps the decoded pixels, so each draw
    /// does not decode the file again. Returns nil if ImageIO cannot decode
    /// the frame, or if the result does not have the size of the header.
    func decode() -> CGImage? {
        let options = [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, index, options),
              image.width == width, image.height == height else {
            return nil
        }
        return image
    }
}

/// Opens the first or the primary frame of an image file.
///
/// NSImage and UIImage decode every frame of a file, and ImageIO reads every
/// frame of some formats before it returns one. This decoder checks the file
/// first, then asks ImageIO for one frame:
///
/// 1. ``ImageContainer`` reads the format and counts the frames.
/// 2. ImageIO must find the same format.
/// 3. The header of the frame must give a size in the limits.
/// 4. ``ImageFrame/decode()`` decodes that frame, and the result must have
///    that size.
enum ImageDecoder {
    /// Reads the header of one frame. Returns nil if the file is not in the
    /// limits. This does not decode the pixels.
    ///
    /// - Parameters:
    ///   - data: the file.
    ///   - maxDimension: the largest width or height, in pixels.
    ///   - maxBytes: the largest decoded bitmap, in bytes.
    static func open(_ data: Data, maxDimension: Int, maxBytes: Int = ImageLimits.maxBitmapBytes) -> ImageFrame? {
        guard let container = data.withUnsafeBytes({ ImageContainer($0, maxFrames: ImageLimits.maxFrames) }) else {
            return nil
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              typeIdentifiers(container.format).contains(type) else {
            return nil
        }
        // The container check makes these calls fast.
        let count = CGImageSourceGetCount(source)
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard count >= 1, count <= ImageLimits.maxFrames, index < count,
              // Do not give kCGImageSourceShouldCache = false here. Then
              // ImageIO does not keep the decoded frame, and each stripe
              // decodes the file again: 2,000 stripes take 4.6 s, not 0.03 s.
              let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let depth = properties[kCGImagePropertyDepth] as? Int, (1...64).contains(depth) else {
            return nil
        }
        // ImageIO keeps the color samples and the alpha sample of each pixel
        // at the depth of the file. For example, 16-bit gray uses 2 bytes and
        // 16-bit RGB uses 6 bytes. bytesPerPixel counts 4 bytes or more, for
        // the padding of 8-bit RGB and for an RGBA output. For an unknown
        // color model, count the largest layout.
        let colorSamples = [kCGImagePropertyColorModelGray as String: 1,
                            kCGImagePropertyColorModelRGB as String: 3,
                            kCGImagePropertyColorModelCMYK as String: 4]
        let alpha = (properties[kCGImagePropertyHasAlpha] as? Bool) == true ? 1 : 0
        let samples = (properties[kCGImagePropertyColorModel] as? String)
            .flatMap { colorSamples[$0] }.map { $0 + alpha } ?? 5
        let bytesPerPixel = ImageContainer.bytesPerPixel(samples: samples, depth: depth)
        guard ImageLimits.bitmapFits(width: width, height: height, bytesPerPixel: bytesPerPixel,
                                     maxDimension: maxDimension, maxBytes: maxBytes) else {
            return nil
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return ImageFrame(source: source, index: index, width: width, height: height,
                          orientation: (1...8).contains(orientation) ? orientation : 1,
                          resolution: (resolution(properties[kCGImagePropertyDPIWidth]),
                                       resolution(properties[kCGImagePropertyDPIHeight])))
    }

    /// The ImageIO types for each container format.
    static func typeIdentifiers(_ format: ImageContainer.Format) -> Set<String> {
        switch format {
        case .png: return ["public.png"]
        // ImageIO uses the MPO type for a JPEG file with more than one image.
        case .jpeg: return ["public.jpeg", "public.mpo-image"]
        case .gif: return ["com.compuserve.gif"]
        case .tiff: return ["public.tiff"]
        case .webp: return ["org.webmproject.webp"]
        case .bmp: return ["com.microsoft.bmp"]
        case .heif: return ["public.heic", "public.heics", "public.heif", "public.avif", "public.avis"]
        }
    }

    /// Returns the transform that puts an image, drawn in the unit square, in
    /// `rect` with its EXIF orientation applied. The y axis of the space goes
    /// down.
    static func orientationTransform(_ orientation: Int, in rect: CGRect) -> CGAffineTransform {
        // For a point (u, v) of the stored pixels, from the top-left corner
        // and from 0 to 1, the shown point is (a·u + c·v + e, b·u + d·v + f).
        let (a, c, e, b, d, f): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
        switch orientation {
        case 2: (a, c, e, b, d, f) = (-1, 0, 1, 0, 1, 0)   // Mirrored.
        case 3: (a, c, e, b, d, f) = (-1, 0, 1, 0, -1, 1)  // Turned 180°.
        case 4: (a, c, e, b, d, f) = (1, 0, 0, 0, -1, 1)   // Mirrored vertically.
        case 5: (a, c, e, b, d, f) = (0, 1, 0, 1, 0, 0)    // Transposed.
        case 6: (a, c, e, b, d, f) = (0, -1, 1, 1, 0, 0)   // Turned 90° clockwise.
        case 7: (a, c, e, b, d, f) = (0, -1, 1, -1, 0, 1)  // Transverse.
        case 8: (a, c, e, b, d, f) = (0, 1, 0, -1, 0, 1)   // Turned 90° counterclockwise.
        default: (a, c, e, b, d, f) = (1, 0, 0, 0, 1, 0)
        }
        // CGContext.draw puts the stored point (u, v) at (u, 1 - v) of the unit
        // square. Replace v with 1 - v, then scale to the rectangle.
        let width = rect.width
        let height = rect.height
        return CGAffineTransform(a: width * a, b: height * b, c: -width * c, d: -height * d,
                                 tx: rect.minX + width * (c + e), ty: rect.minY + height * (d + f))
    }

    /// Returns a resolution from the file, or 72 dots per inch if the file
    /// gives no usable value.
    private static func resolution(_ value: Any?) -> Double {
        guard let number = value as? Double, number > 0, number.isFinite else {
            return 72
        }
        return number
    }
}
#endif
