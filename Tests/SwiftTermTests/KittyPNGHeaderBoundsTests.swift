import Foundation
import Testing
@testable import SwiftTerm
#if canImport(ImageIO) && canImport(CoreGraphics)
import ImageIO
import CoreGraphics
#endif

struct KittyPNGHeaderBoundsTests {
    private func header(width: UInt32, height: UInt32, depth: UInt8 = 16, colorType: UInt8 = 6) -> Data {
        var bytes: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82]
        for value in [width, height] {
            for shift in [24, 16, 8, 0] { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        bytes += [depth, colorType, 0, 0, 0, 0, 0, 0, 0]
        return Data(bytes)
    }

    /// The check that the PNG decoder of WASI does before it allocates, with
    /// the Kitty limits.
    private func fits(_ data: Data, maxOutputBytes: Int = ImageLimits.maxBitmapBytes) -> Bool {
        data.withUnsafeBytes {
            ImageLimits.pngSize($0, maxDimension: ImageLimits.kittyMaxDimension, maxOutputBytes: maxOutputBytes) != nil
        }
    }

    @Test func headerRejectsInvalidOrExcessiveDimensionsBeforeDecode() {
        for (width, height): (UInt32, UInt32) in [(0, 1), (1, 0), (.max, 1), (1, .max), (10_001, 1), (1, 10_001)] {
            #expect(!fits(header(width: width, height: height)))
        }
        #expect(fits(header(width: 10_000, height: 1)))
        #expect(fits(header(width: 1, height: 10_000)))
        #expect(!fits(Data(header(width: 1, height: 1).prefix(24))))
        #expect(fits(header(width: 1, height: 1)))
        #expect(fits(header(width: 1000, height: 1000)))
    }

    @Test func budgetUsesThePNGSampleLayout() {
        for colorType: UInt8 in [0, 2, 3, 4, 6] {
            #expect(fits(header(width: 8000, height: 8000, depth: 8, colorType: colorType)))
        }
        for colorType: UInt8 in [0, 2, 4] {
            #expect(fits(header(width: 8000, height: 8000, depth: 16, colorType: colorType)))
        }
        // 8000 × 8000 × 8 bytes is more than 400 MB.
        #expect(!fits(header(width: 8000, height: 8000, depth: 16, colorType: 6)))
        #expect(!fits(header(width: 1, height: 1, depth: 16, colorType: 3)))
        #expect(!fits(header(width: 1, height: 1, depth: 4, colorType: 2)))
    }

    @Test func pngSizeChecksTheRGBAOutput() {
        // 16-bit RGBA: 72 MB of samples, and 36 MB of RGBA output.
        let data = header(width: 3000, height: 3000, depth: 16, colorType: 6)
        #expect(fits(data, maxOutputBytes: 36_000_000))
        #expect(!fits(data, maxOutputBytes: 35_999_999))
    }

    #if canImport(ImageIO) && canImport(CoreGraphics)
    private func imageData(type: String, width: Int = 1, height: Int = 1, bitsPerComponent: Int = 8) throws -> Data {
        let bytesPerPixel = 4 * bitsPerComponent / 8
        let pixels = Data(repeating: 255, count: width * height * bytesPerPixel)
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let byteOrder = bitsPerComponent == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerComponent * 4, bytesPerRow: width * bytesPerPixel, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | byteOrder), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func kittyImage(_ data: Data) -> KittyGraphicsRenderImage? {
        let terminal = Terminal(delegate: TerminalTestDelegate())
        terminal.feed(text: "\u{1b}_Ga=t,f=100,i=1;\(data.base64EncodedString())\u{1b}\\")
        return terminal.kittyGraphicsRenderSnapshot().imagesById[1]
    }

    /// A 10 × 10 PNG file with the sample layout of the arguments.
    private func pngData(gray: Bool, alpha: Bool, bitsPerComponent: Int) throws -> Data {
        // Without alpha, RGB samples need a padding sample in the bitmap.
        let components = (gray ? 1 : 3) + (alpha || !gray ? 1 : 0)
        let bitsPerPixel = components * bitsPerComponent
        let pixels = Data(repeating: 128, count: 10 * 10 * bitsPerPixel / 8)
        let alphaInfo: CGImageAlphaInfo = alpha ? .last : (gray ? .none : .noneSkipLast)
        let byteOrder = bitsPerComponent == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(width: 10, height: 10, bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel, bytesPerRow: 10 * bitsPerPixel / 8,
            space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue | byteOrder), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func imageIOAndThePNGHeaderCountTheSameBytes() throws {
        // The Apple decoder and the WASI decoder must accept the same files.
        for gray in [true, false] {
            for alpha in [false, true] {
                for bitsPerComponent in [8, 16] {
                    let data = try pngData(gray: gray, alpha: alpha, bitsPerComponent: bitsPerComponent)
                    let header = try #require(data.withUnsafeBytes { ImageContainer.pngHeader($0) })
                    let bytes = header.bytesPerPixel * 100
                    let layout = "gray \(gray), alpha \(alpha), \(bitsPerComponent) bits"
                    #expect(ImageDecoder.open(data, maxDimension: 10, maxBytes: bytes) != nil, "\(layout)")
                    #expect(ImageDecoder.open(data, maxDimension: 10, maxBytes: bytes - 1) == nil, "\(layout)")
                }
            }
        }
    }

    @Test(arguments: ["public.jpeg", "com.compuserve.gif", "public.tiff"])
    func imageIOMetadataAndDecodeAcceptOtherContainers(type: String) throws {
        let terminal = Terminal(delegate: TerminalTestDelegate())
        let data = try imageData(type: type)
        let frame = try #require(ImageDecoder.open(data, maxDimension: ImageLimits.kittyMaxDimension))
        let image = try #require(frame.decode())
        #expect(image.width == 1 && image.height == 1)
        let decoded = try #require(terminal.decodeTerminalImage(data))
        #expect(decoded.width == 1 && decoded.height == 1)
    }

    @Test func kittyRejectsAWidthOverItsLimit() throws {
        #expect(kittyImage(try imageData(type: "public.png", width: 10_000))?.width == 10_000)
        #expect(kittyImage(try imageData(type: "public.png", width: 10_001)) == nil)
    }

    @Test func jpegDimensionsAreRejectedBeforeBitmapDecode() throws {
        var bytes = Array(try imageData(type: "public.jpeg"))
        let startOfFrame = Set<UInt8>([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf])
        var offset = 2
        while offset + 9 < bytes.count {
            if startOfFrame.contains(bytes[offset + 1]) { break }
            let length = Int(bytes[offset + 2]) * 256 + Int(bytes[offset + 3])
            offset += length + 2
        }
        try #require(offset + 9 < bytes.count)
        // Change the SOF width to 10,001. Reading metadata does not need a
        // bitmap with this width or a correspondingly large fixture.
        bytes[offset + 7] = 0x27; bytes[offset + 8] = 0x11
        let data = Data(bytes)
        // The header step reads the size and does not decode. Only the
        // dimension limit makes the difference.
        #expect(ImageDecoder.open(data, maxDimension: 10_001)?.width == 10_001)
        #expect(ImageDecoder.open(data, maxDimension: ImageLimits.kittyMaxDimension) == nil)
    }

    @Test func decodeTerminalImageHasTheTextureLimitsByDefault() throws {
        let terminal = Terminal(delegate: TerminalTestDelegate())
        let tall = try imageData(type: "public.png", width: 1, height: 16_385)
        #expect(terminal.decodeTerminalImage(try imageData(type: "public.png", width: 1, height: 16_384)) != nil)
        #expect(terminal.decodeTerminalImage(tall) == nil)
        #expect(terminal.decodeTerminalImage(tall, maxDimension: 65_535)?.height == 16_385)
    }

    @Test func decodeTerminalImageAppliesTheHostLimitsToTheResult() throws {
        let terminal = Terminal(delegate: TerminalTestDelegate())
        // The file has 16-bit samples: 48 bytes of samples, 24 bytes of RGBA.
        let data = try imageData(type: "public.png", width: 3, height: 2, bitsPerComponent: 16)
        #expect(ImageDecoder.open(data, maxDimension: 3, maxBytes: 47) == nil)
        #expect(terminal.decodeTerminalImage(data, maxBytes: 24)?.bytes.count == 24)
        #expect(terminal.decodeTerminalImage(data, maxBytes: 23) == nil)
        #expect(terminal.decodeTerminalImage(data, maxDimension: 3) != nil)
        #expect(terminal.decodeTerminalImage(data, maxDimension: 2) == nil)
    }
    #endif
}
