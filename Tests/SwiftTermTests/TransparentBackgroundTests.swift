#if canImport(UIKit)
import CoreGraphics
import UIKit
import XCTest
@testable import SwiftTerm

@MainActor
final class TransparentBackgroundTests: XCTestCase {
    private func drainColorCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func composedBackgroundPixel(_ view: TerminalView) -> [UInt8] {
        let width = 120
        let height = 120
        if let state = view.captureFrameViewState() {
            _ = view.prepareFrame(viewState: state)
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { storage in
            let context = CGContext(data: storage.baseAddress,
                                    width: width,
                                    height: height,
                                    bitsPerComponent: 8,
                                    bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            view.setNeedsDisplay()
            view.layer.displayIfNeeded()
            view.layer.render(in: context)
        }
        let offset = (60 * width + 60) * 4
        return Array(pixels[offset..<(offset + 4)])
    }

    func testNativeBackgroundColorIsVisible() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        view.nativeBackgroundColor = .blue

        XCTAssertEqual(composedBackgroundPixel(view), [0, 0, 255, 255])
    }

    func testClearNativeBackgroundPreservesHostLayerColor() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        view.layer.backgroundColor = UIColor.red.cgColor
        await drainColorCallbacks()
        XCTAssertEqual(composedBackgroundPixel(view), [255, 0, 0, 255])

        view.nativeBackgroundColor = .blue
        view.layer.backgroundColor = UIColor.red.cgColor
        view.nativeBackgroundColor = .clear
        await drainColorCallbacks()
        XCTAssertEqual(composedBackgroundPixel(view), [255, 0, 0, 255])
    }

    func testOSC11BackgroundColorIsVisible() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        view.feed(text: "\u{1b}]11;rgb:0000/0000/ffff\u{7}")
        // OSC color changes reach the layer through a main-queue callback.
        await drainColorCallbacks()

        XCTAssertEqual(composedBackgroundPixel(view), [0, 0, 255, 255])
    }

    func testOSC11BackgroundColorChangePreservesOpacity() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        view.backgroundOpacity = 0.5
        view.feed(text: "\u{1b}]11;rgb:0000/0000/ffff\u{7}")
        await drainColorCallbacks()

        let pixel = composedBackgroundPixel(view)
        XCTAssertEqual(pixel[0], 0)
        XCTAssertEqual(pixel[1], 0)
        XCTAssertEqual(pixel[2], pixel[3])
        XCTAssertEqual(Int(pixel[3]), 128, accuracy: 1)
    }

    func testOSC11BackgroundColorFromBackgroundThreadIsVisible() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        await Task.detached {
            view.feed(text: "\u{1b}]11;rgb:0000/0000/ffff\u{7}")
        }.value
        await drainColorCallbacks()

        XCTAssertEqual(composedBackgroundPixel(view), [0, 0, 255, 255])
    }

    func testBackgroundColorChangePreservesOpacity() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        view.backgroundOpacity = 0.5
        view.nativeBackgroundColor = .blue

        let pixel = composedBackgroundPixel(view)
        XCTAssertEqual(pixel[0], 0)
        XCTAssertEqual(pixel[1], 0)
        XCTAssertEqual(pixel[2], pixel[3])
        XCTAssertEqual(Int(pixel[3]), 128, accuracy: 1)
    }

    func testBackgroundColorChangeDuringReverseVideoIsRestored() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        view.backgroundOpacity = 0.5
        view.feed(text: "\u{1b}[?5h")
        await drainColorCallbacks()
        view.nativeBackgroundColor = .blue

        XCTAssertEqual(composedBackgroundPixel(view), [255, 255, 255, 255])

        view.feed(text: "\u{1b}[?5l")
        await drainColorCallbacks()
        let pixel = composedBackgroundPixel(view)
        XCTAssertEqual(pixel[0], 0)
        XCTAssertEqual(pixel[1], 0)
        XCTAssertEqual(pixel[2], pixel[3])
        XCTAssertEqual(Int(pixel[3]), 128, accuracy: 1)
    }

    func testBackgroundColorChangeBeforeReverseVideoRestoreIsVisible() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        view.nativeBackgroundColor = .black
        view.feed(text: "\u{1b}[?5h")
        await drainColorCallbacks()

        view.feed(text: "\u{1b}[?5l")
        view.nativeBackgroundColor = .blue
        await drainColorCallbacks()

        XCTAssertEqual(composedBackgroundPixel(view), [0, 0, 255, 255])
    }

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
