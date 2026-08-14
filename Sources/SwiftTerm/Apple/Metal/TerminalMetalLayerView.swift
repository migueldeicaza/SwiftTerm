//
//  TerminalMetalLayerView.swift
//  SwiftTerm
//
//  A view backed by a CAMetalLayer that we drive ourselves.
//
//  `MTKView` renders from the view system's display cycle: AppKit calls the
//  delegate on the main thread, and there is no supported way to have it call
//  anywhere else. That is the last structural reason terminal rendering has to
//  happen on the main thread (io-gaps.md G1).
//
//  Owning the layer removes that constraint. `nextDrawable()` and command
//  encoding can be called from any thread, so a render loop can drive frames
//  while the main thread is busy — which the baselines show is exactly when
//  frames stop today.
//
//  This type deliberately does no scheduling of its own: something else (the
//  frame driver now, a render loop in WO-F4) decides when to call
//  `MetalTerminalRenderer.render()`.
//

#if os(macOS) || os(iOS) || os(visionOS) || os(macCatalyst)
import Metal
import QuartzCore

#if os(macOS)
import AppKit
typealias TerminalMetalLayerViewBase = NSView
#else
import UIKit
typealias TerminalMetalLayerViewBase = UIView
#endif

/// A `CAMetalLayer`-backed view that renders on demand.
final class TerminalMetalLayerView: TerminalMetalLayerViewBase {
    /// Called when the surface wants a frame — a resize, or a layer rebuild.
    /// The host decides how to service it.
    var onNeedsDisplay: (() -> Void)?

#if !os(macOS)
    override class var layerClass: AnyClass { CAMetalLayer.self }
#endif

    var metalLayer: CAMetalLayer {
#if os(macOS)
        // wantsLayer plus makeBackingLayer guarantees this type.
        return layer as! CAMetalLayer
#else
        return layer as! CAMetalLayer
#endif
    }

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
#if os(macOS)
        wantsLayer = true
        // We repaint the whole surface every frame, so AppKit does not need to
        // preserve or redraw layer contents on resize.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
#endif
        let metal = metalLayer
        metal.pixelFormat = .bgra8Unorm
        // Tag the layer sRGB so the compositor color-manages our pixels the
        // same way it manages a layer-backed NSView's backing store. Untagged,
        // CAMetalLayer's bytes are treated as already in the display's gamut
        // and come out oversaturated on a wide-gamut display — most visible on
        // selection highlights and non-default cell backgrounds.
        //
        // This matches `MacTerminalView.makeMetalView`. Note that the
        // MTKView/CAMetalLayer pixel-parity check cannot catch a mismatch
        // here: it compares the raw texture bytes, which are identical either
        // way, while colorspace changes how those bytes are composited.
        metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // The renderer only ever writes the color attachment, so let Metal
        // optimise for that.
        metal.framebufferOnly = true
        // Presenting from a thread other than main requires that Core Animation
        // not batch our present into the main thread's transaction.
        metal.presentsWithTransaction = false
        updateDrawableSize()
    }

    /// Keeps Core Animation geometry changes on the main thread. The render
    /// thread consumes the resulting drawable but does not read view bounds or
    /// mutate layer properties.
    private func updateDrawableSize() {
        let scale = metalLayer.contentsScale
        guard scale > 0 else { return }
        renderDrawableSize = CGSize(width: bounds.width * scale,
                                    height: bounds.height * scale)
    }

#if os(macOS)
    override func makeBackingLayer() -> CALayer {
        let metal = CAMetalLayer()
        metal.needsDisplayOnBoundsChange = true
        return metal
    }

    override var isOpaque: Bool { metalLayer.isOpaque }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            renderContentsScale = scale
        } else {
            updateDrawableSize()
        }
        onNeedsDisplay?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        onNeedsDisplay?()
    }
#else
    override func layoutSubviews() {
        super.layoutSubviews()
        renderContentsScale = window?.screen.scale ?? contentScaleFactor
        onNeedsDisplay?()
    }
#endif
}

extension TerminalMetalLayerView: MetalRenderTarget {
    var renderDevice: MTLDevice? {
        get { metalLayer.device }
        set { metalLayer.device = newValue }
    }

    var renderPixelFormat: MTLPixelFormat { metalLayer.pixelFormat }

    var renderDrawableSize: CGSize {
        get { metalLayer.drawableSize }
        set {
            // Assigning an unchanged size still invalidates the drawable pool,
            // so guard it: this is touched every frame.
            guard newValue.width > 0, newValue.height > 0,
                  metalLayer.drawableSize != newValue else { return }
            metalLayer.drawableSize = newValue
        }
    }

    var renderBounds: CGRect { bounds }

    var renderContentsScale: CGFloat {
        get { metalLayer.contentsScale }
        set {
            guard newValue > 0, metalLayer.contentsScale != newValue else { return }
            metalLayer.contentsScale = newValue
            updateDrawableSize()
        }
    }

    func acquireDrawable() -> (any CAMetalDrawable)? {
        // Returns nil when the pool is exhausted or the layer has no size yet;
        // the renderer treats that as "skip this frame".
        guard metalLayer.drawableSize.width > 0, metalLayer.drawableSize.height > 0 else {
            return nil
        }
        return metalLayer.nextDrawable()
    }

    func makeRenderPassDescriptor(for drawable: any CAMetalDrawable) -> MTLRenderPassDescriptor? {
        let descriptor = MTLRenderPassDescriptor()
        let color = descriptor.colorAttachments[0]
        color?.texture = drawable.texture
        // The caller sets clearColor before encoding.
        color?.loadAction = .clear
        color?.storeAction = .store
        return descriptor
    }

    /// Nothing calls back into us the way AppKit calls an MTKView delegate,
    /// so the host must drive `render()` directly.
    var needsExternalDrawCall: Bool { true }

    func requestDisplay() {
        onNeedsDisplay?()
    }
}
#endif
