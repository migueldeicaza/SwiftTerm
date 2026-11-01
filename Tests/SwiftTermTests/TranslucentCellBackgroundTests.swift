//
//  TranslucentCellBackgroundTests.swift
//  SwiftTermTests
//
//  `translucentCellBackgrounds` gives explicit cell backgrounds the default
//  background's alpha. These tests go through the paths the renderers use:
//  `SnapshotTextBuilder` for the colors, and the Core Graphics and Metal
//  renderers for the composited pixels, where an explicit fill must replace the
//  translucent default background instead of compositing over it.
//

import Foundation
import Testing
@testable import SwiftTerm

#if os(macOS)
import AppKit

@Suite("TranslucentCellBackgrounds")
@MainActor
struct TranslucentCellBackgroundTests {
    static let red = Attribute.Color.ansi256(code: 1)
    static let palette = Attribute.Color.ansi256(code: 33)
    static let teal = Attribute.Color.trueColor(red: 10, green: 120, blue: 130)

    private func makeView(opacity: CGFloat, translucent: Bool) -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.nativeBackgroundColor = .black
        view.backgroundOpacity = opacity
        view.translucentCellBackgrounds = translucent
        return view
    }

    private func makeContext(_ view: TerminalView) -> SnapshotRenderContext {
        SnapshotRenderContext(viewState: FrameViewState(view: view), style: .empty,
                              ansiColors: view.withTerminal { $0.ansiColors }, cols: 80)
    }

    private func colors(_ attribute: Attribute, view: TerminalView)
        -> (foreground: TTColor, background: TTColor, explicit: Bool)
    {
        let attributes = SnapshotTextBuilder().getAttributes(attribute, withUrl: false,
                                                             context: makeContext(view))!
        return (attributes[.foregroundColor] as! TTColor,
                attributes[.backgroundColor] as! TTColor,
                attributes[SwiftTermExplicitBackgroundKey] != nil)
    }

    private func backgroundAlpha(_ color: Attribute.Color, view: TerminalView) -> CGFloat {
        colors(Attribute(fg: .defaultColor, bg: color, style: .none), view: view)
            .background.alphaComponent
    }

    @Test func explicitBackgroundsStayOpaqueByDefault() {
        let view = makeView(opacity: 0.4, translucent: false)
        #expect(view.translucentCellBackgrounds == false)
        #expect(makeContext(view).translucentCellBackgroundAlpha == nil)
        #expect(backgroundAlpha(Self.red, view: view) == 1)
        #expect(backgroundAlpha(Self.palette, view: view) == 1)
        #expect(backgroundAlpha(Self.teal, view: view) == 1)
    }

    @Test func explicitBackgroundsTakeTheDefaultBackgroundAlpha() {
        let view = makeView(opacity: 0.4, translucent: true)
        #expect(abs(makeContext(view).translucentCellBackgroundAlpha! - 0.4) < 0.001)
        #expect(abs(backgroundAlpha(Self.red, view: view) - 0.4) < 0.001)
        #expect(abs(backgroundAlpha(Self.palette, view: view) - 0.4) < 0.001)
        #expect(abs(backgroundAlpha(Self.teal, view: view) - 0.4) < 0.001)
        // The default background keeps its own (already translucent) color.
        #expect(abs(backgroundAlpha(.defaultColor, view: view) - 0.4) < 0.001)
    }

    /// The alpha is applied to the background fill only: the same palette entry
    /// or truecolor used for text stays opaque.
    @Test func foregroundUsesStayOpaque() {
        let view = makeView(opacity: 0.4, translucent: true)
        for color in [Self.red, Self.palette, Self.teal] {
            let mapped = colors(Attribute(fg: color, bg: color, style: .none), view: view)
            #expect(mapped.foreground.alphaComponent == 1)
            #expect(abs(mapped.background.alphaComponent - 0.4) < 0.001)
        }
        let underlined = SnapshotTextBuilder().getAttributes(
            Attribute(fg: .defaultColor, bg: Self.teal, style: .underline, underlineColor: Self.teal),
            withUrl: false, context: makeContext(view))!
        #expect((underlined[.underlineColor] as! TTColor).alphaComponent == 1)
    }

    /// Reverse video of the default pair is the one block that stays opaque;
    /// reverse video of an explicit color is an explicit background like any other.
    @Test func reverseVideoHighlightStaysOpaque() {
        let view = makeView(opacity: 0.4, translucent: true)
        let highlight = colors(Attribute(fg: .defaultColor, bg: .defaultColor, style: .inverse),
                               view: view)
        #expect(highlight.background.alphaComponent == 1)
        #expect(highlight.foreground.alphaComponent == 1)
        #expect(highlight.explicit)

        let inverted = colors(Attribute(fg: Self.teal, bg: .defaultColor, style: .inverse), view: view)
        #expect(abs(inverted.background.alphaComponent - 0.4) < 0.001)
        #expect(inverted.foreground.alphaComponent == 1)
    }

    /// Dim and minimum contrast work against the color the cell shows, not
    /// against its alpha: the text is the same with the option on or off.
    @Test func dimAndContrastUseTheOpaqueBackground() {
        let attribute = Attribute(fg: .ansi256(code: 4), bg: Self.teal, style: .dim)
        let opaqueView = makeView(opacity: 0.4, translucent: false)
        opaqueView.minimumContrastRatio = 4.5
        let translucentView = makeView(opacity: 0.4, translucent: true)
        translucentView.minimumContrastRatio = 4.5

        let opaque = colors(attribute, view: opaqueView)
        let translucent = colors(attribute, view: translucentView)
        #expect(opaque.foreground == translucent.foreground)
        #expect(translucent.foreground.alphaComponent == 1)
    }

    @Test func fullyOpaqueTerminalIsUnchanged() {
        let view = makeView(opacity: 1, translucent: true)
        #expect(makeContext(view).translucentCellBackgroundAlpha == nil)
        #expect(backgroundAlpha(Self.red, view: view) == 1)
        #expect(backgroundAlpha(Self.teal, view: view) == 1)
    }

    /// Global reverse video (DECSCNM) paints an opaque default background, so
    /// explicit backgrounds stay opaque over it.
    @Test func globalReverseVideoKeepsExplicitBackgroundsOpaque() {
        let view = makeView(opacity: 0.4, translucent: true)
        view.nativeForegroundColor = .white
        view.feed(text: "\u{1b}[?5h")
        #expect(makeContext(view).translucentCellBackgroundAlpha == nil)
        #expect(backgroundAlpha(Self.teal, view: view) == 1)
    }

    /// Toggling the option must invalidate every cache keyed on the context.
    @Test func contextIdentityTracksTheOption() {
        let view = makeView(opacity: 0.4, translucent: false)
        let off = makeContext(view).identity
        view.translucentCellBackgrounds = true
        let on = makeContext(view).identity
        #expect(off != on)
        view.backgroundOpacity = 0.6
        #expect(makeContext(view).identity != on)
        view.translucentCellBackgrounds = false
        view.backgroundOpacity = 0.4
        #expect(makeContext(view).identity == off)
    }

    /// One builder across a toggle, the way a renderer keeps its builder: the
    /// cached dictionaries must not leak the previous setting.
    @Test func builderCacheFollowsTheOption() {
        let view = makeView(opacity: 0.4, translucent: false)
        let builder = SnapshotTextBuilder()
        let attribute = Attribute(fg: .defaultColor, bg: Self.teal, style: .none)
        let before = builder.getAttributes(attribute, withUrl: false, context: makeContext(view))!
        #expect((before[.backgroundColor] as! TTColor).alphaComponent == 1)
        view.translucentCellBackgrounds = true
        let after = builder.getAttributes(attribute, withUrl: false, context: makeContext(view))!
        #expect(abs((after[.backgroundColor] as! TTColor).alphaComponent - 0.4) < 0.001)
    }

    /// Fills replace the default background, so the selection arrives composited
    /// over it; an opaque selection color is unchanged.
    @Test func selectionFillIsCompositedOverTheDefaultBackground() {
        let view = makeView(opacity: 0.4, translucent: true)
        view.selectedTextBackgroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5)
        let fill = makeContext(view).selectionFillColor.usingColorSpace(.sRGB)!
        // 0.5 white over 0.4 black: alpha 0.5 + 0.4 * 0.5 = 0.7, color 0.5 / 0.7.
        #expect(abs(fill.alphaComponent - 0.7) < 0.001)
        #expect(abs(fill.redComponent - 0.5 / 0.7) < 0.001)

        view.selectedTextBackgroundColor = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        #expect(makeContext(view).selectionFillColor.alphaComponent == 1)

        view.translucentCellBackgrounds = false
        view.selectedTextBackgroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5)
        #expect(makeContext(view).selectionFillColor.alphaComponent == 0.5)
    }

    // MARK: - Composited pixels

    /// Ten rows of 60 columns with an explicit truecolor background: covers the
    /// center of a 120x120 view whichever way the bitmap is oriented.
    static let explicitRows = String(repeating: "\u{1b}[48;2;200;0;0m" + String(repeating: " ", count: 60)
                                     + "\u{1b}[0m\r\n", count: 10)

    /// The Core Graphics renderer, composited the way Core Animation does it on
    /// screen: the view's backing store over its layer background.
    /// (`CALayer.render(in:)` does not composite an AppKit backing store over
    /// the layer background, so the composite is done here.)
    private func coreGraphicsCenterPixel(_ view: TerminalView) -> [UInt8] {
        let width = 120
        let height = 120
        // Publish the terminal contents to the snapshot the draw reads.
        if let state = view.captureFrameViewState() {
            _ = view.prepareFrame(viewState: state)
        }
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { storage in
            let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            if let background = view.layer?.backgroundColor {
                context.setFillColor(background)
                context.fill(bounds)
            }
            context.draw(rep.cgImage!, in: bounds)
        }
        let offset = (60 * width + 60) * 4
        return Array(pixels[offset..<(offset + 4)])
    }

    private func makePixelView(translucent: Bool, feed text: String = explicitRows) -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        view.nativeBackgroundColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        view.backgroundOpacity = 0.4
        view.translucentCellBackgrounds = translucent
        view.feed(text: text)
        return view
    }

    /// 0.4 alpha: 0.4 * 255 = 102, and premultiplied channels at 0.4 of the
    /// opaque fill. (The cached display is color managed, so the opaque fill
    /// is not exactly 200, 0, 0.)
    @Test func coreGraphicsExplicitBackgroundEndsAtBackgroundOpacity() {
        let on = coreGraphicsCenterPixel(makePixelView(translucent: true))
        let off = coreGraphicsCenterPixel(makePixelView(translucent: false))
        #expect(off[3] == 255)
        #expect(off[0] > 190)
        #expect(abs(Int(on[3]) - 102) <= 1, "alpha \(on[3]); 163 means the fill composited over the default background")
        for channel in 0..<3 {
            #expect(abs(Double(on[channel]) - Double(off[channel]) * 0.4) <= 2,
                    "channel \(channel): \(on) vs \(off)")
        }
    }

    @Test func coreGraphicsDefaultBackgroundIsUnchangedByTheOption() {
        let on = coreGraphicsCenterPixel(makePixelView(translucent: true, feed: ""))
        let off = coreGraphicsCenterPixel(makePixelView(translucent: false, feed: ""))
        #expect(on == off)
        #expect(abs(Int(on[3]) - 102) <= 1)
    }

    /// The strip below the last full row (a view height that is not a whole
    /// number of rows) shows the default background once, like the rows
    /// above it, with the option on or off.
    @Test func coreGraphicsBottomGapIsPaintedOnce() {
        for translucent in [false, true] {
            let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
            view.nativeBackgroundColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            view.backgroundOpacity = 0.4
            view.translucentCellBackgrounds = translucent
            let gap = view.bounds.height.truncatingRemainder(dividingBy: view.cellDimension.height)
            #expect(gap >= 2, "no gap to sample (cell height \(view.cellDimension.height))")
            guard gap >= 2 else { continue }
            let width = 120, height = 120
            if let state = view.captureFrameViewState() {
                _ = view.prepareFrame(viewState: state)
            }
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { storage in
                let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                        bitsPerComponent: 8, bytesPerRow: width * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                if let background = view.layer?.backgroundColor {
                    context.setFillColor(background)
                    context.fill(bounds)
                }
                context.draw(rep.cgImage!, in: bounds)
            }
            // The last bitmap row is the view's bottom edge: inside the gap.
            let alpha = pixels[((height - 2) * width + 60) * 4 + 3]
            #expect(abs(Int(alpha) - 102) <= 1, "translucent=\(translucent): gap alpha \(alpha)")
        }
    }

    @Test func coreGraphicsLayerBackgroundFollowsTheOption() {
        let view = makePixelView(translucent: true)
        #expect(view.layer?.backgroundColor?.alpha == 0)
        view.translucentCellBackgrounds = false
        #expect(abs((view.layer?.backgroundColor?.alpha ?? 0) - 0.4) < 0.001)
        view.translucentCellBackgrounds = true
        view.backgroundOpacity = 1
        #expect(view.layer?.backgroundColor?.alpha == 1)
    }
}

