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
import Foundation

#if canImport(MetalKit)
import MetalKit
#endif

/// Immutable geometry published by a view for one drawable surface.
struct MetalSurfaceGeometry: Sendable, Equatable {
    let bounds: CGRect
    let drawableSize: CGSize
    let contentsScale: CGFloat
}

/// A drawable and its immutable render state.
///
/// The producer and renderer use this value synchronously on one thread. The
/// Metal objects do not cross an additional concurrency boundary here.
struct MetalDrawableFrame {
    let drawable: any CAMetalDrawable
    let renderPassDescriptor: MTLRenderPassDescriptor
    let geometry: MetalSurfaceGeometry
}

/// The part of a surface that the render thread can use.
protocol MetalRenderSurface: Sendable {
    /// Acquires one drawable using the last geometry published by main.
    func acquireDrawableFrame() -> MetalDrawableFrame?
}

/// Main-actor view configuration for a Metal surface.
@MainActor
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

    /// Immutable geometry that is safe to publish to a render surface.
    var renderGeometry: MetalSurfaceGeometry { get }

    /// A render-thread surface, or nil when this target draws only on main.
    var detachedRenderSurface: (any MetalRenderSurface)? { get }

    /// Acquires a frame on main. The MTKView path uses this method.
    func acquireDrawableFrame() -> MetalDrawableFrame?

    /// True when the surface has no display callback of its own, so the host
    /// must call `MetalTerminalRenderer.render()` itself.
    ///
    /// `MTKView` is false: `setNeedsDisplay` makes AppKit call the delegate.
    /// The layer surface is true, and getting this wrong spins the frame
    /// driver — request a frame, get marked dirty, tick, request again — while
    /// never drawing anything.
    var needsExternalDrawCall: Bool { get }

    /// Asks the surface to schedule another frame.
    func requestDisplay()
}

#if canImport(MetalKit)
@MainActor
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

    // NSView.layer is optional, UIView.layer is not.
#if os(macOS)
    var renderContentsScale: CGFloat {
        get { layer?.contentsScale ?? 1 }
        set { layer?.contentsScale = newValue }
    }
#else
    var renderContentsScale: CGFloat {
        get { layer.contentsScale }
        set { layer.contentsScale = newValue }
    }
#endif

    var renderGeometry: MetalSurfaceGeometry {
        MetalSurfaceGeometry(bounds: bounds,
                             drawableSize: drawableSize,
                             contentsScale: renderContentsScale)
    }

    var detachedRenderSurface: (any MetalRenderSurface)? { nil }

    func acquireDrawableFrame() -> MetalDrawableFrame? {
        // MTKView builds this itself, including depth and stencil attachments
        // when configured, so use its descriptor rather than assembling one.
        guard let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor else { return nil }
        return MetalDrawableFrame(drawable: drawable,
                                  renderPassDescriptor: descriptor,
                                  geometry: renderGeometry)
    }

    var needsExternalDrawCall: Bool { false }

    func requestDisplay() {
#if os(macOS)
        setNeedsDisplay(bounds)
#else
        setNeedsDisplay()
#endif
    }
}

/// Main-actor adapter for the MTKView display cycle.
///
/// Snapshot preparation completes before drawable acquisition. The renderer
/// owns no view reference; hosts retain this adapter beside the renderer.
@MainActor
final class MetalMainActorDrawDelegate: NSObject, MTKViewDelegate {
    private weak var terminalView: TerminalView?
    private let renderOwner: TerminalRenderOwner

    init(terminalView: TerminalView, renderOwner: TerminalRenderOwner) {
        self.terminalView = terminalView
        self.renderOwner = renderOwner
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // MTKView publishes its new geometry before the next draw.
    }

    func draw(in view: MTKView) {
        if !renderOwner.metalHasPreparedSnapshot {
            guard terminalView?.refreshSnapshotForMetal() == true else { return }
        }
        // Keep this after snapshot preparation: refreshSnapshotForMetal takes
        // the terminal lock, and drawable acquisition must never run under it.
        guard let frame = view.acquireDrawableFrame() else { return }
        renderOwner.renderMetal(frame: frame)
    }
}
#endif
#endif
