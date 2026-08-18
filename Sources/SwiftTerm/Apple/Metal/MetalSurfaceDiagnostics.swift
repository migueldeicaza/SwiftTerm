//
//  MetalSurfaceDiagnostics.swift
//  SwiftTerm
//
//  Compares the two Metal surfaces by rendering the same content through both.
//
//  This exists because the equivalent unit test cannot run: the renderer loads
//  its shaders from the SwiftTerm resource bundle, which is not present next to
//  the SwiftPM test binary. Inside a host app the bundle is there, so the check
//  runs for real.
//
//  It is the regression net for WO-F3 (replacing MTKView with a CAMetalLayer we
//  drive ourselves). Same renderer, same shaders, same snapshot — only the
//  surface differs, so the pixels must match exactly.
//

#if os(macOS) && canImport(MetalKit)
import Foundation
import AppKit
import Metal
import MetalKit
import QuartzCore

extension TerminalView {
    /// Result of comparing the `MTKView` and `CAMetalLayer` render surfaces.
    public struct MetalSurfaceComparison {
        /// Pixels whose RGB differs between the two surfaces. Zero is the
        /// expected result.
        public let differingPixels: Int
        public let totalPixels: Int
        /// Pixels that differ from the top-left pixel. A comparison of two
        /// blank surfaces would report a perfect match, so this guards against
        /// the check silently passing on nothing.
        public let nonUniformPixels: Int
        /// Set when the comparison could not run; both counts are zero then.
        public let unavailableReason: String?

        /// True only when the surfaces agree *and* they actually drew
        /// something.
        public var matches: Bool {
            unavailableReason == nil && differingPixels == 0 && nonUniformPixels > 0
        }
    }

    /// Renders deterministic content through both Metal surfaces and compares
    /// the results.
    ///
    /// Uses a terminal view it creates and sizes to match the surfaces, rather
    /// than a live one: the renderer positions rows from
    /// `SnapshotRenderContext.viewBounds`, so a view whose bounds differ from
    /// the drawable puts every row outside it and both surfaces come back
    /// blank — which compares equal and proves nothing.
    ///
    /// Diagnostic only — it builds throwaway renderers and blocks on the GPU,
    /// so it must not be called on a frame path.
    public static func compareMetalSurfaces(width: Int = 320, height: Int = 120) -> MetalSurfaceComparison {
        func unavailable(_ reason: String) -> MetalSurfaceComparison {
            MetalSurfaceComparison(differingPixels: 0, totalPixels: 0,
                                   nonUniformPixels: 0, unavailableReason: reason)
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            return unavailable("no Metal device")
        }
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        let frame = CGRect(origin: .zero, size: size)

        let mtkView = MTKView(frame: frame, device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = false        // needed to read the texture back
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true

        let layerView = TerminalMetalLayerView(frame: frame)
        layerView.renderDevice = device
        layerView.metalLayer.framebufferOnly = false

        // Sized to the surfaces so rows land inside the drawable, and fed
        // content with several colors so a blank render cannot pass.
        let source = TerminalView(frame: frame)
        source.feed(text: "SwiftTerm surface parity check\r\n"
                    + "\u{1b}[31mred\u{1b}[32m green\u{1b}[34m blue\u{1b}[0m plain\r\n"
                    + "\u{1b}[1mbold\u{1b}[0m \u{1b}[4munderline\u{1b}[0m 0123456789\r\n")

        guard let fromMTK = renderPixels(source: source, target: mtkView, size: size),
              let fromLayer = renderPixels(source: source, target: layerView, size: size) else {
            return unavailable("no drawable or renderer available")
        }
        guard fromMTK.count == fromLayer.count else {
            return unavailable("surfaces produced different buffer sizes")
        }

        var differing = 0
        var nonUniform = 0
        let firstR = fromMTK[0], firstG = fromMTK[1], firstB = fromMTK[2]
        for index in stride(from: 0, to: fromMTK.count, by: 4) where
            fromMTK[index] != firstR || fromMTK[index + 1] != firstG ||
            fromMTK[index + 2] != firstB {
            nonUniform += 1
        }
        for index in stride(from: 0, to: fromMTK.count, by: 4) where
            fromMTK[index] != fromLayer[index] ||
            fromMTK[index + 1] != fromLayer[index + 1] ||
            fromMTK[index + 2] != fromLayer[index + 2] {
            differing += 1
        }
        return MetalSurfaceComparison(differingPixels: differing,
                                      totalPixels: fromMTK.count / 4,
                                      nonUniformPixels: nonUniform,
                                      unavailableReason: nil)
    }

    private static func renderPixels(source: TerminalView,
                                     target: any MetalRenderTarget,
                                     size: CGSize) -> [UInt8]? {
        target.renderContentsScale = 1
        target.renderDrawableSize = size
        guard let renderer = try? MetalTerminalRenderer(target: target) else {
            return nil
        }
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesRenderedTexture = true
        guard source.renderSnapshotForMetal(renderer: renderer,
                                            target: target) else { return nil }

        // The texture the renderer actually drew into. Asking the surface for
        // another drawable would return a different, unrendered one.
        guard let texture = renderer.lastRenderedTexture else { return nil }
        guard texture.width > 0, texture.height > 0 else { return nil }
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(base,
                             bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                             mipmapLevel: 0)
        }
        return bytes
    }
}
#endif