#if canImport(MetalKit)
import Metal
import MetalKit

@Suite("TranslucentCellBackgroundsMetal")
@MainActor
struct TranslucentCellBackgroundMetalTests {
    /// Renders one frame through the Metal renderer into a layer we own and
    /// returns the BGRA center pixel, or nil without a usable GPU surface.
    private func metalCenterPixel(_ view: TerminalView) -> [UInt8]? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let target = TerminalMetalLayerView(frame: view.bounds)
        target.renderDevice = device
        target.metalLayer.framebufferOnly = false
        target.renderContentsScale = 1
        target.renderDrawableSize = view.bounds.size
        guard let renderer = try? MetalTerminalRenderer(target: target) else { return nil }
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesRenderedTexture = true
        guard view.renderSnapshotForMetal(renderer: renderer, target: target),
              let texture = renderer.lastRenderedTexture,
              texture.width > 0, texture.height > 0 else { return nil }
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                             mipmapLevel: 0)
        }
        let offset = (texture.height / 2) * bytesPerRow + (texture.width / 2) * 4
        return Array(bytes[offset..<(offset + 4)])
    }

    private func makeView(translucent: Bool,
                          feed text: String = TranslucentCellBackgroundTests.explicitRows) -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        view.nativeBackgroundColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        view.backgroundOpacity = 0.4
        view.translucentCellBackgrounds = translucent
        view.feed(text: text)
        return view
    }

    /// BGRA, premultiplied: red 200 * 0.4 = 80 at alpha 102.
    @Test func metalExplicitBackgroundEndsAtBackgroundOpacity() {
        guard let pixel = metalCenterPixel(makeView(translucent: true)) else { return }
        #expect(abs(Int(pixel[3]) - 102) <= 1, "alpha \(pixel[3]); 163 means the fill blended over the pass clear")
        #expect(abs(Int(pixel[2]) - 80) <= 1)
        #expect(pixel[0] == 0 && pixel[1] == 0)
    }

    /// The pass clear is premultiplied like the background quads, so a
    /// translucent default background composites the way the Core Graphics
    /// layer background does (BGRA: blue 255 * 0.4 = 102 at alpha 102).
    @Test func metalTranslucentDefaultBackgroundIsPremultiplied() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        view.nativeBackgroundColor = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        view.backgroundOpacity = 0.4
        guard let pixel = metalCenterPixel(view) else { return }
        #expect(abs(Int(pixel[0]) - 102) <= 1)
        #expect(pixel[1] == 0 && pixel[2] == 0)
        #expect(abs(Int(pixel[3]) - 102) <= 1)
    }

    /// A cell whose explicit background is the default color looks like the
    /// default cells around it.
    @Test func metalExplicitDefaultColoredCellMatchesTheDefaultBackground() {
        let explicitBlue = String(repeating: "\u{1b}[48;2;0;0;255m" + String(repeating: " ", count: 60)
                                  + "\u{1b}[0m\r\n", count: 10)
        let explicit = TerminalView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        explicit.nativeBackgroundColor = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        explicit.backgroundOpacity = 0.4
        explicit.translucentCellBackgrounds = true
        explicit.feed(text: explicitBlue)
        let plain = TerminalView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        plain.nativeBackgroundColor = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        plain.backgroundOpacity = 0.4
        plain.translucentCellBackgrounds = true
        guard let a = metalCenterPixel(explicit), let b = metalCenterPixel(plain) else { return }
        for channel in 0..<4 {
            #expect(abs(Int(a[channel]) - Int(b[channel])) <= 1, "\(a) vs \(b)")
        }
    }

    @Test func metalExplicitBackgroundIsOpaqueWhenOff() {
        guard let pixel = metalCenterPixel(makeView(translucent: false)) else { return }
        #expect(pixel == [0, 0, 200, 255])
    }
}
#endif
#endif
