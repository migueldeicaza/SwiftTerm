#if os(iOS) && canImport(MetalKit)
import MetalKit
import Testing
@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct IOSMetalBackgroundOpacityTests {
    @Test func opacityChangesUpdateTheActiveMetalSurface() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        defer { view.frameDriver.invalidate() }
        view.backgroundOpacity = 1
        try view.setUseMetal(true)
        let surface = try #require(view.metalView)
        let delegate = try #require(surface.delegate)
        #expect(!surface.isOpaque)
        #expect(!surface.layer.isOpaque)

        // Change from solid to animated backgrounds, then back to solid.
        for opacity: CGFloat in [0, 0.5, 1, -1, 2] {
            view.backgroundOpacity = opacity
            let expectedOpacity = max(0, min(1, opacity))
            #expect(view.backgroundOpacity == expectedOpacity)
            #expect(!surface.isOpaque)
            #expect(!surface.layer.isOpaque)
            #expect(view.metalView === surface)
            #expect(surface.delegate === delegate)
        }
    }

    @Test(arguments: [CGFloat(0), 0.5, 1])
    func metalStartsWithTheCurrentBackgroundOpacity(_ opacity: CGFloat) throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        defer { view.frameDriver.invalidate() }
        view.backgroundOpacity = opacity

        try view.setUseMetal(true)

        let surface = try #require(view.metalView)
        #expect(!surface.isOpaque)
        #expect(!surface.layer.isOpaque)
    }

    @Test(arguments: [CGFloat(0), 0.5, 1])
    func metalPixelsCompositeTheDefaultBackgroundOnce(_ opacity: CGFloat) throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        defer { view.frameDriver.invalidate() }
        let white = UIColor(red: 1, green: 1, blue: 1, alpha: 1)
        let background: UIColor = opacity == 1 ? white : .red
        view.nativeForegroundColor = white
        view.nativeBackgroundColor = background
        view.backgroundOpacity = opacity
        view.feed(text: "\u{1b}[?25l\u{1b}[42m \u{1b}[0m\u{1b}[7m \u{1b}[0m")
        try view.setUseMetal(true)
        let surface = try #require(view.metalView)
        surface.framebufferOnly = false
        let renderer = try MetalTerminalRenderer(target: surface)
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesRenderedTexture = true

        let state = FrameViewState(view: view)
        let context = SnapshotRenderContext(viewState: state, style: .empty,
            ansiColors: view.withTerminal { $0.ansiColors }, cols: 80)
        #expect(context.metalClearColor.cgColor.alpha == 0)
        #expect(context.effectiveBackgroundColor == background)
        #expect(mapColor(color: .defaultInvertedColor, isFg: true,
            isBold: false, context: context) == background)
        #expect(mapColor(color: .ansi256(code: 2), isFg: false,
            isBold: false, context: context).cgColor.alpha == 1)

        #expect(view.renderSnapshotForMetal(renderer: renderer, target: surface))
        let texture = try #require(renderer.lastRenderedTexture)
        let rowBytes = texture.width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * texture.height)
        pixels.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: rowBytes,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        // Default cells must contain transparent black, not opaque RGB pixels.
        #expect(Array(pixels.suffix(4)) == [0, 0, 0, 0])
        // Explicit and inverse backgrounds must still produce opaque pixels.
        var hasGreenBackground = false
        var hasInverseBackground = false
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let blue = pixels[offset]
            let green = pixels[offset + 1]
            let red = pixels[offset + 2]
            guard pixels[offset + 3] == 255 else { continue }
            hasGreenBackground = hasGreenBackground || (green > blue && green > red)
            hasInverseBackground = hasInverseBackground || (red == 255 && green == 255 && blue == 255)
        }
        #expect(hasGreenBackground)
        #expect(hasInverseBackground)

        // Composite one default pixel over the host layer and a blue backdrop.
        let bitmap = try #require(CGContext(data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(UIColor.blue.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        bitmap.setFillColor(try #require(view.layer.backgroundColor))
        bitmap.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let sample = Array(pixels.suffix(4))
        bitmap.setFillColor(UIColor(red: CGFloat(sample[2]) / 255,
            green: CGFloat(sample[1]) / 255, blue: CGFloat(sample[0]) / 255,
            alpha: CGFloat(sample[3]) / 255).cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let result = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
        #expect(abs(Int(result[0]) - Int((opacity * 255).rounded())) <= 1)
        #expect(result[1] == (opacity == 1 ? 255 : 0))
        let blue = opacity == 1 ? 255 : Int(((1 - opacity) * 255).rounded())
        #expect(abs(Int(result[2]) - blue) <= 1)

        view.feed(text: "\u{1b}[?5h")
        let reversed = FrameViewState(view: view)
        #expect(reversed.metalClearColor.alpha == 1)
        #expect(view.renderSnapshotForMetal(renderer: renderer, target: surface))
        let reverseTexture = try #require(renderer.lastRenderedTexture)
        var reversePixel = [UInt8](repeating: 0, count: 4)
        reversePixel.withUnsafeMutableBytes {
            reverseTexture.getBytes($0.baseAddress!, bytesPerRow: 4,
                from: MTLRegionMake2D(reverseTexture.width - 1, reverseTexture.height - 1, 1, 1),
                mipmapLevel: 0)
        }
        #expect(reversePixel[3] == 255)
    }

}
#endif
