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

    @Test func headerRejectsInvalidOrExcessiveDimensionsBeforeDecode() {
        let delegate = TerminalTestDelegate()
        let terminal = Terminal(delegate: delegate)
        for (width, height): (UInt32, UInt32) in [(0, 1), (1, 0), (.max, 1), (1, .max), (10_001, 1), (10_000, 10_000)] {
            let data = header(width: width, height: height)
            #expect(!terminal.validateKittyPNGHeader(data))
            #expect(terminal.decodeTerminalImage(data) == nil)
        }
        #expect(!terminal.validateKittyPNGHeader(Data(header(width: 1, height: 1).prefix(24))))
        #expect(terminal.validateKittyPNGHeader(header(width: 1, height: 1)))
        #expect(terminal.validateKittyPNGHeader(header(width: 1000, height: 1000)))
    }

    @Test func budgetUsesThePNGSampleLayout() {
        let delegate = TerminalTestDelegate()
        let terminal = Terminal(delegate: delegate)
        for colorType: UInt8 in [0, 2, 3, 4, 6] {
            #expect(terminal.validateKittyPNGHeader(header(width: 8000, height: 8000, depth: 8, colorType: colorType)))
        }
        for colorType: UInt8 in [0, 2, 4] {
            #expect(terminal.validateKittyPNGHeader(header(width: 8000, height: 8000, depth: 16, colorType: colorType)))
        }
        #expect(!terminal.validateKittyPNGHeader(header(width: 8000, height: 8000, depth: 16, colorType: 6)))
        #expect(!terminal.validateKittyPNGHeader(header(width: 1, height: 1, depth: 16, colorType: 3)))
        #expect(!terminal.validateKittyPNGHeader(header(width: 1, height: 1, depth: 4, colorType: 2)))
    }

    #if canImport(ImageIO) && canImport(CoreGraphics)
    private func imageData(type: String) throws -> Data {
        let pixel = Data([255, 0, 0, 255])
        let provider = try #require(CGDataProvider(data: pixel as CFData))
        let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test(arguments: ["public.jpeg", "com.compuserve.gif", "public.tiff"])
    func imageIOMetadataAndDecodeAcceptOtherContainers(type: String) throws {
        let delegate = TerminalTestDelegate()
        let terminal = Terminal(delegate: delegate)
        let data = try imageData(type: type)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let dimensions = try #require(terminal.validatedKittyImageDimensions(source))
        #expect(dimensions.width == 1 && dimensions.height == 1)
        let decoded = try #require(terminal.decodeTerminalImage(data))
        #expect(decoded.width == 1 && decoded.height == 1)
    }

    @Test func jpegDimensionsAreRejectedBeforeBitmapDecode() throws {
        let delegate = TerminalTestDelegate()
        let terminal = Terminal(delegate: delegate)
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
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 10_001)
        #expect(terminal.validatedKittyImageDimensions(source) == nil)
        #expect(terminal.decodeTerminalImage(data) == nil)
    }
    #endif
}
