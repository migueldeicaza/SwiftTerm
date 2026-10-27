#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import SwiftTerm

/// iTerm2 inline images (OSC 1337 File=) and Sixel bitmaps on macOS: the
/// decoder, the stripes, and the view.
@MainActor
@Suite(.serialized)
struct InlineImageTests {
    /// Makes an RGBA image. `color` gives the color of the pixel at a column
    /// and a row, from the top-left corner.
    private func image(width: Int, height: Int, bitsPerComponent: Int = 8,
                       color: (Int, Int) -> [UInt8] = { _, _ in [0, 0, 0] }) throws -> CGImage {
        let bytesPerComponent = bitsPerComponent / 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4 * bytesPerComponent)
        for y in 0..<height {
            for x in 0..<width {
                for (index, value) in (color(x, y) + [255]).enumerated() {
                    // In 16-bit little endian samples, the high byte comes second.
                    pixels[((y * width + x) * 4 + index) * bytesPerComponent + bytesPerComponent - 1] = value
                }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let byteOrder = bitsPerComponent == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerComponent * 4,
            bytesPerRow: width * 4 * bytesPerComponent, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | byteOrder), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// An image with a different color in each quarter: red at the top left,
    /// green at the top right, blue at the bottom left, and white at the
    /// bottom right.
    private func quarters(width: Int, height: Int) throws -> CGImage {
        try image(width: width, height: height) { x, y in
            switch (x < width / 2, y < height / 2) {
            case (true, true): return [255, 0, 0]
            case (false, true): return [0, 255, 0]
            case (true, false): return [0, 0, 255]
            case (false, false): return [255, 255, 255]
            }
        }
    }

    private func encode(_ images: [CGImage], type: String = "public.png",
                        properties: [CFString: Any] = [:]) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, images.count, nil))
        for image in images {
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A black image. A large image with one row or column is a small file.
    private func imageData(width: Int, height: Int, type: String = "public.png") throws -> Data {
        try encode([image(width: width, height: height)], type: type)
    }

    private func pdfData() throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 100)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// RGBA pixels, from the top-left corner.
    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let start = (y * width + x) * 4
            return Array(bytes[start..<(start + 4)])
        }
    }

    /// Draws the images from the top, one under the other.
    private func stack(_ images: [CGImage]) throws -> Pixels {
        let width = try #require(images.first).width
        let height = images.reduce(0) { $0 + $1.height }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            var top = 0
            for image in images {
                top += image.height
                context.draw(image, in: CGRect(x: 0, y: height - top, width: image.width, height: image.height))
            }
        }
        return Pixels(width: width, height: height, bytes: bytes)
    }

    private func render(_ image: NSImage) throws -> Pixels {
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
        }
        return Pixels(width: width, height: height, bytes: bytes)
    }

    private func makeView() -> TerminalView {
        TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
    }

    private func sendInlineImage(_ view: TerminalView, _ data: Data, arguments: String = "") {
        view.feed(text: "\u{1b}]1337;File=inline=1\(arguments):\(data.base64EncodedString())\u{07}")
    }

    private func hasImages(_ view: TerminalView) -> Bool {
        view.withTerminal { $0.buffer.hasAnyImages }
    }

    /// The rows of the images on the buffer lines, from the top.
    private func rows(_ view: TerminalView) -> [TerminalView.AppleImage] {
        view.withTerminal { terminal in
            let lines = terminal.buffer.lines
            return (0..<lines.count).flatMap { index in
                (lines[index].images ?? []).compactMap { $0 as? TerminalView.AppleImage }
            }
        }
    }

    /// The stripes on the buffer lines, from the top.
    private func stripes(_ view: TerminalView) -> [CGImage] {
        rows(view).map(\.image)
    }

    /// Inserts an image of `width` × `height` pixels, as if the screen had
    /// `scale` pixels for each point.
    private func insert(_ view: TerminalView, width: Int, height: Int, scale: CGFloat) throws {
        let source = try image(width: width, height: height)
        let cellSize = try #require(view.cachedImageMetricsValue()).cellSize
        view.withTerminal { terminal in
            view.insertImage(size: CGSize(width: width, height: height), orientation: 1, terminal: terminal,
                             metrics: (cellSize, scale), width: .auto, height: .auto,
                             preserveAspectRatio: true) { source }
        }
    }

    private func text(_ view: TerminalView) -> String {
        view.withTerminal { terminal in
            (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
                .joined(separator: "\n")
        }
    }

    // MARK: - Decoder

    private func expectDecodes4x2(_ data: Data) throws {
        let frame = try #require(ImageDecoder.open(data, maxDimension: ImageLimits.maxDimension))
        #expect(frame.width == 4 && frame.height == 2)
        #expect(frame.orientation == 1)
        let image = try #require(frame.decode())
        #expect(image.width == 4 && image.height == 2)
    }

    @Test(arguments: ["public.png", "public.jpeg", "com.compuserve.gif", "public.tiff", "com.microsoft.bmp"])
    func decoderReadsTheSupportedFormats(type: String) throws {
        try expectDecodes4x2(try imageData(width: 4, height: 2, type: type))
    }

    @Test func decoderReadsAHEICFile() throws {
        // A black image of 4 × 2 pixels from ImageIO. The encoder needs HEVC
        // hardware, which some virtual machines do not have, but the decoder
        // does not.
        let heic = "AAAAJGZ0eXBoZWljAAAAAG1pZjFNaVBybWlhZk1pSEJoZWljAAABh21ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAHBpY3QAAAAA"
            + "AAAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAADnBpdG0AAAAAAAEAAAAjaWluZgAAAAAAAQAA"
            + "ABVpbmZlAgAAAAABAABodmMxAAAAAOdpcHJwAAAAxmlwY28AAAATY29scm5jbHgAAgACAAaAAAAADGNsbGkAywBAAAAAFGlzcGUA"
            + "AAAAAAAABAAAAAIAAAAJaXJvdAAAAAAQcGl4aQAAAAADCAgIAAAAcmh2Y0MBA3AAAACwAAAAAAAe8AD8/fj4AAALA6AAAQAXQAEM"
            + "Af//A3AAAAMAsAAAAwAAAwAecCShAAEAJEIBAQNwAAADALAAAAMAAAMAHqAUIEHAnwQYh7kWVTcCAgYAgKIAAQAJRAHAYMiyERTZ"
            + "AAAAGWlwbWEAAAAAAAAAAQABBoECAwWGhAAAAB5pbG9jAAAAAEQAAAEAAQAAAAEAAAG7AAAAHwAAAAFtZGF0AAAAAAAAAC8AAAAb"
            + "KAGvOiXA+zd/xOv3qN8a3H3Aoxv5TYQJtLuU"
        try expectDecodes4x2(try #require(Data(base64Encoded: heic)))
    }

    @Test func decoderRejectsOtherFormats() throws {
        // ImageIO can read Netpbm, but it is not a supported format.
        let netpbm = Data("P1\n2 1\n1 0\n".utf8)
        let source = try #require(CGImageSourceCreateWithData(netpbm as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        #expect(ImageDecoder.open(netpbm, maxDimension: ImageLimits.maxDimension) == nil)
        #expect(ImageDecoder.open(try pdfData(), maxDimension: ImageLimits.maxDimension) == nil)
        #expect(ImageDecoder.open(Data(), maxDimension: ImageLimits.maxDimension) == nil)
        #expect(ImageDecoder.open(Data("not an image".utf8), maxDimension: ImageLimits.maxDimension) == nil)
    }

    @Test(arguments: ["public.tiff", "com.compuserve.gif"])
    func decoderRejectsTooManyFrames(type: String) throws {
        let frame = try image(width: 1, height: 1)
        let limit = ImageLimits.maxFrames
        let atLimit = try encode(Array(repeating: frame, count: limit), type: type)
        let overLimit = try encode(Array(repeating: frame, count: limit + 1), type: type)
        #expect(ImageDecoder.open(atLimit, maxDimension: ImageLimits.maxDimension) != nil)
        #expect(ImageDecoder.open(overLimit, maxDimension: ImageLimits.maxDimension) == nil)
    }

    @Test func decoderCountsTheSampleDepth() throws {
        // With 16-bit RGBA samples, the decoded bitmap has 8 bytes for each
        // pixel. KittyPNGHeaderBoundsTests checks the other layouts.
        let data = try encode([image(width: 10, height: 10, bitsPerComponent: 16)], type: "public.tiff")
        #expect(ImageDecoder.open(data, maxDimension: 10, maxBytes: 800) != nil)
        #expect(ImageDecoder.open(data, maxDimension: 10, maxBytes: 799) == nil)
        #expect(ImageDecoder.open(data, maxDimension: 9) == nil)
    }

    @Test func decoderGivesTheSizeThatNSImageGives() throws {
        let data = try encode([image(width: 40, height: 10)], type: "public.jpeg",
                              properties: [kCGImagePropertyOrientation: 6,
                                           kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
        let frame = try #require(ImageDecoder.open(data, maxDimension: ImageLimits.maxDimension))
        #expect(frame.orientation == 6)
        #expect(frame.pixelSize == CGSize(width: 10, height: 40))
        #expect(frame.pointSize == CGSize(width: 5, height: 20))
        #expect(frame.pointSize == NSImage(data: data)?.size)
    }

    /// GIF frames of 1 × 1 pixels, built by hand.
    private func gifFrames(_ count: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        for _ in 0..<count {
            bytes += [0x21, 0xF9, 4, 0, 10, 0, 0, 0]
            bytes += [0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0]
            bytes += [2, 2, 0x44, 0x01, 0]
        }
        return bytes
    }

    @Test func imageIOStopsAtAnUnknownGIFByte() throws {
        // ImageContainer stops at a byte that is not a GIF block. ImageIO must
        // stop at the same byte, or it reads frames that were not counted.
        let header = Array("GIF89a".utf8) + [1, 0, 1, 0, 0x80, 0, 0] + [0, 0, 0, 255, 255, 255]
        for junk: [UInt8] in [[0x99], [0x00], [0x0D, 0x0A]] {
            let data = Data(header + gifFrames(2) + junk + gifFrames(ImageLimits.maxFrames + 1) + [0x3B])
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            #expect(CGImageSourceGetCount(source) == 2)
            #expect(data.withUnsafeBytes { ImageContainer($0, maxFrames: ImageLimits.maxFrames) }?.frames == 2)
            #expect(ImageDecoder.open(data, maxDimension: ImageLimits.maxDimension)?.decode() != nil)
        }
    }

    @Test(arguments: 1...8)
    func decodeTerminalImageAppliesTheOrientation(orientation: Int) throws {
        let data = try encode([quarters(width: 40, height: 20)], type: "public.tiff",
                              properties: [kCGImagePropertyOrientation: orientation])
        let expected = try render(try #require(NSImage(data: data)))
        let terminal = Terminal(delegate: TerminalTestDelegate())
        let decoded = try #require(terminal.decodeTerminalImage(data))
        let shown = Pixels(width: decoded.width, height: decoded.height, bytes: decoded.bytes)
        #expect(shown.width == expected.width && shown.height == expected.height)
        for (x, y) in [(1, 1), (3, 1), (1, 3), (3, 3)] {
            let point = (expected.width * x / 4, expected.height * y / 4)
            #expect(shown.pixel(point.0, point.1) == expected.pixel(point.0, point.1),
                    "orientation \(orientation) at \(point)")
        }
    }

    @Test func decodedImageKeepsItsPixels() throws {
        // Each stripe draws from the decoded image. If ImageIO does not keep
        // the decoded pixels, each stripe decodes the file again. Then 2,000
        // stripes take about 170 times as long as from a bitmap.
        let bitmap = try image(width: 1, height: 30_000)
        let decoded = try #require(ImageDecoder.open(try encode([bitmap]), maxDimension: ImageLimits.maxDimension)?.decode())
        let area = try #require(ImageLimits.area(
            width: .auto, height: .auto, preserveAspectRatio: true, naturalWidth: 1, naturalHeight: 30_000,
            cellWidth: 8, cellHeight: 15, columns: 80, rows: 25, letterbox: true))
        func drawStripes(_ image: CGImage) -> Duration {
            ContinuousClock().measure {
                for row in 0..<area.rows {
                    _ = ImageStripes.draw(image, orientation: 1, area: area, row: row, cellHeight: 15, scale: 1)
                }
            }
        }
        // Use the fastest of three runs, so that a busy computer does not
        // make the test fail.
        let fromBitmap = try #require((0..<3).map { _ in drawStripes(bitmap) }.min())
        let fromFile = try #require((0..<3).map { _ in drawStripes(decoded) }.min())
        #expect(fromFile < fromBitmap * 20 + .milliseconds(500))
    }

    // MARK: - Stripes

    @Test(arguments: [1.0, 2.0, 3.0])
    func stripeHasThePixelsThatTheLimitCounts(scale: Double) throws {
        let cellHeight = 16.5
        let area = try #require(ImageLimits.area(
            width: .pixels(33), height: .pixels(41), preserveAspectRatio: false,
            naturalWidth: 7, naturalHeight: 5, cellWidth: 8, cellHeight: cellHeight,
            columns: 80, rows: 25, letterbox: true))
        let stripe = try #require(ImageStripes.draw(try image(width: 7, height: 5), orientation: 1, area: area,
                                                    row: 0, cellHeight: cellHeight, scale: scale))
        #expect(stripe.width == ImageLimits.stripeWidth(area.width, scale: scale))
        #expect(stripe.height == ImageLimits.pixels(cellHeight, scale: scale))
    }

    @Test func stripeHasTheTextureWidthLimit() throws {
        // At scale 2, the area is 20,000 pixels wide. A Metal texture of that
        // width can stop the process.
        let area = try #require(ImageLimits.area(
            width: .pixels(10_000), height: .pixels(15), preserveAspectRatio: false,
            naturalWidth: 1, naturalHeight: 1, cellWidth: 8, cellHeight: 15,
            columns: 80, rows: 25, letterbox: true))
        let stripe = try #require(ImageStripes.draw(try image(width: 1, height: 1), orientation: 1, area: area,
                                                    row: 0, cellHeight: 15, scale: 2))
        #expect(stripe.width == ImageLimits.maxStripeWidth)
        #expect(stripe.height == 30)
    }

    @Test(arguments: [1, 6])
    func stripesHaveThePixelsOfOneDraw(orientation: Int) throws {
        // The image is scaled down. Each stripe must have the same pixels as
        // the same rows of one draw of the full image, with no lines at the
        // edges of the stripes.
        var seed: UInt32 = 1
        let source = try image(width: 400, height: 1200) { _, _ in
            (0..<3).map { _ in
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return UInt8(truncatingIfNeeded: seed >> 24)
            }
        }
        let cellHeight = 15.0, scale = 2.0
        let size = orientation >= 5 ? (width: 300.0, height: 100.0) : (width: 100.0, height: 300.0)
        let area = try #require(ImageLimits.area(
            width: .pixels(Int(size.width)), height: .pixels(Int(size.height)), preserveAspectRatio: false,
            naturalWidth: size.width, naturalHeight: size.height, cellWidth: 8, cellHeight: cellHeight,
            columns: 80, rows: 25, letterbox: true))
        let width = ImageLimits.pixels(area.width, scale: scale)
        let rowHeight = ImageLimits.pixels(cellHeight, scale: scale)
        let height = rowHeight * area.rows
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: Double(height) / scale)
        context.scaleBy(x: 1, y: -1)
        context.concatenate(ImageDecoder.orientationTransform(orientation, in: CGRect(
            x: area.imageX, y: area.imageY, width: area.imageWidth, height: area.imageHeight)))
        context.draw(source, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let expected = try stack([try #require(context.makeImage())])
        let stripes = try (0..<area.rows).map { row in
            try #require(ImageStripes.draw(source, orientation: orientation, area: area, row: row,
                                           cellHeight: cellHeight, scale: scale))
        }
        let shown = try stack(stripes)
        #expect(shown.width == expected.width && shown.height == expected.height)
        #expect(shown.bytes == expected.bytes)
    }

    @Test func stripeIsEmptyOutsideTheImage() throws {
        let source = try image(width: 10, height: 20)
        let area = ImageArea(width: 10, height: 60, imageX: 0, imageY: 20, imageWidth: 10, imageHeight: 20, rows: 3)
        #expect(ImageStripes.draw(source, orientation: 1, area: area, row: 0, cellHeight: 20, scale: 1) == nil)
        #expect(ImageStripes.draw(source, orientation: 1, area: area, row: 1, cellHeight: 20, scale: 1) != nil)
        #expect(ImageStripes.draw(source, orientation: 1, area: area, row: 2, cellHeight: 20, scale: 1) == nil)
    }

    // MARK: - Terminal view

    @Test func viewDrawsAnImageInTheLimits() throws {
        let view = makeView()
        sendInlineImage(view, try imageData(width: 2, height: 2))
        #expect(hasImages(view))

        let narrow = makeView()
        sendInlineImage(narrow, try imageData(width: 1, height: 40), arguments: ";width=2")
        #expect(hasImages(narrow))
    }

    @Test func viewShowsEachPixelOfAStripeAsOnePixelOfTheScreen() throws {
        // At scale 2, an image with an odd width in pixels has a width of a
        // half point. The row must keep that width, or the renderers scale
        // the stripe (1,001 pixels into 1,000), or do not show it (0 points).
        let view = makeView()
        let cellHeight = try #require(view.cachedImageMetricsValue()).cellSize.height
        try insert(view, width: 1, height: 4, scale: 2)
        try insert(view, width: 1001, height: 4, scale: 2)
        let shown = rows(view)
        #expect(shown.map(\.image.width) == [1, 1001])
        #expect(shown.map(\.size.width) == [0.5, 500.5])
        #expect(shown.allSatisfy { $0.size.height == cellHeight && $0.image.height == Int(cellHeight * 2) })
    }

    @Test func viewKeepsTheLeftPartOfAVeryWideImage() throws {
        let view = makeView()
        try insert(view, width: 20_000, height: 2, scale: 2)
        let row = try #require(rows(view).first)
        #expect(row.image.width == ImageLimits.maxStripeWidth)
        #expect(row.size.width == CGFloat(ImageLimits.maxStripeWidth) / 2)
    }

    @Test func viewDrawsTheImageUpright() throws {
        // A gradient from red at the top to blue at the bottom. The red value
        // must go down inside each row too, because each row is one stripe.
        let data = try encode([image(width: 16, height: 64) { _, y in [UInt8(255 - y * 4), 0, UInt8(y * 4)] }],
                              type: "public.tiff")
        let view = makeView()
        sendInlineImage(view, data)
        view.frameTick()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        // colorAt counts y from the top.
        func red(_ y: Int) throws -> CGFloat {
            let color = try #require(rep.colorAt(x: 8 * rep.pixelsWide / Int(view.bounds.width),
                                                 y: y * rep.pixelsHigh / Int(view.bounds.height))?
                .usingColorSpace(.deviceRGB))
            return color.redComponent - color.blueComponent
        }
        let cellHeight = Int(view.cellDimension.height)
        #expect(try red(2) > red(cellHeight - 3))
        #expect(try red(cellHeight - 3) > red(60))
    }

    @Test(arguments: 1...8)
    func viewAppliesTheOrientation(orientation: Int) throws {
        // TIFF keeps the colors exactly. NSImage applies the orientation, and
        // gives the expected result.
        let data = try encode([quarters(width: 40, height: 20)], type: "public.tiff",
                              properties: [kCGImagePropertyOrientation: orientation])
        let expected = try render(try #require(NSImage(data: data)))
        let view = makeView()
        sendInlineImage(view, data)
        let shown = try stack(stripes(view))
        #expect(shown.width == expected.width)
        for (x, y) in [(1, 1), (3, 1), (1, 3), (3, 3)] {
            let point = (expected.width * x / 4, expected.height * y / 4)
            #expect(shown.pixel(point.0, point.1) == expected.pixel(point.0, point.1),
                    "orientation \(orientation) at \(point)")
        }
    }

    @Test func viewDrawsTheFirstFrameOfAnAnimation() throws {
        let frames = try [[UInt8(255), 0, 0], [0, 255, 0], [0, 0, 255]].map { color in
            try image(width: 8, height: 8) { _, _ in color }
        }
        let view = makeView()
        sendInlineImage(view, try encode(frames, type: "com.compuserve.gif"))
        #expect(try stack(stripes(view)).pixel(4, 4) == [255, 0, 0, 255])
    }

    @Test func viewDrawsATallImage() throws {
        // The height is more than the Kitty limit of 10,000.
        let view = makeView()
        sendInlineImage(view, try imageData(width: 1, height: 30_000))
        #expect(hasImages(view))
    }

    @Test func viewDrawsATallSixelBitmap() {
        let view = makeView()
        var pixels = [UInt8](repeating: 255, count: 2 * 16_000 * 4)
        view.withTerminal { terminal in
            view.createImageFromBitmap(source: terminal, bytes: &pixels, width: 2, height: 16_000)
        }
        #expect(hasImages(view))
    }

    @Test func viewRejectsALargeSourceAndContinuesParsing() throws {
        // A width of 2 cells makes the drawn image small, so only the source
        // check rejects this image.
        let view = makeView()
        view.feed(text: "before ")
        sendInlineImage(view, try imageData(width: ImageLimits.maxDimension + 1, height: 1), arguments: ";width=2")
        view.feed(text: "after")
        #expect(!hasImages(view))
        #expect(text(view).hasPrefix("before after"))
    }

    @Test func viewRejectsALargeDrawnAreaAndContinuesParsing() throws {
        // The source is 4000 pixels. With a width of 100 cells and the aspect
        // ratio kept, the drawn height is more than one million points.
        let view = makeView()
        view.feed(text: "before ")
        sendInlineImage(view, try imageData(width: 1, height: 4000), arguments: ";width=100")
        view.feed(text: "after")
        #expect(!hasImages(view))
        #expect(text(view).hasPrefix("before after"))
    }

    @Test func viewChecksTheAreaBeforeTheDecode() {
        // A small file can declare a large image. The view must not decode
        // it when the drawn area is not in the limits.
        let view = makeView()
        let metrics = view.cachedImageMetricsValue()!
        func decodes(width: ImageSizeRequest) -> Bool {
            var decoded = false
            view.withTerminal { terminal in
                view.insertImage(size: CGSize(width: 1, height: 4000), orientation: 1, terminal: terminal,
                                 metrics: metrics, width: width, height: .auto, preserveAspectRatio: true) {
                    decoded = true
                    return nil
                }
            }
            return decoded
        }
        #expect(!decodes(width: .cells(100)))
        #expect(decodes(width: .auto))
    }

    @Test func viewRejectsTooManyFramesAndContinuesParsing() throws {
        let frame = try image(width: 1, height: 1)
        let view = makeView()
        view.feed(text: "before ")
        sendInlineImage(view, try encode(Array(repeating: frame, count: ImageLimits.maxFrames + 1), type: "public.tiff"))
        view.feed(text: "after")
        #expect(!hasImages(view))
        #expect(text(view).hasPrefix("before after"))
    }

    @Test func viewDoesNotDrawAnSVG() {
        // SVG is not supported: CoreSVG expands nested <use> elements in
        // memory. See VECTOR_INLINE_IMAGES_DESIGN.md.
        let view = makeView()
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24'><circle cx='12' cy='12' r='10'/></svg>"
        sendInlineImage(view, Data(svg.utf8))
        view.feed(text: "after")
        #expect(!hasImages(view))
        #expect(text(view).hasPrefix("after"))
    }

    @Test func viewDoesNotDrawAPDF() throws {
        // PDF is not supported: CGPDF draws nested forms without a limit.
        // See VECTOR_INLINE_IMAGES_DESIGN.md.
        let view = makeView()
        sendInlineImage(view, try pdfData())
        view.feed(text: "after")
        #expect(!hasImages(view))
        #expect(text(view).hasPrefix("after"))
    }
}
#endif
