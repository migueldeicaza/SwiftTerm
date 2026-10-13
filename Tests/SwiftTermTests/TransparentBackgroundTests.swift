#if canImport(UIKit)
import CoreGraphics
import UIKit
import XCTest
@testable import SwiftTerm

@MainActor
final class TransparentBackgroundTests: XCTestCase {
    private func backgroundPixel(_ view: TerminalView) -> [UInt8] {
        let width = 40
        let height = 40
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { storage in
            let context = CGContext(data: storage.baseAddress,
                                    width: width,
                                    height: height,
                                    bitsPerComponent: 8,
                                    bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            // A partial redraw must remove pixels from the previous frame.
            context.setFillColor(UIColor.red.cgColor)
            context.fill(view.bounds)
            UIGraphicsPushContext(context)
            view.draw(view.bounds)
            UIGraphicsPopContext()
        }
        let offset = (20 * width + 20) * 4
        return Array(pixels[offset..<(offset + 4)])
    }

    func testDefaultBackgroundClearsOldPixels() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.nativeBackgroundColor = .black
        view.backgroundOpacity = 0

        XCTAssertEqual(backgroundPixel(view), [0, 0, 0, 0])
    }

    func testGlobalReverseVideoPaintsAnOpaqueBackground() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        view.backgroundOpacity = 0
        view.feed(text: "\u{1b}[?5h")

        XCTAssertEqual(backgroundPixel(view), [255, 255, 255, 255])

        view.feed(text: "\u{1b}[?5l")
        XCTAssertEqual(backgroundPixel(view), [0, 0, 0, 0])
    }
}
#endif
