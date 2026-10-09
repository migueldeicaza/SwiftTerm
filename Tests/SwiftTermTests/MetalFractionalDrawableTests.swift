//
//  MetalFractionalDrawableTests.swift
//  SwiftTermTests
//
//  A view under a non-integral scale (for example a terminal hosted inside a
//  zoomed canvas) ends up with a fractional drawableSize. The drawable's
//  texture is truncated to whole pixels, so the viewport handed to the shaders
//  must come from the texture, not from drawableSize. Otherwise every cell is
//  placed slightly off, the error grows towards the right edge, and once it
//  passes half a pixel the linear sampler reads the neighbouring glyph in the
//  atlas: box-drawing lines show short vertical ticks and stray dots.
//

import Foundation
import Testing
@testable import SwiftTerm

#if os(macOS) && canImport(MetalKit)
import AppKit
import Metal
import MetalKit
import QuartzCore

@Suite("MetalFractionalDrawable")
@MainActor
struct MetalFractionalDrawableTests {
    private static let width = 320
    private static let height = 120

    /// Renders through `target` with the given drawable size and returns the
    /// texture's pixels, or nil when the environment cannot render.
    private func renderPixels(into target: any MetalRenderTarget,
                              drawableSize: CGSize,
                              terminalView: TerminalView) -> (width: Int, height: Int, bytes: [UInt8])? {
        target.renderContentsScale = 1
        target.renderDrawableSize = drawableSize
        guard let renderer = try? MetalTerminalRenderer(target: target) else {
            return nil
        }
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesRenderedTexture = true
        guard terminalView.renderSnapshotForMetal(renderer: renderer,
                                                  target: target) else { return nil }
        guard let texture = renderer.lastRenderedTexture,
              texture.width > 0, texture.height > 0 else { return nil }
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!,
                             bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                             mipmapLevel: 0)
        }
        return (texture.width, texture.height, bytes)
    }

    private func makeTerminalView() -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        let line = String(repeating: "\u{2500}", count: 60)
        view.feed(text: "\u{1b}[2m\(line)\u{1b}[0m\r\n> prompt\r\n\u{1b}[2m\(line)\u{1b}[0m\r\n")
        return view
    }

    private func makeTargets(device: MTLDevice) -> [(String, any MetalRenderTarget)] {
        let mtkView = MTKView(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
                              device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = false
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true

        let layerView = TerminalMetalLayerView(frame: CGRect(x: 0, y: 0,
                                                             width: Self.width, height: Self.height))
        layerView.renderDevice = device
        layerView.metalLayer.framebufferOnly = false
        return [("MTKView", mtkView), ("CAMetalLayer", layerView)]
    }

    /// A fractional drawable size that truncates to the same texture must
    /// produce exactly the same pixels as the whole-pixel size.
    @Test func fractionalDrawableSizeMatchesTruncatedSize() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let whole = CGSize(width: Self.width, height: Self.height)
        let fractional = CGSize(width: Double(Self.width) + 0.75, height: Double(Self.height) + 0.75)

        for (name, target) in makeTargets(device: device) {
            let terminalView = makeTerminalView()
            guard let reference = renderPixels(into: target, drawableSize: whole, terminalView: terminalView),
                  let shifted = renderPixels(into: target, drawableSize: fractional, terminalView: terminalView)
            else {
                continue
            }
            #expect(reference.width == shifted.width && reference.height == shifted.height,
                    "\(name): texture size changed with the fractional drawable size")
            guard reference.bytes.count == shifted.bytes.count else { continue }

            var differing = 0
            for index in stride(from: 0, to: reference.bytes.count, by: 4) where
                reference.bytes[index] != shifted.bytes[index] ||
                reference.bytes[index + 1] != shifted.bytes[index + 1] ||
                reference.bytes[index + 2] != shifted.bytes[index + 2] {
                differing += 1
            }
            #expect(differing == 0,
                    "\(name): \(differing) of \(reference.bytes.count / 4) pixels differ with a fractional drawable size")
        }
    }
}
#endif
