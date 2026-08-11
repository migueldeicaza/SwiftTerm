//
//  MetalRenderTarget.swift
//  SwiftTerm
//
//  The surface a Metal frame is drawn into.
//
//  `MTKView` draws through AppKit/UIKit: it calls its delegate from the view
//  system's display cycle, on the main thread. That is fine while rendering is
//  a main-thread activity, and it is the reason rendering cannot leave the main
//  thread today (io-gaps.md G1).
//
//  This protocol names the eight things the renderer actually needs from its
//  surface, so the renderer can be handed either an `MTKView` (today) or a
//  `CAMetalLayer` we own and drive ourselves (WO-F3), without knowing which.
//

#if os(macOS) || os(iOS) || os(visionOS) || os(macCatalyst)
import Metal
import QuartzCore

#if canImport(MetalKit)
import MetalKit
#endif

/// A surface the terminal renderer can draw a frame into.
protocol MetalRenderTarget: AnyObject {
    /// Settable: the renderer picks the system default device when the
    /// surface has none, then hands it back.
    var renderDevice: MTLDevice? { get set }
    var renderPixelFormat: MTLPixelFormat { get }
    /// Size of the drawable in pixels. Setting it resizes the surface.
    var renderDrawableSize: CGSize { get set }
    /// Bounds in points, used to derive the drawable size.
    var renderBounds: CGRect { get }
    /// Backing scale of the surface; the renderer keeps it in step with the
    /// display it is on.
    var renderContentsScale: CGFloat { get set }

    /// The next drawable to render into, or nil when none is available.
    func acquireDrawable() -> (any CAMetalDrawable)?

    /// A render pass targeting `drawable`. The caller sets the clear color.
    func makeRenderPassDescriptor(for drawable: any CAMetalDrawable) -> MTLRenderPassDescriptor?

    /// Asks the surface to schedule another frame.
    func requestDisplay()
}

#if canImport(MetalKit)
extension MTKView: MetalRenderTarget {
    var renderDevice: MTLDevice? {
        get { device }
        set { device = newValue }
    }
    var renderPixelFormat: MTLPixelFormat { colorPixelFormat }

    var renderDrawableSize: CGSize {
        get { drawableSize }
        set { drawableSize = newValue }
    }

    var renderBounds: CGRect { bounds }

    var renderContentsScale: CGFloat {
        get { layer?.contentsScale ?? 1 }
        set { layer?.contentsScale = newValue }
    }

    func acquireDrawable() -> (any CAMetalDrawable)? {
        currentDrawable
    }

    func makeRenderPassDescriptor(for drawable: any CAMetalDrawable) -> MTLRenderPassDescriptor? {
        // MTKView builds this itself, including depth and stencil attachments
        // when configured, so use its descriptor rather than assembling one.
        currentRenderPassDescriptor
    }

    func requestDisplay() {
#if os(macOS)
        setNeedsDisplay(bounds)
#else
        setNeedsDisplay()
#endif
    }
}
#endif
#endif
