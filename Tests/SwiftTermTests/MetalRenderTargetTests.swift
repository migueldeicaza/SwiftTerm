//
//  MetalRenderTargetTests.swift
//  SwiftTermTests
//
//  Covers the render-target abstraction that lets the Metal renderer draw into
//  a surface we own rather than an MTKView (io-gaps.md G1, WO-F3).
//

import Foundation
import Testing
@testable import SwiftTerm

#if os(macOS) && canImport(Metal)
import Metal
import QuartzCore

@Suite("MetalRenderTarget")
@MainActor
struct MetalRenderTargetTests {
    @Test func layerViewIsBackedByAMetalLayer() {
        let view = TerminalMetalLayerView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(view.layer is CAMetalLayer)
        #expect(view.metalLayer.pixelFormat == .bgra8Unorm)
        // Presenting from a non-main thread requires this to stay false.
        #expect(view.metalLayer.presentsWithTransaction == false)
    }

    @Test func drawableSizeAndScaleRoundTrip() {
        let view = TerminalMetalLayerView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let target: any MetalRenderTarget = view

        target.renderDrawableSize = CGSize(width: 400, height: 200)
        #expect(target.renderDrawableSize == CGSize(width: 400, height: 200))

        target.renderContentsScale = 2
        #expect(target.renderContentsScale == 2)
        #expect(target.renderBounds.width == 200)
        #expect(target.renderGeometry == MetalSurfaceGeometry(
            bounds: view.bounds,
            drawableSize: target.renderDrawableSize,
            contentsScale: 2))
    }

    /// A zero-sized surface must yield no drawable rather than trapping, since
    /// the renderer can be asked to draw before layout has run.
    @Test func zeroSizedSurfaceYieldsNoDrawable() {
        let view = TerminalMetalLayerView(frame: .zero)
        view.renderDevice = MTLCreateSystemDefaultDevice()
        #expect(view.acquireDrawableFrame() == nil)
    }

    @Test func renderPassDescriptorTargetsTheDrawableTexture() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let view = TerminalMetalLayerView(frame: CGRect(x: 0, y: 0, width: 64, height: 32))
        view.renderDevice = device
        view.renderDrawableSize = CGSize(width: 64, height: 32)

        guard let frame = view.acquireDrawableFrame() else { return }
        let descriptor = frame.renderPassDescriptor
        #expect(descriptor.colorAttachments[0].texture === frame.drawable.texture)
        #expect(descriptor.colorAttachments[0].loadAction == .clear)
        #expect(descriptor.colorAttachments[0].storeAction == .store)
    }

    @Test func detachedSurfacePublishesGeometryAsSendableState() throws {
        func acceptSendable<T: Sendable>(_: T) {}

        let view = TerminalMetalLayerView(frame: CGRect(x: 0, y: 0,
                                                        width: 80, height: 40))
        view.renderContentsScale = 2
        let surface = try #require(view.detachedRenderSurface)
        acceptSendable(surface)
        #expect(view.renderGeometry.drawableSize == CGSize(width: 160, height: 80))
        #expect(view.renderGeometry.contentsScale == 2)
    }

    /// The surface must not schedule frames itself; the host decides.
    @Test func requestDisplayForwardsToTheHost() {
        let view = TerminalMetalLayerView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        var asked = 0
        view.onNeedsDisplay = { asked += 1 }
        view.requestDisplay()
        #expect(asked == 1)
    }
}
#endif
