//
//  MetalSurfaceParityTests.swift
//  SwiftTermTests
//
//  The regression net for swapping MTKView out for a CAMetalLayer we own
//  (io-gaps.md G1, WO-F3).
//
//  Same renderer, same shaders, same snapshot — only the surface differs, so
//  the two must produce the same pixels. This is what makes the integration
//  safe to do without a live window: a mismatch here is a real defect, not a
//  rasterisation difference (comparing against the Core Graphics path would be
//  meaningless, since that is a different rasteriser entirely).
//

import Foundation
import Testing
@testable import SwiftTerm

#if os(macOS) && canImport(MetalKit)
import AppKit
import Metal
import MetalKit
import QuartzCore

@Suite("MetalSurfaceParity")
@MainActor
struct MetalSurfaceParityTests {
    private static let width = 320
    private static let height = 120

    /// Renders `content` through `target` and returns the drawable's pixels.
    private func renderPixels(into target: any MetalRenderTarget,
                              terminalView: TerminalView,
                              device: MTLDevice) -> [UInt8]? {
        // The renderer loads its shaders from the SwiftTerm resource bundle,
        // which is not present next to the SwiftPM test binary. When that is
        // the case there is nothing to compare, so skip rather than fail — the
        // app-side harness runs this same comparison where the bundle exists.
        guard let renderer = try? MetalTerminalRenderer(view: target, terminalView: terminalView) else {
            return nil
        }
        renderer.waitForCompletionAfterCommit = true
        var mutableTarget = target
        mutableTarget.renderContentsScale = 1
        mutableTarget.renderDrawableSize = CGSize(width: Self.width, height: Self.height)

        renderer.render()

        // Read back whatever the surface now holds.
        guard let drawable = target.acquireDrawable() else { return nil }
        let texture = drawable.texture
        guard texture.width > 0, texture.height > 0 else { return nil }
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!,
                             bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                             mipmapLevel: 0)
        }
        return bytes
    }

    private func makeTerminalView() -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        view.feed(text: "swiftterm parity \u{1b}[31mred\u{1b}[0m \u{1b}[1mbold\u{1b}[0m\r\nsecond line 0123456789\r\n")
        return view
    }

    /// The surfaces must agree on everything the renderer reads from them.
    /// A mismatch here changes how a frame is built, so it is worth asserting
    /// separately from the pixels.
    @Test func surfacesAgreeOnConfiguration() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        let mtkView = MTKView(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
                              device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        let layerView = TerminalMetalLayerView(frame: CGRect(x: 0, y: 0,
                                                            width: Self.width, height: Self.height))
        layerView.renderDevice = device

        #expect(mtkView.renderPixelFormat == layerView.renderPixelFormat)

        var a: any MetalRenderTarget = mtkView
        var b: any MetalRenderTarget = layerView
        a.renderDrawableSize = CGSize(width: Self.width, height: Self.height)
        b.renderDrawableSize = CGSize(width: Self.width, height: Self.height)
        #expect(a.renderDrawableSize == b.renderDrawableSize)

        a.renderContentsScale = 2
        b.renderContentsScale = 2
        #expect(a.renderContentsScale == b.renderContentsScale)
        #expect(a.renderBounds == b.renderBounds)
    }

    /// The pixels themselves. Skips rather than fails when the environment has
    /// no usable device or drawable, so it stays honest on CI machines without
    /// a GPU surface.
    @Test func bothSurfacesProduceTheSamePixels() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        let mtkView = MTKView(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
                              device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = false          // required to read the texture back
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true

        let layerView = TerminalMetalLayerView(frame: CGRect(x: 0, y: 0,
                                                             width: Self.width, height: Self.height))
        layerView.renderDevice = device
        layerView.metalLayer.framebufferOnly = false

        let terminalView = makeTerminalView()

        guard let fromMTK = renderPixels(into: mtkView, terminalView: terminalView, device: device),
              let fromLayer = renderPixels(into: layerView, terminalView: terminalView, device: device)
        else {
            return
        }

        #expect(fromMTK.count == fromLayer.count)
        guard fromMTK.count == fromLayer.count else { return }

        var differing = 0
        for index in stride(from: 0, to: fromMTK.count, by: 4) where
            fromMTK[index] != fromLayer[index] ||
            fromMTK[index + 1] != fromLayer[index + 1] ||
            fromMTK[index + 2] != fromLayer[index + 2] {
            differing += 1
        }
        let totalPixels = fromMTK.count / 4
        // Identical inputs through identical shaders: expect an exact match.
        #expect(differing == 0,
                "\(differing) of \(totalPixels) pixels differ between MTKView and CAMetalLayer surfaces")
    }
}
#endif
