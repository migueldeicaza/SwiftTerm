//
//  MacTerminalView.swift
//
// This is the AppKit version of the TerminalView and holds the state
// variables in the `TerminalView` class, but as much of the terminal
// implementation details live in the Apple/AppleTerminalView which
// contains the shared AppKit/UIKit code
//
//  Created by Miguel de Icaza on 3/4/20.
//
#if os(macOS)
import Foundation
import AppKit
import CoreText
import CoreGraphics
import Carbon.HIToolbox
#if canImport(MetalKit)
import MetalKit
#endif
#if canImport(os)
import os.log
#endif

/**
 * TerminalView provides an AppKit front-end to the `Terminal` termininal emulator.
 * It is up to a subclass to either wire the terminal emulator to a remote terminal
 * via some socket, to an application that wants to run with terminal emulation, or
 * wiring this up to a pseudo-terminal.
 *
 * Users are notified of interesting events in their implementation of the `TerminalViewDelegate`
 * methods - an instance must be provided to the constructor of `TerminalView`.
 *
 * Developers might want to surface UIs for `optionAsMetaKey` and `allowMouseReporting` in
 * their application.  They both default to true, but this means that Option-Letter is hijacked for
 * terminal purposes to send the sequence ESC-Letter, instead of the macOS specific character and
 * means that when mouse-aware applications are running, they hijack the normal selection process.
 *
 * Call the `getTerminal` method to get a reference to the underlying `Terminal` that backs this
 * view.
 *
 * Use the `configureNativeColors()` to set the defaults colors for the view to match the OS
 * defaults, otherwise, this uses its own set of defaults colors.
 */
open class TerminalView: NSView, NSTextInputClient, NSUserInterfaceValidations, TerminalDelegate {
#if canImport(MetalKit)
    // Default to throttling Metal redraws during live-resize; set SWIFTTERM_METAL_LIVE_RESIZE_THROTTLE=0 to disable.
    private static let metalLiveResizeThrottleEnabled: Bool = {
        let value = ProcessInfo.processInfo.environment["SWIFTTERM_METAL_LIVE_RESIZE_THROTTLE"]
        if value == "0" || value == "false" || value == "FALSE" {
            return false
        }
        return true
    }()
#endif
    private static let regularArrowKeyCodes: Set<UInt16> = [
        UInt16(kVK_LeftArrow),
        UInt16(kVK_RightArrow),
        UInt16(kVK_DownArrow),
        UInt16(kVK_UpArrow)
    ]

    // Per-window state for the macOS 26 mouse-moved fallback. `acceptsMouseMovedEvents`
    // is an NSWindow-wide setting and a single `.mouseMoved` local monitor is enough
    // to service every terminal view in the window, so this state is shared per window
    // rather than per view (multiple terminal views can share a window, e.g. a
    // split-pane host). It is a reference type so the monitor and the weak view set
    // can be mutated in place while held in the registry.
    private final class MouseMovedFallbackWindowState {
        // The window's `acceptsMouseMovedEvents` value before we turned it on, so we
        // can put it back when the last interested terminal view stops tracking.
        let originalAcceptsMouseMovedEvents: Bool
        // The single local monitor servicing this window (removed with the last view).
        var monitor: Any?
        // The terminal views in this window that currently want move tracking.
        let views = NSHashTable<TerminalView>.weakObjects()

        init(originalAcceptsMouseMovedEvents: Bool) {
            self.originalAcceptsMouseMovedEvents = originalAcceptsMouseMovedEvents
        }
    }

    // Guards `mouseMovedFallbackWindowStates` and the per-window state it holds. NSView
    // deinit is expected on the main thread, but a stray off-main last release would
    // otherwise race begin/end and corrupt the registry, so serialize all access.
    private static let mouseMovedFallbackLock = NSLock()
    private static var mouseMovedFallbackWindowStates: [ObjectIdentifier: MouseMovedFallbackWindowState] = [:]

    private static func beginWindowMouseMovedFallback(view: TerminalView, window: NSWindow) {
        mouseMovedFallbackLock.lock()
        defer { mouseMovedFallbackLock.unlock() }

        let identifier = ObjectIdentifier(window)
        let state: MouseMovedFallbackWindowState
        if let existing = mouseMovedFallbackWindowStates[identifier] {
            state = existing
        } else {
            state = MouseMovedFallbackWindowState(originalAcceptsMouseMovedEvents: window.acceptsMouseMovedEvents)
            mouseMovedFallbackWindowStates[identifier] = state
            window.acceptsMouseMovedEvents = true
            // A single window-scoped monitor dispatches to whichever view the pointer is
            // over. It captures only the window identifier (a value), never the window or
            // the state, so nothing is retained. Note: local monitors do not fire while
            // the application is inactive, so background mouse-move reporting that the old
            // `.activeAlways` tracking area provided is not available on macOS 26.
            state.monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
                TerminalView.dispatchWindowMouseMoved(event, windowIdentifier: identifier)
                // Never consume the event: sibling/overlay `.mouseMoved` tracking areas and
                // AppKit's normal first-responder delivery must still see it.
                return event
            }
        }
        state.views.add(view)
    }

    // `window` may be nil if it was deallocated before the view's deinit ran (ARC zeroes
    // the weak reference first). The identifier still lets us drop the registry entry so a
    // later NSWindow reusing the same address does not inherit stale state.
    private static func endWindowMouseMovedFallback(view: TerminalView, identifier: ObjectIdentifier, window: NSWindow?) {
        mouseMovedFallbackLock.lock()
        defer { mouseMovedFallbackLock.unlock() }

        guard let state = mouseMovedFallbackWindowStates[identifier] else { return }
        state.views.remove(view)
        guard state.views.allObjects.isEmpty else { return }

        mouseMovedFallbackWindowStates.removeValue(forKey: identifier)
        if let monitor = state.monitor {
            NSEvent.removeMonitor(monitor)
            state.monitor = nil
        }
        // Restore the original setting only if it is still the `true` we wrote. If the host
        // changed it out from under us we leave its choice in place rather than clobber it.
        if let window, window.acceptsMouseMovedEvents {
            window.acceptsMouseMovedEvents = state.originalAcceptsMouseMovedEvents
        }
    }

    // Called on the main thread from the per-window monitor. Delivers the move to every
    // terminal view in the window; each view decides whether the pointer is over it.
    private static func dispatchWindowMouseMoved(_ event: NSEvent, windowIdentifier: ObjectIdentifier) {
        mouseMovedFallbackLock.lock()
        let views = mouseMovedFallbackWindowStates[windowIdentifier]?.views.allObjects ?? []
        mouseMovedFallbackLock.unlock()

        for view in views {
            view.handleWindowMouseMoved(event)
        }
    }

    struct FontSet {
        public let normal: NSFont
        let bold: NSFont
        let italic: NSFont
        let boldItalic: NSFont
        
        static var defaultFont: NSFont {
            if #available(macOS 10.15, *)  {
                return NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            } else {
                return NSFont(name: "Menlo Regular", size: NSFont.systemFontSize) ?? NSFont(name: "Courier", size: NSFont.systemFontSize)!
            }
        }
        
        public init(font baseFont: NSFont, fontSize: CGFloat? = nil) {
            self.normal = baseFont
            self.bold = NSFontManager.shared.convert(baseFont, toHaveTrait: [.boldFontMask])
            self.italic = NSFontManager.shared.convert(baseFont, toHaveTrait: [.italicFontMask])
            self.boldItalic = NSFontManager.shared.convert(baseFont, toHaveTrait: [.italicFontMask, .boldFontMask])
        }

        // Expected by the shared rendering code
        func underlinePosition () -> CGFloat
        {
            return normal.underlinePosition
        }

        // Expected by the shared rendering code
        func underlineThickness () -> CGFloat
        {
            return normal.underlineThickness
        }
    }
    
    /**
     * The delegate that the TerminalView uses to interact with its hosting
     */
    public weak var terminalDelegate: TerminalViewDelegate?
    
    /// If true, the caret view will show different shapes depending on the focus
    /// otherwise, it will behave like it is focused
    public var caretViewTracksFocus: Bool {
        get {
            return caretView.tracksFocus
        }
        set {
            caretView.tracksFocus = newValue
#if canImport(MetalKit)
            frameDriver.markDirty()
#endif
        }
    }

    var accessibility: AccessibilityService = AccessibilityService()
    var search: SearchService!
    private var findBar: TerminalFindBarView?
    private var findBarTerm: String = ""
    private var findBarOptions: SearchOptions = SearchOptions()
    var debug: TerminalDebugView?
    let viewStateLock = NSLock()
    final var frameDriver: FrameDriver!
    var scrolledDirty: Bool = false
    var suppressAccessibilityForNextFrame = false
    // viewStateLock-guarded mirror of terminal.reverseColors (DECSCNM); see
    // effectiveNativeForegroundColor for why draw paths must not read the
    // terminal's flag directly. Access via reverseColorsActiveValue()/
    // setReverseColorsActive().
    var reverseColorsActive: Bool = false
    var textBlinkVisible = true
    var textBlinkTimer: Timer?
    var textBlinkObservers: [(NotificationCenter, NSObjectProtocol)] = []
    var textBlinkApplicationActive = true
    /// Owned by whoever prepares frames: the main thread normally, the render
    /// loop when one is running (io-gaps.md G1, WO-F4). Never both.
    var currentSnapshot = TerminalSnapshot()
    var currentSnapshotRenderContext: SnapshotRenderContext?
    /// viewStateLock-guarded handover of the main thread's per-frame capture to
    /// the render loop.
    var publishedFrameViewState: FrameViewState?
    /// viewStateLock-guarded copy of the last frame's blinking rows, so the
    /// blink timer on main never reads the snapshot the render loop owns.
    var lastBlinkRows: [Int] = []
    /// viewStateLock-guarded resize waiting for the next frame, in cells.
    /// Cells rather than points because the conversion reads view state
    /// (io-gaps.md G5b).
    var pendingTerminalSize: (cols: Int, rows: Int)?

    var cursorColorIsDefault = true
    var cursorTextColorIsDefault = true

    // Guards the diagnostics counters, which the parse thread increments once
    // per batch. Deliberately not the terminal lock: see recordFedBytes.
    /// Builds styled segments for the Core Graphics draw path. The Metal
    /// renderer owns a separate instance, so the two never share a cache.
    let textBuilder = SnapshotTextBuilder()

    let diagnosticsLock = NSLock()
    var diagnosticsCounters = TerminalView.Diagnostics()
#if canImport(MetalKit)
    var metalView: (NSView & MetalRenderTarget)?
    var metalRenderer: MetalTerminalRenderer?
    /// Prepares and draws frames off the main thread. Non-nil only for the
    /// layer surface (io-gaps.md G1, WO-F4).
    ///
    /// Assigned on main, but read from the parse thread as well, so every
    /// access goes through `viewStateLock` — see `activeRenderLoop()`.
    private var renderLoopStorage: RenderLoop?

    /// The running render loop, or nil. Safe from any thread.
    func activeRenderLoop () -> RenderLoop? {
        viewStateLock.lock()
        let loop = renderLoopStorage
        viewStateLock.unlock()
        guard let loop, loop.isRunning else { return nil }
        return loop
    }

    var renderLoop: RenderLoop? {
        viewStateLock.lock()
        defer { viewStateLock.unlock() }
        return renderLoopStorage
    }
    /// Experimental GPU path: CoreText glyph atlas + Metal quads.
    /// Limitations: image caching is basic; GPU path is still evolving.
    private var useMetalRenderer = false
    /// The NSWindow that the current `metalView`'s CAMetalLayer is bound to.
    /// CAMetalLayer's binding to a window's WindowServer surface doesn't
    /// survive being reparented across NSWindow instances — `present(_:)`
    /// silently no-ops on the new window, leaving the terminal frozen on its
    /// last frame. When `viewDidMoveToWindow` fires with a different window,
    /// we rebuild the MTKView so a fresh CAMetalLayer binds to it.
    private weak var metalBoundWindow: NSWindow?
    /// Controls how the Metal renderer builds GPU buffers each frame.
    ///
    /// The default is ``MetalBufferingMode/perRowPersistent``, which caches
    /// per-row vertex data and only rebuilds dirty rows. Switch to
    /// ``MetalBufferingMode/perFrameAggregated`` for workloads that repaint
    /// most of the screen every frame.
    ///
    /// You can change this property at any time; the renderer picks up the
    /// new mode on the next frame.
    public var metalBufferingMode: MetalBufferingMode = .perRowPersistent

    /// Overrides the backing scale used by the Metal renderer.
    ///
    /// Client applications that apply their own view transforms can set this
    /// to the effective on-screen pixels-per-point value so Metal rasterizes
    /// glyphs at the same scale the transformed view is displayed at.
    public var metalScaleFactorOverride: CGFloat? {
        didSet {
            guard oldValue != metalScaleFactorOverride else { return }
            guard useMetalRenderer else { return }
            let scale = metalRenderingScaleFactor()
            metalView?.renderContentsScale = scale
            metalView?.renderDrawableSize = CGSize(width: bounds.width * scale,
                                                    height: bounds.height * scale)
            frameDriver.markDirty()
        }
    }

    /// Whether the terminal view is currently using the Metal GPU renderer.
    ///
    /// Returns `true` after a successful call to ``setUseMetal(_:)`` with
    /// `true`, and `false` otherwise.
    public var isUsingMetalRenderer: Bool {
        return useMetalRenderer
    }

    /// Draws one Metal frame immediately when the Metal renderer is active.
    ///
    /// Normal applications do not need this method. It supports deterministic
    /// snapshots and tests when the main run loop cannot process an on-demand
    /// `MTKView` draw before the snapshot starts.
    public func drawMetalFrameNow() {
        guard useMetalRenderer, metalView != nil, let metalRenderer else { return }
        // The render loop owns the snapshot while it is running, so borrow it
        // rather than racing it. Rare and main-thread-only, so the wait is not
        // on any hot path.
        withRenderLoopSuspended {
            guard let refreshed = refreshSnapshotForMetal() else { return }
            metalRenderer.prepareSnapshotForImmediateDraw(snapshot: refreshed.snapshot,
                                                          context: refreshed.context)
            metalRenderer.render()
            metalRenderer.discardPreparedSnapshot()
        }
    }

    /// True when frames are prepared and drawn on the render loop rather than
    /// on the main thread.
    ///
    /// Only the layer surface can do this: `MTKView` draws from AppKit's
    /// display cycle, which is main-thread only (io-gaps.md G1, WO-F4).
    var usesRenderLoop: Bool {
        activeRenderLoop() != nil
    }

    /// Whether frames are being prepared and drawn on a render loop rather
    /// than on the main thread.
    ///
    /// Public because a report that names the renderer must ask what actually
    /// ran rather than re-derive it from the launch flags — the two drifted
    /// apart the moment the default changed, and a mislabelled row is worse
    /// than no row.
    public var isUsingRenderLoop: Bool {
        usesRenderLoop
    }

    func startRenderLoopIfNeeded () {
        guard usesMetalLayerSurfaceSetting, metalView?.needsExternalDrawCall == true else {
            return
        }
        let loop = RenderLoop()
        loop.onRender = { [weak self] in self?.renderLoopFrame() }
        viewStateLock.lock()
        renderLoopStorage = loop
        viewStateLock.unlock()
        loop.start()
    }

    func stopRenderLoop () {
        viewStateLock.lock()
        let loop = renderLoopStorage
        renderLoopStorage = nil
        viewStateLock.unlock()
        loop?.invalidate()
    }

    /// Runs `body` on the main thread with no frame in flight.
    ///
    /// Use it for anything structural: replacing the surface, tearing the
    /// renderer down, drawing a frame synchronously. Must not be called while
    /// holding the terminal lock — see `RenderLoop.frameLock`.
    func withRenderLoopSuspended<T> (_ body: () -> T) -> T {
        guard let renderLoop, renderLoop.isRunning else { return body() }
        renderLoop.frameLock.lock()
        defer { renderLoop.frameLock.unlock() }
        return body()
    }

    /// One frame, on the render thread.
    ///
    /// Prepare and draw happen here; everything that needs AppKit is posted
    /// back to main afterwards. The order matters: the frame reaches the GPU
    /// before the main queue is asked to do anything, so a busy main thread
    /// delays the caret and the scroller, not the pixels.
    private func renderLoopFrame () {
        guard let viewState = takePublishedFrameViewState() else { return }
        guard let prepared = prepareFrame(viewState: viewState) else { return }
        submitFrameDraw(prepared)
        DispatchQueue.main.async { [weak self] in
            self?.applyFrameSideEffects(prepared)
        }
    }
#endif

    var cellDimension: CellDimension!
    var cachedCellPointSize: CGSize?
    var cachedImageScale: CGFloat?
    var cachedCellPixelSize: (width: Int, height: Int)?
    var cachedNativeColors: (foreground: Color, background: Color)?
    var caretView: CaretView!
    var _fontSmoothing: Bool = true
    var _lineSpacing: CGFloat = 1.0
    public var terminal: Terminal!

    /// Marked (uncommitted) text from an input source (IME, dictation, etc.).
    private var markedTextStorage: NSAttributedString?
    private var markedSelectedRange: NSRange = NSRange(location: NSNotFound, length: 0)
    private var markedTextOverlay: DictationOverlayTextView?
    private var progressBarView: TerminalProgressBarView?
    private var progressReportTimer: Timer?
    private var lastProgressValue: UInt8?

    /// Tracks the selection state of the terminal, and can be used to set it
    /// programmatically (see `SelectionService`).
    public var selection: SelectionService!
    private var scroller: NSScroller!
    
    // Attribute dictionary, maps a console attribute (color, flags) to the corresponding dictionary
    // of attributes for an NSAttributedString
    var attributes: [Attribute: [NSAttributedString.Key:Any]] = [:]
    var urlAttributes: [Attribute: [NSAttributedString.Key:Any]] = [:]
    
    
    // Cache for the colors in the 0..255 range
    var colors: [NSColor?] = Array(repeating: nil, count: 256)
    var trueColors: [Attribute.Color:NSColor] = [:]
    var transparent = TTColor.transparent ()
    var isBigSur = true
    
    /// This flag is automatically set to true after the initializer is called, if running on a system older than BigSur.
    /// Starting with BigSur any screen updates will invoke the draw() method with the whole region, regardless
    /// of how much changed.   Setting this to true, will disable this OS behavior, setting it to false, will keep
    /// the original BigSur behavior to redraw the whole region.
    ///
    /// For more details on this see:
    /// https://gist.github.com/lukaskubanek/9a61ac71dc0db8bb04db2028f2635779
    /// https://developer.apple.com/forums/thread/663256?answerId=646653022#646653022
    public var disableFullRedrawOnAnyChanges = false
    var fontSet: FontSet

    /// Options used to create the `Terminal` that backs this view; set by `init(frame:font:options:)`,
    /// consumed by `setupOptions` when the view creates its terminal
    var startupOptions: TerminalOptions = TerminalOptions.default

    /// The font to use to render the terminal
    public var font: NSFont {
        get {
            return fontSet.normal
        }
        set {
            fontSet = FontSet (font: newValue)
            resetFont()
            selectNone()
        }
    }
    
    public init(frame: CGRect, font: NSFont?) {
        self.fontSet = FontSet (font: font ?? FontSet.defaultFont)

        super.init (frame: frame)
        _nativeFg = NSColor.textColor
        _nativeBg = NSColor.textBackgroundColor
        setup()
    }

    /// Creates a terminal view with explicit startup options; the `cols` and `rows` in the options
    /// are used as-is for a zero-sized frame, and are otherwise recomputed from the frame size
    public init(frame: CGRect, font: NSFont? = nil, options: TerminalOptions) {
        self.startupOptions = options
        self.fontSet = FontSet (font: font ?? FontSet.defaultFont)

        super.init (frame: frame)
        _nativeFg = NSColor.textColor
        _nativeBg = NSColor.textBackgroundColor
        setup()
    }


    public override init (frame: CGRect)
    {
        self.fontSet = FontSet (font: FontSet.defaultFont)
        super.init (frame: frame)
        _nativeFg = NSColor.textColor
        _nativeBg = NSColor.textBackgroundColor
        setup()
    }
    
    public required init? (coder: NSCoder)
    {
        self.fontSet = FontSet (font: FontSet.defaultFont)
        super.init (coder: coder)
        _nativeFg = NSColor.textColor
        _nativeBg = NSColor.textBackgroundColor
        setup()
    }
    
    private func setup()
    {
        wantsLayer = true
        isBigSur = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 11, minorVersion: 0, patchVersion: 0))
        if isBigSur {
            disableFullRedrawOnAnyChanges = true
        }
        if #available(macOS 14, *) {
            self.clipsToBounds = true
        }
        setupScroller()
        setupFrameDriver()
        eventQueue.onDrain = { [weak self] event in
            self?.applyTerminalEvent(event)
        }
        eventQueue.canDeliverInline = { [weak self] in
            guard let self, let terminal = self.terminal else { return false }
            return !terminal.terminalLock.isLockedByCurrentThread
        }
        setupOptions()
        setupProgressBar()
        setupFocusNotification()
        setupTextBlinking()
    }

#if canImport(MetalKit)
    /// Enables or disables GPU-accelerated rendering via Metal.
    ///
    /// When enabled, the terminal view replaces its CoreGraphics rendering
    /// path with a Metal-based renderer that rasterizes glyphs into a
    /// texture atlas and draws cells as GPU quads. This can significantly
    /// reduce CPU usage for large or rapidly-updating terminals.
    ///
    /// Metal rendering is **disabled by default**. Call this method after
    /// the view has been added to a window:
    ///
    /// ```swift
    /// try terminalView.setUseMetal(true)
    /// ```
    ///
    /// You can switch back to CoreGraphics at any time by passing `false`.
    ///
    /// - Parameter enabled: Pass `true` to activate Metal rendering, or
    ///   `false` to revert to CoreGraphics.
    /// - Throws: ``MetalError`` if the Metal device or pipeline cannot be
    ///   initialized (for example, on hardware without Metal support).
    public func setUseMetal(_ enabled: Bool) throws {
        if enabled == useMetalRenderer {
            return
        }
        if enabled {
            try updateMetalRenderer(enabled: true)
            useMetalRenderer = true
        } else {
            try updateMetalRenderer(enabled: false)
            useMetalRenderer = false
        }
    }

    private func updateMetalRenderer(enabled: Bool) throws {
        if enabled {
            if metalView != nil {
                return
            }
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw MetalError.deviceUnavailable
            }
            let surface = makeMetalView(frame: bounds, device: device)
            let renderer = try MetalTerminalRenderer(view: surface, terminalView: self)
            renderer.requestRedraw = { [weak self] in self?.frameDriver?.markDirty() }
            bindSurface(surface, to: renderer)
            insertMetalView(surface, replacing: nil)
            metalView = surface
            metalRenderer = renderer
            metalBoundWindow = window
            startRenderLoopIfNeeded()
            // Metal's clear color paints the background; if the host layer
            // painted it too, a translucent background would composite twice
            layer?.backgroundColor = NSColor.clear.cgColor
            needsDisplay = false
            surface.requestDisplay()
        } else {
            stopRenderLoop()
            unbindSurface(metalView)
            metalView?.removeFromSuperview()
            metalView = nil
            metalRenderer = nil
            metalBoundWindow = nil
            layer?.backgroundColor = effectiveNativeBackgroundColor.cgColor
            if let caretView = caretView {
                caretView.isHidden = false
                caretView.updateCursorStyle()
            }
            needsDisplay = true
            invalidateTerminalContents()
        }
    }

    func metalRenderingScaleFactor() -> CGFloat {
        max(1, metalScaleFactorOverride ?? backingScaleFactor())
    }

    /// The value `usesMetalLayerSurface` starts at. `SWIFTTERM_METAL_LAYER=0`
    /// picks the `MTKView` surface at launch, the same way `--metal` picks the
    /// renderer at launch — an initial value, not the switch itself.
    static let defaultUsesMetalLayerSurface =
        ProcessInfo.processInfo.environment["SWIFTTERM_METAL_LAYER"] != "0"

    /// Whether the renderer draws into a `CAMetalLayer` this view owns, which
    /// is what lets frames be prepared and drawn on a render loop instead of
    /// the main thread (io-gaps.md G1).
    ///
    /// **On by default since WO-F5.** On the bidi flood the main-thread stall
    /// p99 is 0.03–0.12 ms against 6.9–19.1 ms for `MTKView`, with throughput
    /// and frame production unchanged.
    ///
    /// Settable at runtime, like ``setUseMetal(_:)``: setting it while Metal
    /// is active rebuilds the surface in place, so a misbehaving frame can be
    /// compared against the other surface without relaunching and losing
    /// whatever provoked it. `MTKView` remains the only surface on iOS.
    public var usesMetalLayerSurface: Bool {
        get { usesMetalLayerSurfaceSetting }
        set { try? setUsesMetalLayerSurface(newValue) }
    }

    /// Selects the Metal surface, rebuilding it if Metal is already running.
    ///
    /// Throws for the same reasons ``setUseMetal(_:)`` does — the rebuild can
    /// fail to create a device, renderer or shader library — in which case the
    /// view falls back to Core Graphics rather than keeping a dead surface.
    public func setUsesMetalLayerSurface(_ enabled: Bool) throws {
        guard usesMetalLayerSurfaceSetting != enabled else { return }
        usesMetalLayerSurfaceSetting = enabled
        // Not running Metal: the choice applies the next time it starts.
        guard useMetalRenderer else { return }
        try updateMetalRenderer(enabled: false)
        try updateMetalRenderer(enabled: true)
    }

    private var usesMetalLayerSurfaceSetting =
        TerminalView.defaultUsesMetalLayerSurface

    /// Builds the Metal surface configured for terminal rendering. Used by both
    /// initial Metal enablement and `rebindMetalRendererToWindow` so the two
    /// paths can never drift out of sync on configuration.

    /// Connects a surface to its renderer.
    ///
    /// The two surfaces are driven differently, and this is the only place
    /// that difference lives: `MTKView` calls its delegate from AppKit's
    /// display cycle, while the layer surface has no delegate and asks us for
    /// a frame through a closure — which is what lets a render loop take over
    /// in WO-F4.
    private func bindSurface(_ surface: NSView & MetalRenderTarget,
                             to renderer: MetalTerminalRenderer) {
        if let mtkView = surface as? MTKView {
            mtkView.delegate = renderer
        } else if let layerView = surface as? TerminalMetalLayerView {
            layerView.onNeedsDisplay = { [weak self] in
                // Marking dirty, not rendering: the surface asks for a frame
                // from AppKit's layout pass, and the render loop is what turns
                // that into a draw on the next tick.
                self?.frameDriver?.markDirty()
            }
        }
    }

    private func unbindSurface(_ surface: (NSView & MetalRenderTarget)?) {
        if let mtkView = surface as? MTKView {
            mtkView.delegate = nil
        } else if let layerView = surface as? TerminalMetalLayerView {
            layerView.onNeedsDisplay = nil
        }
    }

    private func makeMetalView(frame: CGRect, device: MTLDevice) -> (NSView & MetalRenderTarget) {
        if usesMetalLayerSurfaceSetting {
            let layerView = TerminalMetalLayerView(frame: frame)
            layerView.autoresizingMask = [.width, .height]
            layerView.renderDevice = device
            // Same configuration the MTKView path applies below. Every one of
            // these matters and none of them show up in a pixel comparison.
            layerView.metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layerView.metalLayer.isOpaque = backgroundOpacity >= 1.0
            layerView.renderContentsScale = metalRenderingScaleFactor()
            return layerView
        }
        let mtkView = MTKView(frame: frame, device: device)
        mtkView.autoresizingMask = [.width, .height]
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        // MTKView updates its layer geometry during AppKit layout on main.
        // The renderer must not resize the layer from its render thread.
        mtkView.autoResizeDrawable = true
        mtkView.framebufferOnly = true
        mtkView.colorPixelFormat = .bgra8Unorm
        // Tag the metal layer with sRGB so the compositor color-manages our
        // pixels the same way it color-manages the layer-backed NSView
        // (whose backing store is in the display colorspace). Without this,
        // CAMetalLayer is untagged and our raw bytes are treated as
        // already-in-display-gamut, producing oversaturated colors on
        // wide-gamut displays — most visible on selection highlights and
        // any non-default cell backgrounds. NSColor components resolved via
        // `usingColorSpace(.deviceRGB)` are sRGB-encoded on modern macOS,
        // so this is the colorspace they actually live in.
        if let metalLayer = mtkView.layer as? CAMetalLayer {
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            // Composite through the layer when the background is translucent
            metalLayer.isOpaque = backgroundOpacity >= 1.0
        }
        return mtkView
    }

    /// Inserts the Metal view into the view hierarchy with the correct
    /// z-order: below the caret (which is hidden while Metal owns the
    /// cursor), with the scroller above it. When there is no caret view
    /// and `replacing` is non-nil, the new view takes the old one's
    /// z-position instead. Actually removing the old view is the caller's
    /// responsibility — the rebind path defers removal until after the new
    /// view has drawn its first frame so the hierarchy is never empty.
    private func insertMetalView(_ newView: NSView, replacing oldView: NSView?) {
        if let caretView = caretView {
            addSubview(newView, positioned: .below, relativeTo: caretView)
            caretView.disableAnimations()
            caretView.isHidden = true
        } else if let oldView = oldView {
            addSubview(newView, positioned: .above, relativeTo: oldView)
        } else {
            addSubview(newView, positioned: .below, relativeTo: nil)
        }
        if let scroller = scroller {
            addSubview(scroller, positioned: .above, relativeTo: newView)
        }
    }

    /// Swaps in a fresh MTKView (and therefore a fresh CAMetalLayer) bound
    /// to the current window's CAContext.
    ///
    /// CAMetalLayer's WindowServer binding does not survive being reparented
    /// across NSWindow instances. After the reparent, `present(_:)` silently
    /// no-ops on the new window and the terminal stays frozen on its last
    /// frame. Apple exposes no public API to rebind an existing layer to a
    /// new context, so the only reliable fix is to recreate the MTKView.
    ///
    /// To avoid the visible CoreGraphics-fallback flash that a naive
    /// disable/enable toggle produces, the new view is built and inserted
    /// before the old one is removed, and we force a synchronous draw plus a
    /// belt-and-braces `setNeedsDisplay` so the new layer has content the
    /// moment it is in the hierarchy.
    ///
    /// On failure (renderer init throws), we fall back to CoreGraphics
    /// rendering rather than leaving a frozen Metal view in place — a
    /// degraded but responsive terminal beats a dead one.
    private func rebindMetalRendererToWindow(_ targetWindow: NSWindow) {
        // Swapping the surface out from under an in-flight frame would have the
        // render loop present into a layer that is already off screen.
        withRenderLoopSuspended {
            rebindMetalRendererToWindowLocked(targetWindow)
        }
        // Outside the suspension on purpose: stopping the loop waits on the
        // same lock, so doing it from the failure path inside would deadlock.
        if metalView == nil {
            stopRenderLoop()
        }
    }

    private func rebindMetalRendererToWindowLocked(_ targetWindow: NSWindow) {
        guard useMetalRenderer, let oldView = metalView else { return }
        // Reuse the old view's MTLDevice when possible so we don't churn
        // GPUs unnecessarily on multi-GPU or eGPU setups.
        guard let device = oldView.renderDevice ?? MTLCreateSystemDefaultDevice() else {
            disableMetalRendererAfterRebindFailure(error: MetalError.deviceUnavailable)
            return
        }

        let newView = makeMetalView(frame: oldView.frame, device: device)

        let newRenderer: MetalTerminalRenderer
        do {
            newRenderer = try MetalTerminalRenderer(view: newView, terminalView: self)
            newRenderer.requestRedraw = { [weak self] in self?.frameDriver?.markDirty() }
        } catch {
            disableMetalRendererAfterRebindFailure(error: error)
            return
        }
        bindSurface(newView, to: newRenderer)

        // Critical sequence: the new layer must have visible content before
        // the old view is removed. Force a synchronous draw, plus a
        // `setNeedsDisplay` belt-and-braces in case the synchronous draw bails
        // out (e.g. the new layer hasn't acquired its first drawable yet).
        insertMetalView(newView, replacing: oldView)
        newRenderer.render()
        newView.requestDisplay()

        unbindSurface(oldView)
        oldView.removeFromSuperview()

        metalView = newView
        metalRenderer = newRenderer
        metalBoundWindow = targetWindow
    }

    /// Tears down the Metal renderer and reverts to CoreGraphics rendering
    /// after an unrecoverable rebind failure. Keeps the terminal usable when
    /// the GPU path can't be restored.
    private func disableMetalRendererAfterRebindFailure(error: Error) {
#if canImport(os)
        os_log("SwiftTerm: Metal renderer rebind failed; falling back to CoreGraphics: %{public}@",
               type: .error, String(describing: error))
#endif
        unbindSurface(metalView)
        metalView?.removeFromSuperview()
        metalView = nil
        metalRenderer = nil
        metalBoundWindow = nil
        useMetalRenderer = false
        if let caretView = caretView {
            caretView.isHidden = false
            caretView.updateCursorStyle()
        }
        needsDisplay = true
        invalidateTerminalContents()
    }
#endif

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        frameDriver.bind(to: window == nil ? nil : self)
        startWindowMouseMovedFallback()
        updateTextBlinkLifecycle()
#if canImport(MetalKit)
        guard useMetalRenderer, let currentWindow = window else { return }
        if currentWindow !== metalBoundWindow {
            rebindMetalRendererToWindow(currentWindow)
        }
#endif
    }
    
    var becomeKeyObserver, resignKeyObserver: NSObjectProtocol?
    
    deinit {
        stopWindowMouseMovedFallback()
        if let becomeKeyObserver {
            NotificationCenter.default.removeObserver (becomeKeyObserver)
        }
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver (resignKeyObserver)
        }
        progressReportTimer?.invalidate()
        stopTextBlinking()
        frameDriver.invalidate()
#if canImport(MetalKit)
        // Waits for a frame in flight: the loop is about to lose the view it
        // renders from.
        stopRenderLoop()
#endif
    }
    
    func setupFocusNotification() {
        becomeKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { [unowned self] notification in
            self.caretView.updateCursorStyle()
            self.frameDriver.markDirty()
        }
        resignKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: nil) { [unowned self] notification in
            self.caretView.updateCursorStyle()
            self.frameDriver.markDirty()
        }
    }

    private func setupProgressBar() {
        let bar = TerminalProgressBarView(frame: .zero)
        bar.isHidden = true
        if let scroller {
            addSubview(bar, positioned: .above, relativeTo: scroller)
        } else {
            addSubview(bar)
        }
        progressBarView = bar
        updateProgressBarFrame()
    }

    private func updateProgressBarFrame() {
        guard let progressBarView else { return }
        let height: CGFloat = 2
        progressBarView.frame = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
    }

    private func resolveProgress(for report: Terminal.ProgressReport) -> UInt8? {
        switch report.state {
        case .remove:
            return nil
        case .set:
            return report.progress ?? 0
        case .error:
            return report.progress ?? lastProgressValue
        case .indeterminate:
            return nil
        case .pause:
            return report.progress ?? lastProgressValue ?? 100
        }
    }

    private func resetProgressReportTimer() {
        progressReportTimer?.invalidate()
        progressReportTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            self?.clearProgressReport()
        }
    }

    private func clearProgressReport() {
        progressReportTimer?.invalidate()
        progressReportTimer = nil
        lastProgressValue = nil
        progressBarView?.apply(state: .remove, progress: nil)
    }

    private func handleProgressReport(_ report: Terminal.ProgressReport) {
        if report.state == .remove {
            clearProgressReport()
            return
        }

        let resolvedProgress = resolveProgress(for: report)
        if let resolvedProgress {
            lastProgressValue = resolvedProgress
        }
        progressBarView?.apply(state: report.state, progress: resolvedProgress)
        resetProgressReportTimer()
    }
    
    func setupOptions ()
    {
        setupOptions (width: getEffectiveWidth (size: bounds.size), height: bounds.height)
        layer?.backgroundColor = nativeBackgroundColor.cgColor
    }

    /// This controls whether the backspace should send ^? or ^H, the default is ^?
    public var backspaceSendsControlH: Bool = false
    
    var _nativeFg, _nativeBg: TTColor!
    var settingFg = false, settingBg = false
    func setNativeForegroundColorLocked (_ newValue: NSColor)
    {
        terminal.terminalLock.preconditionLocked()
        if settingFg { return }
        settingFg = true
        _nativeFg = newValue
        terminal.foregroundColor = newValue.getTerminalColor()
        refreshCachedViewState()
        settingFg = false
    }

    func setNativeBackgroundColorLocked (_ newValue: NSColor)
    {
        terminal.terminalLock.preconditionLocked()
        if settingBg { return }
        settingBg = true
        _nativeBg = newValue
        terminal.backgroundColor = newValue.getTerminalColor()
        layer?.backgroundColor = metalView == nil
            ? effectiveNativeBackgroundColor.cgColor : NSColor.clear.cgColor
        refreshCachedViewState()
        settingBg = false
    }

    func setNativeForegroundColorFromTerminal (_ newValue: NSColor)
    {
        if settingFg { return }
        settingFg = true
        _nativeFg = newValue
        refreshCachedViewState()
        settingFg = false
    }

    func setNativeBackgroundColorFromTerminal (_ newValue: NSColor)
    {
        if settingBg { return }
        settingBg = true
        _nativeBg = newValue
        refreshCachedViewState()
        settingBg = false
    }

    /**
     * This will set the native foreground color to the specified native color (UIColor or NSColor)
     * and will have this reflected into the underlying's terminal `foregroundColor` and
     * `backgroundColor`
     */
    public var nativeForegroundColor: NSColor {
        get { _nativeFg }
        set {
            guard terminal != nil else {
                setNativeForegroundColorFromTerminal(newValue)
                return
            }
            withTerminal { _ in
                setNativeForegroundColorLocked(newValue)
            }
        }
    }

    /**
     * This will set the native foreground color to the specified native color (UIColor or NSColor)
     * and will have this reflected into the underlying's terminal `foregroundColor` and
     * `backgroundColor`
     */
    public var nativeBackgroundColor: NSColor {
        get { _nativeBg }
        set {
            guard terminal != nil else {
                setNativeBackgroundColorFromTerminal(newValue)
                return
            }
            withTerminal { _ in
                setNativeBackgroundColorLocked(newValue)
            }
        }
    }
    
    /**
     * Opacity of the terminal's default background, in the 0...1 range (values are clamped).
     *
     * Values below 1 render the default background translucently, in the style of
     * Terminal.app's background opacity: only the default background is affected;
     * text, the caret, selections and cells with explicit background colors stay
     * fully opaque. The opacity is carried in the alpha channel of
     * `nativeBackgroundColor`, so assigning that property with an alpha-bearing
     * color is equivalent.
     *
     * For the translucency to be visible, the hosting window must be configured
     * to composite it: `window.isOpaque = false` and a clear
     * `window.backgroundColor`.
     */
    public var backgroundOpacity: CGFloat {
        get {
            return _nativeBg.cgColor.alpha
        }
        set {
            let clamped = max (0.0, min (1.0, newValue))
            nativeBackgroundColor = _nativeBg.withAlphaComponent (clamped)
            // CAMetalLayer defaults to opaque; it must composite when translucent
            metalView?.layer?.isOpaque = clamped >= 1.0
            colorsChanged ()
        }
    }

    /// Controls weather to use high ansi colors, if false terminal will use bold text instead of high ansi colors
    public var useBrightColors: Bool = true

    /// Controls whether this view applies the terminal's BiDi presentation state.
    public var bidiHostPolicy: BidiHostPolicy = .respectTerminal {
        didSet {
            withTerminal { $0.updateFullScreen() }
            frameDriver.markDirty()
            updateCursorPosition()
        }
    }

    /// When true, block element (U+2580-U+259F) and box drawing (U+2500-U+257F) characters use custom rendering.
    public var customBlockGlyphs: Bool = true {
        didSet {
            withTerminal { $0.updateFullScreen() }
            frameDriver.markDirty()
        }
    }

    /// When true, custom block/box glyphs use anti-aliasing instead of pixel-aligned edges.
    public var antiAliasCustomBlockGlyphs: Bool = false {
        didSet {
            withTerminal { $0.updateFullScreen() }
            frameDriver.markDirty()
        }
    }
    
    /// Controls the color for the caret
    public var caretColor: NSColor {
        get { caretView.caretColor }
        set {
            cursorColorIsDefault = false
            caretView.caretColor = newValue
        }
    }

    /// Controls the color for the text in the caret when using a block cursor, if not set
    /// the cursor will render with the foreground color
    public var caretTextColor: NSColor? {
        get { caretView.caretTextColor }
        set {
            cursorTextColorIsDefault = newValue == nil
            caretView.caretTextColor = newValue
        }
    }

    var _selectedTextBackgroundColor = NSColor(srgbRed: 0, green: 166.0 / 255.0, blue: 178.0 / 255.0, alpha: 1.0)
    /// The background color used to render the selection.
    public var selectedTextBackgroundColor: NSColor {
        get {
            return _selectedTextBackgroundColor
        }
        set {
            _selectedTextBackgroundColor = newValue
            withTerminal { $0.updateFullScreen() }
            frameDriver.markDirty()
        }
    }

    var _selectedTextForegroundColor = NSColor.black
    /// The foreground color used to render selected text.
    public var selectedTextForegroundColor: NSColor {
        get {
            return _selectedTextForegroundColor
        }
        set {
            _selectedTextForegroundColor = newValue
            withTerminal { $0.updateFullScreen() }
            frameDriver.markDirty()
        }
    }

    func backingScaleFactor () -> CGFloat
    {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }
    
    @objc
    func scrollerActivated ()
    {
        switch scroller.hitPart {
        case .decrementPage:
            pageUp()
            scroller.doubleValue =  scrollPosition
        case .incrementPage:
            pageDown()
            scroller.doubleValue =  scrollPosition
        case .knob:
            scroll(toPosition: scroller.doubleValue)
        case .knobSlot:
            print ("Scroller .knobSlot clicked")
        case .noPart:
            print ("Scroller .noPart clicked")
        case .decrementLine:
            print ("Scroller .decrementLine clicked")
        case .incrementLine:
            print ("Scroller .incrementLine clicked")
        default:
            print ("Scroller: New value introduced")
        }
    }

    /// Style for the terminal's scroll indicator. Defaults to `.overlay` which auto-hides.
    /// Set to `.legacy` for an always-visible scrollbar.
    public var scrollerStyle: NSScroller.Style = .overlay {
        didSet {
            scroller?.scrollerStyle = scrollerStyle
            if let scroller {
                let width = NSScroller.scrollerWidth(for: .regular, scrollerStyle: scrollerStyle)
                scroller.constraints.first(where: { $0.firstAttribute == .width })?.constant = width
            }
        }
    }

    func getScrollerFrame() -> CGRect {
        let width = reservedScrollerWidth
        return NSRect(x: bounds.maxX - width, y: 0, width: width, height: bounds.height)
    }

    func setupScroller()
    {
        if scroller == nil {
            scroller = NSScroller(frame: .zero)
            scroller.translatesAutoresizingMaskIntoConstraints = false
            addSubview(scroller)

            // Use Auto Layout to position the scroller. This ensures correct layout
            // whether the parent view uses frame-based or constraint-based layout.
            NSLayoutConstraint.activate([
                scroller.trailingAnchor.constraint(equalTo: trailingAnchor),
                scroller.topAnchor.constraint(equalTo: topAnchor),
                scroller.bottomAnchor.constraint(equalTo: bottomAnchor),
                scroller.widthAnchor.constraint(equalToConstant: scrollerWidth)
            ])
        }
        scroller.scrollerStyle = scrollerStyle
        scroller.knobProportion = 0.1
        scroller.isEnabled = false
        if let progressBarView {
            addSubview(progressBarView, positioned: .above, relativeTo: scroller)
        }
        scroller.action = #selector(scrollerActivated)
        scroller.target = self
    }

    func updateScrollerFrame() {
        // Scroller position is managed by Auto Layout constraints
    }

    /// This method sents the `nativeForegroundColor` and `nativeBackgroundColor`
    /// to match macOS default colors for text and its background.
    public func configureNativeColors ()
    {
        self.nativeForegroundColor = NSColor.textColor
        self.nativeBackgroundColor = NSColor.textBackgroundColor
    }
    
    open func bufferActivated(source: Terminal) {
        eventQueue.post(.bufferActivated)
    }
    
    open func send(source: Terminal, data: ArraySlice<UInt8>) {
        terminalDelegate?.send (source: self, data: data)
    }
        
    private var scrollerWidth: CGFloat {
        NSScroller.scrollerWidth(for: .regular, scrollerStyle: scrollerStyle)
    }

    private var reservedScrollerWidth: CGFloat {
        scroller?.isHidden == true ? 0 : scrollerWidth
    }

    /**
     * Given the current set of columns and rows returns a frame that would host this control.
     *
     * Typically called from ``TerminalViewDelegate/sizeChanged(source:newCols:newRows:)``
     * to snap a window to whole cells. If you do that, set the frame without
     * animating it and compare before setting — see that method's notes and
     * <doc:Embedding>; animating the snap is a measurable performance problem
     * rather than a cosmetic choice.
     */
    open func getOptimalFrameSize () -> NSRect
    {
        let size = withTerminal { terminal in
            (cols: terminal.cols, rows: terminal.rows)
        }
        return NSRect (x: 0, y: 0, width: cellDimension.width * CGFloat(size.cols) + reservedScrollerWidth, height: cellDimension.height * CGFloat(size.rows))
    }

    func getEffectiveWidth (size: CGSize) -> CGFloat
    {
        max(0, size.width - reservedScrollerWidth)
    }
    
    open func scrolled(source terminal: Terminal, yDisp: Int) {
        markScrolledDirty()
        frameDriver.markDirty()
    }
    
    /// TerminalView handles selection once before each managed feed, so it does
    /// not call this method for each parsed line feed.
    ///
    /// Use `notifyUpdateChanges` and
    /// `TerminalViewDelegate.rangeChanged(source:startY:endY:)` for display
    /// updates. Use a separate `Terminal(delegate:)` when you need each parser
    /// line-feed event.
    @available(*, deprecated, message: "Use notifyUpdateChanges and TerminalViewDelegate.rangeChanged(source:startY:endY:) for display updates, or use a separate Terminal(delegate:) for each line-feed event.")
    open func linefeed(source: Terminal) {
        // Preserve manual selection while output is streaming when mouse reporting is disabled.
        guard allowMouseReporting && selection.active else { return }
        selection.selectNone()
    }
    
    /// This vaiable controls whether mouse events are sent to the application running under the
    /// terminal if it has requested the data.   This poses a problem for selection, so users
    /// need a way of toggling this behavior.
    public var allowMouseReporting: Bool = true

    /// Controls how link tracking resolves hovered links:
    /// `.explicit` = OSC 8 only, `.implicit` = explicit + implicit fallback, `.none` = off.
    public var linkReporting: LinkReporting = .implicit

    /// Controls link highlighting and link activation behavior.
    public var linkHighlightMode: LinkHighlightMode = .hoverWithModifier {
        didSet {
            linkHighlightRange = nil
            updateLinkHighlightTracking()
            withTerminal { $0.updateFullScreen() }
            frameDriver.markDirty()
        }
    }

    var linkHighlightRange: [Terminal.LinkMatch.RowRange]?

    /**
     * If set to true, this will call the TerminalViewDelegate's rangeChanged method
     * when there are changes that are being performed on the UI
     */
    public var notifyUpdateChanges = false

    func updateDebugDisplay()
    {
        debug?.update()
    }
    
    /// Requests a scroller refresh. The work happens once per frame, inside
    /// the lock `frameTick` already holds.
    ///
    /// This used to take the terminal lock itself, and it is called from many
    /// paths — buffer switches, scrollback changes, every frame. Measured on a
    /// binary flood: 2 216 acquisitions for 633 frames, each waiting a full
    /// ~3 ms parse batch. Marking a flag costs nothing and the scroller is a
    /// once-per-frame visual anyway.
    func updateScroller () {
        // May be queued from a callback fired during Terminal.init, before
        // the constructing thread finished assigning `terminal`.
        guard terminal != nil else { return }
        viewStateLock.lock()
        scrollerNeedsUpdate = true
        viewStateLock.unlock()
        frameDriver?.markDirty()
    }

    /// The three values a scroller refresh needs, read under the terminal lock
    /// and applied on the main thread.
    ///
    /// Applying them where they are read would put an AppKit mutation inside
    /// the frame preparation, which from WO-F4 on runs on a render thread
    /// (io-gaps.md G1).
    struct ScrollerState {
        var isEnabled: Bool
        var doubleValue: Double
        var knobProportion: CGFloat
    }

    /// Takes a pending scroller refresh. Caller must hold the terminal lock.
    func consumeScrollerStateLocked () -> ScrollerState? {
        terminal.terminalLock.preconditionLocked()
        viewStateLock.lock()
        let needed = scrollerNeedsUpdate
        scrollerNeedsUpdate = false
        viewStateLock.unlock()
        guard needed else { return nil }
        return ScrollerState(isEnabled: canScrollLocked(),
                             doubleValue: scrollPositionLocked(),
                             knobProportion: scrollThumbsizeLocked())
    }

    /// Applies a scroller refresh. Main thread only.
    func applyScrollerState (_ state: ScrollerState) {
        scroller.isEnabled = state.isEnabled
        scroller.doubleValue = state.doubleValue
        scroller.knobProportion = state.knobProportion
    }
    
    var userScrolling = false

    override open func viewWillDraw() {
        
        // Starting with BigSur, it looks like even sending one pixel to be redrawn will trigger
        // a call to draw() for the whole surface
        if disableFullRedrawOnAnyChanges {
            let layer = self.layer
            layer?.contentsFormat = .RGBA8Uint
        }
    }
    #if false
    override open func setNeedsDisplay(_ invalidRect: NSRect) {
        print ("setNeeds: \(invalidRect)")
        super.setNeedsDisplay(invalidRect)
    }
    #endif
    
    func getCurrentGraphicsContext () -> CGContext?
    {
        NSGraphicsContext.current?.cgContext
    }
    
    override public func draw (_ dirtyRect: NSRect) {
#if canImport(MetalKit)
        if metalView != nil {
            return
        }
#endif
        guard let currentContext = getCurrentGraphicsContext() else {
            return
        }
        drawTerminalContents (dirtyRect: dirtyRect, context: currentContext, bufferOffset: 0)
        TerminalView.onFramePresented?()
    }
    
    public override func cursorUpdate(with event: NSEvent)
    {
        NSCursor.iBeam.set ()
    }
    
    func makeFirstResponder ()
    {
        window?.makeFirstResponder (self)
    }

    open override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateScrollerFrame()
        updateProgressBarFrame()
        guard cellDimension != nil else { return }
        // Coalesce only while the user is dragging the window, which is the
        // case G5b is about. Outside a live resize the change stays
        // synchronous, and that is not conservatism — see the note on
        // `queueSizeChange`, where deferring broke a host's re-entrancy guard
        // and made stalls ten times worse.
        if inLiveResize {
            queueSizeChange(newSize: frame.size)
        } else {
            _ = processSizeChange(newSize: frame.size)
        }
#if canImport(MetalKit)
        if useMetalRenderer {
            if inLiveResize && TerminalView.metalLiveResizeThrottleEnabled {
                frameDriver.markDirty()
            } else {
                frameDriver.markDirty()
            }
        } else {
            needsDisplay = true
            invalidateTerminalContents()
        }
#else
        needsDisplay = true
        invalidateTerminalContents()
#endif
        updateCursorPosition()
    }

    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        updateScroller()
        withTerminal { _ in
            selection.active = false
        }
        updateProgressBarFrame()
    }
    
    private var _hasFocus = false
    open var hasFocus : Bool {
        get {
            //print ("hasFocus: \(_hasFocus) window=\(window?.isKeyWindow)")
            return _hasFocus && (window?.isKeyWindow ?? true)
        }
        set {
            _hasFocus = newValue
            caretView.focused = newValue
#if canImport(MetalKit)
            frameDriver.markDirty()
#endif
        }
    }

    //
    // NSTextInputClient protocol implementation
    //
    public override func becomeFirstResponder() -> Bool {
        let response = super.becomeFirstResponder()
        if response {
            hasFocus = true
            caretView.updateCursorStyle()
            withTerminal { $0.setTerminalFocus(true) }
        }
        return response
    }
    
    public override func resignFirstResponder() -> Bool {
        let response = super.resignFirstResponder()
        if response {
            caretView.disableAnimations()
            hasFocus = false
            withTerminal { $0.setTerminalFocus(false) }
        }
        return response
    }
    
    public override var acceptsFirstResponder: Bool {
        get {
            return true
        }
    }
    
    // Tracking object, maintained by `startTracking` and `deregisterTrackingInterest`
    var tracking: NSTrackingArea? = nil

    // macOS 26 can synthesize left-mouse-down events while a tracking area asks
    // for `.mouseMoved`.  Keep using the area for enter/exit notifications, and
    // receive movement through a shared per-window monitor instead (see
    // `MouseMovedFallbackWindowState`).  We remember the window we registered
    // with so we can unregister; the identifier is stored separately as a value
    // so cleanup still works if the window has already been deallocated.
    private weak var mouseMovedFallbackWindow: NSWindow?
    private var mouseMovedFallbackWindowIdentifier: ObjectIdentifier?
    
    // Turns on AppKit mouse event tracking - used both by the url highlighter and the mouse move,
    // when the client application has set MouseMove.anyEvent
    //
    // Can be invoked multiple times, use the "deregisterTrackingInterest" method to turn it off
    // which will take into account both the url highlighter state (which is bound to the command
    // key being pressed) and the client requirements
    func startTracking ()
    {
        if tracking == nil {
            var options: NSTrackingArea.Options = [.activeAlways, .mouseEnteredAndExited]
            if #available(macOS 26, *) {
                // See the Tahoe WindowServer workaround above.
            } else {
                options.insert(.mouseMoved)
            }
            tracking = NSTrackingArea (rect: frame, options: options, owner: self, userInfo: [:])
            addTrackingArea(tracking!)
        }
        startWindowMouseMovedFallback()
    }

    private func startWindowMouseMovedFallback() {
        guard #available(macOS 26, *) else { return }
        guard tracking != nil, let window else {
            stopWindowMouseMovedFallback()
            return
        }

        guard mouseMovedFallbackWindow !== window else { return }
        stopWindowMouseMovedFallback()
        mouseMovedFallbackWindow = window
        mouseMovedFallbackWindowIdentifier = ObjectIdentifier(window)
        TerminalView.beginWindowMouseMovedFallback(view: self, window: window)
    }

    private func stopWindowMouseMovedFallback() {
        guard #available(macOS 26, *) else { return }

        if let identifier = mouseMovedFallbackWindowIdentifier {
            TerminalView.endWindowMouseMovedFallback(view: self, identifier: identifier, window: mouseMovedFallbackWindow)
        }
        mouseMovedFallbackWindow = nil
        mouseMovedFallbackWindowIdentifier = nil
    }

    // Invoked by the shared per-window monitor for every terminal view in the window.
    fileprivate func handleWindowMouseMoved(_ event: NSEvent) {
        guard shouldHandleWindowMouseMoved(event) else { return }
        // The first responder already receives `mouseMoved` through AppKit's normal
        // dispatch (because `acceptsMouseMovedEvents` is on), so only synthesize
        // delivery for a hovered view that is *not* the first responder; otherwise we
        // would report the same move twice.
        if window?.firstResponder === self { return }
        mouseMoved(with: event)
    }

    private func shouldHandleWindowMouseMoved(_ event: NSEvent) -> Bool {
        guard tracking != nil,
              shouldTrackMouse(),
              let window,
              event.window === window else {
            return false
        }
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point)
    }
    
    func shouldTrackMouse () -> Bool
    {
        if currentMouseMode == .anyEvent {
            return true
        }
        if commandActive {
            return true
        }
        if linkHighlightMode == .hover {
            return true
        }
        if linkHighlightMode == .hoverWithModifier && commandActive {
            return true
        }
        return false
    }

    // Can be invoked by both the keyboard handler monitoring the command key, and the
    // mouse tracking system, only when both are off, this is turned off.
    func deregisterTrackingInterest ()
    {
        if !shouldTrackMouse() {
            if tracking != nil {
                removeTrackingArea(tracking!)
                tracking = nil
            }
            stopWindowMouseMovedFallback()
        }
    }

    func updateLinkHighlightTracking ()
    {
        if shouldTrackMouse() {
            startTracking()
        } else {
            deregisterTrackingInterest()
        }
    }
    
    func turnOffUrlPreview ()
    {
        if commandActive {
            commandActive = false
            deregisterTrackingInterest()
            removePreviewUrl()
            lastReportedLink = nil
            if linkHighlightMode == .hoverWithModifier {
                let oldRange = linkHighlightRange
                linkHighlightRange = nil
                invalidateLinkHighlight(oldRange: oldRange, newRange: nil)
                frameDriver.markDirty()
            }
            if linkHighlightMode == .alwaysWithModifier {
                withTerminal { $0.updateFullScreen() }
                frameDriver.markDirty()
            }
        }
    }
    
    // If true, the Command key has been pressed
    var commandActive = false
    
    // We monitor the flags changed to enable URL previews on mouse-hover like iTerm
    // when the Command key is pressed.
    
    public override func flagsChanged(with event: NSEvent) {
        if event.modifierFlags.contains(.command){
            commandActive = true
            startTracking()

            if let hit = currentMouseHit() {
                if let payload = payloadString(at: hit) {
                    previewUrl(payload: payload)
                }
                reportLink(at: hit)
                updateHoverLink(at: hit)
            } else if let payload = getPayload(for: event) as? String {
                previewUrl (payload: payload)
            }
            if linkHighlightMode == .alwaysWithModifier {
                withTerminal { $0.updateFullScreen() }
                frameDriver.markDirty()
            }
        } else {
            turnOffUrlPreview ()
        }
        let keyboardEnhancementFlags = withTerminal { $0.keyboardEnhancementFlags }
        if keyboardEnhancementFlags.contains(.reportAllKeys),
           !kittyIsComposing,
           let modifierKey = kittyModifierKey(from: event.keyCode),
           let modifierFlag = modifierFlag(for: modifierKey) {
            let isDown = event.modifierFlags.contains(modifierFlag)
            let eventType: KittyKeyboardEventType = isDown ? .press : .release
            if eventType == .release && !keyboardEnhancementFlags.contains(.reportEvents) {
                super.flagsChanged(with: event)
                return
            }
            let modifiers = kittyModifiers(from: event, includeOption: true)
            let kittyEvent = KittyKeyEvent(key: .functional(modifierKey),
                                           modifiers: modifiers,
                                           eventType: eventType,
                                           text: nil,
                                           shiftedKey: nil,
                                           baseLayoutKey: nil,
                                           composing: kittyIsComposing)
            _ = sendKittyEvent(kittyEvent)
        }
        super.flagsChanged(with: event)
    }
    
    public override func mouseExited(with event: NSEvent) {
        turnOffUrlPreview()
        if linkHighlightMode == .hover || linkHighlightMode == .hoverWithModifier {
            let oldRange = linkHighlightRange
            linkHighlightRange = nil
            invalidateLinkHighlight(oldRange: oldRange, newRange: nil)
            frameDriver.markDirty()
        }
        super.mouseExited(with: event)
    }
    
    /// If set to true, the terminal treats the "Option" key as the Meta key in old terminals,
    /// which has the effect of sending the ESC character before the character that was
    /// entered.  Applications use this to provide bindings for Alt-keys, or in Emacs terms
    /// the Meta key (M-x stands for Meta-x, or pressing the option key and x).
    ///
    /// If this is set to `false`, then the key is passed to the OS, which produces the
    /// OS specific feature.
    public var optionAsMetaKey: Bool = true

    private struct PendingKittyKeyEvent {
        let event: NSEvent
        let eventType: KittyKeyboardEventType
    }

    private var pendingKittyKeyEvent: PendingKittyKeyEvent?
    private var kittyIsComposing = false
    
    //
    // We capture a handful of keydown events and pre-process those, and then let
    // interpretKeyEvents do the rest of the work, that includes text-insertion, and
    // keybinding mapping.
    //
    // That is why we do not handle things like the return key here, instead those are
    // handled by doCommand below.
    //
    // This currently handles the function keys here, but probably should be done in
    // doCommand/noop: - but more research needs to take place to figure out the priority
    // of those keys.
    //
    public override func keyDown(with event: NSEvent) {
        withTerminal { _ in
            selection.active = false
        }
        let eventFlags = event.modifierFlags

        let terminalState = withTerminal { terminal in
            (terminal.keyboardEnhancementFlags, terminal.applicationCursor)
        }
        let keyboardEnhancementFlags = terminalState.0

        if keyboardEnhancementFlags.isEmpty,
           eventFlags.contains(.command),
           !(eventFlags.contains(.option) && event.charactersIgnoringModifiers == "o") {
            interpretKeyEvents([event])
            return
        }

        if keyboardEnhancementFlags.isEmpty,
           !eventFlags.contains(.command),
           (!eventFlags.contains(.option) || optionAsMetaKey),
           let functionKey = kittyFunctionalKey(from: event) {
            let modifiers = kittyModifiers(from: event, includeOption: optionAsMetaKey)
            let isUnmodifiedPageKey = (functionKey == .pageUp || functionKey == .pageDown)
                && modifiers.intersection([.shift, .alt, .ctrl]).isEmpty
                && !terminalState.1
            if isUnmodifiedPageKey {
                if functionKey == .pageUp {
                    pageUp()
                } else {
                    pageDown()
                }
                return
            }
            let keyEvent = KittyKeyEvent(key: .functional(functionKey),
                                         modifiers: modifiers,
                                         eventType: event.isARepeat ? .repeatPress : .press,
                                         text: kittyTextForFunctionalKey(functionKey, event: event),
                                         shiftedKey: nil,
                                         baseLayoutKey: nil,
                                         composing: kittyIsComposing)
            if sendKittyEvent(keyEvent) {
                return
            }
        }

        if !keyboardEnhancementFlags.isEmpty {
            pendingKittyKeyEvent = nil
            if eventFlags.contains([.option, .command]), event.charactersIgnoringModifiers == "o" {
                optionAsMetaKey.toggle()
                return
            }

            let wantsEvents = keyboardEnhancementFlags.contains(.reportEvents)
            let wantsAllKeys = keyboardEnhancementFlags.contains(.reportAllKeys)
            let repeatEventType: KittyKeyboardEventType = (event.isARepeat && wantsEvents) ? .repeatPress : .press
            let textEventType: KittyKeyboardEventType = (event.isARepeat && wantsEvents && wantsAllKeys) ? .repeatPress : .press
            if let functionKey = kittyFunctionalKey(from: event) {
                let kittyEvent = KittyKeyEvent(key: .functional(functionKey),
                                               modifiers: kittyModifiers(from: event, includeOption: optionAsMetaKey),
                                               eventType: repeatEventType,
                                               text: kittyTextForFunctionalKey(functionKey, event: event),
                                               shiftedKey: nil,
                                               baseLayoutKey: nil,
                                               composing: kittyIsComposing)
                if sendKittyEvent(kittyEvent) {
                    return
                }
            }

            if eventFlags.contains(.control) || (optionAsMetaKey && eventFlags.contains(.option)) {
                if let kittyEvent = kittyTextEvent(from: event, eventType: repeatEventType),
                   sendKittyEvent(kittyEvent) {
                    return
                }
            }

            pendingKittyKeyEvent = PendingKittyKeyEvent(event: event, eventType: textEventType)
            interpretKeyEvents([event])
            return
        }
        
        // Handle Option-letter to send the ESC sequence plus the letter as expected by terminals
        if eventFlags.contains ([.option, .command]) {
            if event.charactersIgnoringModifiers == "o" {
                optionAsMetaKey.toggle()
            }
        } else if optionAsMetaKey && eventFlags.contains (.option) {
            if let rawCharacter = event.charactersIgnoringModifiers {
                if let fs = rawCharacter.unicodeScalars.first {
                    switch Int (fs.value) {
                    case NSLeftArrowFunctionKey:
                        send (EscapeSequences.emacsBack)
                        return
                    case NSRightArrowFunctionKey:
                        send (EscapeSequences.emacsForward)
                        return
                    default: break
                    }
                }
                send (EscapeSequences.cmdEsc)
                send (txt: rawCharacter)
            }
            return
        } else if eventFlags.contains (.control) {
            // Sends the control sequence
            if let ch = event.charactersIgnoringModifiers {
                if let fs = ch.unicodeScalars.first {
                    switch Int (fs.value) {
                    case NSLeftArrowFunctionKey:
                        send (EscapeSequences.controlLeft)
                        return
                    case NSRightArrowFunctionKey:
                        send (EscapeSequences.controlRight)
                        return
                    default:
                        break
                    }
                }
                send (applyControlToEventCharacters (ch))
                return
            }
        } else if eventFlags.contains (.function) {
            if let str = event.charactersIgnoringModifiers {
                if let fs = str.unicodeScalars.first {
                    let c = Int (fs.value)
                    switch c {
                    case NSF1FunctionKey:
                        send (EscapeSequences.cmdF [0])
                    case NSF2FunctionKey:
                        send (EscapeSequences.cmdF [1])
                    case NSF3FunctionKey:
                        send (EscapeSequences.cmdF [2])
                    case NSF4FunctionKey:
                        send (EscapeSequences.cmdF [3])
                    case NSF5FunctionKey:
                        send (EscapeSequences.cmdF [4])
                    case NSF6FunctionKey:
                        send (EscapeSequences.cmdF [5])
                    case NSF7FunctionKey:
                        send (EscapeSequences.cmdF [6])
                    case NSF8FunctionKey:
                        send (EscapeSequences.cmdF [7])
                    case NSF9FunctionKey:
                        send (EscapeSequences.cmdF [8])
                    case NSF10FunctionKey:
                        send (EscapeSequences.cmdF [9])
                    case NSF11FunctionKey:
                        send (EscapeSequences.cmdF [10])
                    case NSF12FunctionKey:
                        send (EscapeSequences.cmdF [11])
                    case NSDeleteFunctionKey:
                        send (EscapeSequences.cmdDelKey)
                        //                    case NSUpArrowFunctionKey:
                        //                        send (EscapeSequences.MoveUpNormal)
                        //                    case NSDownArrowFunctionKey:
                        //                        send (EscapeSequences.MoveDownNormal)
                        //                    case NSLeftArrowFunctionKey:
                        //                        send (EscapeSequences.MoveLeftNormal)
                        //                    case NSRightArrowFunctionKey:
                    //                        send (EscapeSequences.MoveRightNormal)
                    case NSPageUpFunctionKey:
                        pageUp ()
                    case NSPageDownFunctionKey:
                        pageDown()
                    default:
                        interpretKeyEvents([event])
                    }
                }
            }
            return
        }
        
        interpretKeyEvents([event])
    }

    public override func keyUp(with event: NSEvent) {
        let flags = withTerminal { $0.keyboardEnhancementFlags }
        if flags.contains(.reportEvents) {
            let hasAltOrCtrl = event.modifierFlags.contains(.control) || (optionAsMetaKey && event.modifierFlags.contains(.option))
            let shouldHandle = flags.contains(.reportAllKeys) || hasAltOrCtrl || kittyFunctionalKey(from: event) != nil
            if shouldHandle, let kittyEvent = kittyKeyEvent(from: event, eventType: .release, text: nil) {
                if !flags.contains(.reportAllKeys),
                   case .unicode(let codepoint) = kittyEvent.key,
                   codepoint == 9 || codepoint == 13 || codepoint == 127 {
                    // Enter/Tab/Backspace only report release events in report-all-keys mode.
                } else {
                    _ = sendKittyEvent(kittyEvent)
                }
            }
        }
        super.keyUp(with: event)
    }
    
    public override func doCommand(by selector: Selector) {
        if !withTerminal({ $0.keyboardEnhancementFlags }).isEmpty || !kittyIsComposing {
            let mods: KittyKeyboardModifiers
            if let pending = pendingKittyKeyEvent {
                mods = kittyModifiers(from: pending.event, includeOption: optionAsMetaKey)
            } else {
                mods = []
            }
            switch selector {
            case #selector(insertNewline(_:)):
                if sendKittyFunctionalKey(.enter, modifiers: mods) { return }
            case #selector(cancelOperation(_:)):
                if sendKittyFunctionalKey(.escape, modifiers: mods) { return }
            case #selector(deleteBackward(_:)):
                if sendKittyFunctionalKey(.backspace, modifiers: mods) { return }
            case #selector(moveUp(_:)):
                if sendKittyFunctionalKey(.up, modifiers: mods) { return }
            case #selector(moveDown(_:)):
                if sendKittyFunctionalKey(.down, modifiers: mods) { return }
            case #selector(moveLeft(_:)):
                if sendKittyFunctionalKey(.left, modifiers: mods) { return }
            case #selector(moveRight(_:)):
                if sendKittyFunctionalKey(.right, modifiers: mods) { return }
            case #selector(insertTab(_:)):
                if sendKittyFunctionalKey(.tab, modifiers: mods) { return }
            case #selector(insertBacktab(_:)):
                if sendKittyFunctionalKey(.tab, modifiers: mods.union([.shift])) { return }
            case #selector(moveToBeginningOfLine(_:)):
                if sendKittyFunctionalKey(.home, modifiers: mods) { return }
            case #selector(scrollToBeginningOfDocument(_:)):
                if sendKittyFunctionalKey(.home, modifiers: mods) { return }
            case #selector(moveToEndOfLine(_:)):
                if sendKittyFunctionalKey(.end, modifiers: mods) { return }
            case #selector(scrollToEndOfDocument(_:)):
                if sendKittyFunctionalKey(.end, modifiers: mods) { return }
            case #selector(scrollPageUp(_:)):
                fallthrough
            case #selector(pageUp(_:)):
                if withTerminal({ $0.applicationCursor }) {
                    if sendKittyFunctionalKey(.pageUp, modifiers: mods) { return }
                } else {
                    pageUp()
                    return
                }
            case #selector(scrollPageDown(_:)):
                fallthrough
            case #selector(pageDown(_:)):
                if withTerminal({ $0.applicationCursor }) {
                    if sendKittyFunctionalKey(.pageDown, modifiers: mods) { return }
                } else {
                    pageDown()
                    return
                }
            default:
                break
            }
        }
        switch selector {
        case #selector(insertNewline(_:)):
            send (EscapeSequences.cmdRet)
        case #selector(cancelOperation(_:)):
            send (EscapeSequences.cmdEsc)
        case #selector(deleteBackward(_:)):
            send ([backspaceSendsControlH ? 8 : 0x7f])
        case #selector(moveUp(_:)):
            sendKeyUp()
        case #selector(moveDown(_:)):
            sendKeyDown()
        case #selector(moveLeft(_:)):
            sendKeyLeft()
        case #selector(moveRight(_:)):
            sendKeyRight()
        case #selector(insertTab(_:)):
            send (EscapeSequences.cmdTab)
        case #selector(insertBacktab(_:)):
            send (EscapeSequences.cmdBackTab)
        case #selector(moveToBeginningOfLine(_:)):
            send (withTerminal({ $0.applicationCursor }) ? EscapeSequences.moveHomeApp : EscapeSequences.moveHomeNormal)
        case #selector(scrollToBeginningOfDocument(_:)):
            send (withTerminal({ $0.applicationCursor }) ? EscapeSequences.moveHomeApp : EscapeSequences.moveHomeNormal)
        case #selector(moveToEndOfLine(_:)):
            send (withTerminal({ $0.applicationCursor }) ? EscapeSequences.moveEndApp : EscapeSequences.moveEndNormal)
        case #selector(scrollToEndOfDocument(_:)):
            send (withTerminal({ $0.applicationCursor }) ? EscapeSequences.moveEndApp : EscapeSequences.moveEndNormal)
        case #selector(scrollPageUp(_:)):
            fallthrough
        case #selector(pageUp(_:)):
            if withTerminal({ $0.applicationCursor }) {
                send (EscapeSequences.cmdPageUp)
            } else {
                pageUp()
            }
        case #selector(scrollPageDown(_:)):
            fallthrough
        case #selector(pageDown(_:)):
            if withTerminal({ $0.applicationCursor }) {
                send (EscapeSequences.cmdPageDown)
            } else {
                pageDown()
            }
        case #selector(pageDownAndModifySelection(_:)):
            if withTerminal({ $0.applicationCursor }) {
                // TODO: view should scroll one page up.
            } else {
                send (EscapeSequences.cmdPageDown)
            }
        case #selector(moveToLeftEndOfLine(_:)):
            // Apple sends the Emacs back-word commands
            send (EscapeSequences.emacsBack)
        case #selector(moveToRightEndOfLine(_:)):
            send (EscapeSequences.emacsForward)
        default:
            print ("Unhandle selector \(selector)")
        }
    }
    
    // NSTextInputClient protocol implementation
    open func insertText(_ string: Any, replacementRange: NSRange) {
        insertText(string, replacementRange: replacementRange, isPaste: false)
    }
    
    func insertText(_ string: Any, replacementRange: NSRange, isPaste: Bool) {
        markedTextStorage = nil
        markedSelectedRange = NSRange(location: NSNotFound, length: 0)
        updateMarkedTextOverlay()
        if let str = string as? NSString {
            let terminalState = withTerminal { terminal in
                (keyboardFlags: terminal.keyboardEnhancementFlags, bracketedPasteMode: terminal.bracketedPasteMode)
            }
            if !terminalState.keyboardFlags.isEmpty {
                if isPaste, terminalState.bracketedPasteMode {
                    pendingKittyKeyEvent = nil
                    send(data: EscapeSequences.bracketedPasteStart[0...])
                    send (txt: str as String)
                    send(data: EscapeSequences.bracketedPasteEnd[0...])
                    return
                }
                let pendingEvent = pendingKittyKeyEvent
                pendingKittyKeyEvent = nil
                kittyIsComposing = false
                let text = str as String

                // Option acting as a compose/AltGr layer (e.g. on the Czech
                // layout Option+2 produces "@" while the bare key is "ě"). When
                // optionAsMetaKey is off, Option is not Meta, so the keypress
                // simply produced a normal character. Encoding it as a kitty
                // CSI-u event keys off charactersIgnoringModifiers (the
                // base-layout glyph, "ě") and only carries the composed "@" as
                // associated text, so apps that negotiate reportAlternates or
                // reportAllKeys without reportText (e.g. OpenCode) receive the
                // base key and the composed glyph is lost. Send the composed
                // text directly instead, matching how kitty/Ghostty handle
                // AltGr layers.
                if let pendingEvent,
                   !optionAsMetaKey,
                   pendingEvent.event.modifierFlags.contains(.option),
                   !pendingEvent.event.modifierFlags.contains(.control),
                   !pendingEvent.event.modifierFlags.contains(.command),
                   isPlainPrintableText(text) {
                    send(txt: text)
                    return
                }

                let kittyEvent: KittyKeyEvent
                if text.unicodeScalars.count == 1,
                   let pendingEvent,
                   let event = kittyTextEvent(from: pendingEvent.event, eventType: pendingEvent.eventType, text: text) {
                    kittyEvent = event
                } else {
                    kittyEvent = kittyTextEventFromText(text)
                }
                _ = sendKittyEvent(kittyEvent)
                return
            }
            if isPaste, withTerminal({ $0.bracketedPasteMode }) {
                send(data: EscapeSequences.bracketedPasteStart[0...])
            }
            send (txt: str as String)
            if isPaste, withTerminal({ $0.bracketedPasteMode }) {
                send(data: EscapeSequences.bracketedPasteEnd[0...])
            }
        }
        // TODO: I do not think we actually need this needsDisplay, the data fed should bubble this up
        // needsDisplay = true
    }
    
    /// Whether `text` is a non-empty run of printable scalars (no C0/C1 control
    /// characters). Used to decide when Option-composed input can be sent as
    /// literal UTF-8 rather than encoded as a kitty key event.
    private func isPlainPrintableText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || (scalar.value >= 0x7f && scalar.value <= 0x9f) {
                return false
            }
        }
        return true
    }

    // NSTextInputClient protocol implementation
    open func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let attributed as NSAttributedString:
            markedTextStorage = attributed.length > 0 ? attributed : nil
        case let plain as String:
            markedTextStorage = plain.isEmpty ? nil : NSAttributedString(string: plain)
        default:
            markedTextStorage = nil
        }
        markedSelectedRange = selectedRange
        kittyIsComposing = true
        updateMarkedTextOverlay()
    }

    /// Shows or hides a floating overlay that previews in-progress marked text
    /// (e.g. dictation hypotheses or IME composition) at the current cursor position.
    private func updateMarkedTextOverlay() {
        guard let markedTextStorage, markedTextStorage.length > 0 else {
            markedTextOverlay?.removeFromSuperview()
            markedTextOverlay = nil
            return
        }

        let overlay: DictationOverlayTextView
        if let existing = markedTextOverlay {
            overlay = existing
        } else {
            let tv = DictationOverlayTextView(frame: .zero)
            tv.isEditable = false
            tv.isSelectable = false
            tv.isRichText = true
            tv.textContainerInset = .zero
            tv.textContainer?.lineFragmentPadding = 0
            // Our subclass fills the background per-line-fragment instead of
            // over the whole frame, so turn off NSTextView's built-in fill.
            tv.drawsBackground = false
            addSubview(tv, positioned: .above, relativeTo: nil)
            markedTextOverlay = tv
            overlay = tv
        }

        // Match the terminal's effective background so the overlay blends in
        // with whatever the rest of the view is rendering. `nativeBackgroundColor`
        // is typically `NSColor.windowBackgroundColor` (dynamic: adapts to
        // light/dark) when the host has called `configureNativeColors()`.
        overlay.overlayBackgroundColor = effectiveNativeBackgroundColor

        // Match terminal line metrics so wrapped lines line up with terminal rows.
        let lineHeight = cellDimension.height
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = lineHeight
        para.maximumLineHeight = lineHeight
        para.lineBreakMode = .byWordWrapping

        // Match the terminal's effective foreground color. This preserves
        // host-selected themes and terminal foreground-color changes.
        //
        // The terminal pixel-snaps each cell's width, so the effective per-cell
        // advance is slightly wider than the font's natural advance. Apply a
        // matching `.kern` so overlay characters line up with the terminal grid.
        let glyphW = font.glyph(withName: "W")
        let naturalAdvance = font.advancement(forGlyph: glyphW).width
        let kern = max(0, cellDimension.width - naturalAdvance)

        let display = NSMutableAttributedString(attributedString: markedTextStorage)
        let fullRange = NSRange(location: 0, length: display.length)
        display.addAttributes([
            .font: font,
            .foregroundColor: effectiveNativeForegroundColor,
            .paragraphStyle: para,
            .kern: kern,
        ], range: fullRange)
        overlay.textStorage?.setAttributedString(display)

        // The overlay spans the full content width. Line 1 skips the portion
        // already occupied by text to the left of the caret (e.g. the prompt)
        // via an exclusion path; wrapped lines 2+ start from the left edge.
        let horizontalInset: CGFloat = 4
        let rightInset: CGFloat = 4
        let overlayX = horizontalInset
        let overlayWidth = max(cellDimension.width, bounds.width - horizontalInset - rightInset)
        let caretX = max(horizontalInset, caretView.frame.origin.x)
        let exclusionWidth = max(0, caretX - overlayX)

        if let container = overlay.textContainer {
            container.containerSize = NSSize(width: overlayWidth, height: .greatestFiniteMagnitude)
            container.exclusionPaths = exclusionWidth > 0
                ? [NSBezierPath(rect: NSRect(x: 0, y: 0, width: exclusionWidth, height: lineHeight + 1))]
                : []
        }

        // Size the text view so its frame exactly wraps the wrapped line fragments.
        overlay.layoutManager?.ensureLayout(for: overlay.textContainer!)
        let overlayHeight = overlay.layoutManager?.usedRect(for: overlay.textContainer!).height ?? lineHeight

        overlay.frame = NSRect(
            x: overlayX,
            y: caretView.frame.maxY - overlayHeight,
            width: overlayWidth,
            height: overlayHeight
        )
    }

    private func kittyEncoder() -> KittyKeyboardEncoder {
        let terminalState = withTerminal { terminal in
            (terminal.keyboardEnhancementFlags, terminal.applicationCursor, terminal.applicationKeypad)
        }
        return KittyKeyboardEncoder(flags: terminalState.0,
                                    applicationCursor: terminalState.1,
                                    applicationKeypad: terminalState.2,
                                    backspaceSendsControlH: backspaceSendsControlH)
    }

    private func kittyModifiers(from event: NSEvent, includeOption: Bool) -> KittyKeyboardModifiers {
        var modifiers: KittyKeyboardModifiers = []
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.ctrl) }
        if includeOption, event.modifierFlags.contains(.option) { modifiers.insert(.alt) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.super) }
        if event.modifierFlags.contains(.capsLock) { modifiers.insert(.capsLock) }
        return modifiers
    }

    private func kittyFunctionalKey(from event: NSEvent) -> KittyFunctionalKey? {
        switch Int(event.keyCode) {
        case kVK_ANSI_Keypad0:
            return .keypad0
        case kVK_ANSI_Keypad1:
            return .keypad1
        case kVK_ANSI_Keypad2:
            return .keypad2
        case kVK_ANSI_Keypad3:
            return .keypad3
        case kVK_ANSI_Keypad4:
            return .keypad4
        case kVK_ANSI_Keypad5:
            return .keypad5
        case kVK_ANSI_Keypad6:
            return .keypad6
        case kVK_ANSI_Keypad7:
            return .keypad7
        case kVK_ANSI_Keypad8:
            return .keypad8
        case kVK_ANSI_Keypad9:
            return .keypad9
        case kVK_ANSI_KeypadDecimal:
            return .keypadDecimal
        case kVK_ANSI_KeypadDivide:
            return .keypadDivide
        case kVK_ANSI_KeypadMultiply:
            return .keypadMultiply
        case kVK_ANSI_KeypadMinus:
            return .keypadSubtract
        case kVK_ANSI_KeypadPlus:
            return .keypadAdd
        case kVK_ANSI_KeypadEnter:
            return .keypadEnter
        case kVK_ANSI_KeypadEquals:
            return .keypadEqual
        case kVK_ANSI_KeypadClear:
            return .keypadBegin
        default:
            break
        }
        guard let chars = event.charactersIgnoringModifiers,
              let scalar = chars.unicodeScalars.first else {
            return nil
        }
        if event.modifierFlags.contains(.numericPad),
           !Self.regularArrowKeyCodes.contains(event.keyCode) {
            switch Int(scalar.value) {
            case NSUpArrowFunctionKey:
                return .keypadUp
            case NSDownArrowFunctionKey:
                return .keypadDown
            case NSLeftArrowFunctionKey:
                return .keypadLeft
            case NSRightArrowFunctionKey:
                return .keypadRight
            case NSHomeFunctionKey:
                return .keypadHome
            case NSEndFunctionKey:
                return .keypadEnd
            case NSPageUpFunctionKey:
                return .keypadPageUp
            case NSPageDownFunctionKey:
                return .keypadPageDown
            case NSInsertFunctionKey:
                return .keypadInsert
            case NSDeleteFunctionKey:
                return .keypadDelete
            default:
                break
            }
        }
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey:
            return .up
        case NSDownArrowFunctionKey:
            return .down
        case NSLeftArrowFunctionKey:
            return .left
        case NSRightArrowFunctionKey:
            return .right
        case NSHomeFunctionKey:
            return .home
        case NSEndFunctionKey:
            return .end
        case NSPageUpFunctionKey:
            return .pageUp
        case NSPageDownFunctionKey:
            return .pageDown
        case NSInsertFunctionKey:
            return .insert
        case NSDeleteFunctionKey:
            return .delete
        case NSPrintScreenFunctionKey:
            return .printScreen
        case NSScrollLockFunctionKey:
            return .scrollLock
        case NSPauseFunctionKey:
            return .pause
        case NSMenuFunctionKey:
            return .menu
        case NSF1FunctionKey:
            return .f1
        case NSF2FunctionKey:
            return .f2
        case NSF3FunctionKey:
            return .f3
        case NSF4FunctionKey:
            return .f4
        case NSF5FunctionKey:
            return .f5
        case NSF6FunctionKey:
            return .f6
        case NSF7FunctionKey:
            return .f7
        case NSF8FunctionKey:
            return .f8
        case NSF9FunctionKey:
            return .f9
        case NSF10FunctionKey:
            return .f10
        case NSF11FunctionKey:
            return .f11
        case NSF12FunctionKey:
            return .f12
        case NSF13FunctionKey:
            return .f13
        case NSF14FunctionKey:
            return .f14
        case NSF15FunctionKey:
            return .f15
        case NSF16FunctionKey:
            return .f16
        case NSF17FunctionKey:
            return .f17
        case NSF18FunctionKey:
            return .f18
        case NSF19FunctionKey:
            return .f19
        case NSF20FunctionKey:
            return .f20
        case NSF21FunctionKey:
            return .f21
        case NSF22FunctionKey:
            return .f22
        case NSF23FunctionKey:
            return .f23
        case NSF24FunctionKey:
            return .f24
        case NSF25FunctionKey:
            return .f25
        case NSF26FunctionKey:
            return .f26
        case NSF27FunctionKey:
            return .f27
        case NSF28FunctionKey:
            return .f28
        case NSF29FunctionKey:
            return .f29
        case NSF30FunctionKey:
            return .f30
        case NSF31FunctionKey:
            return .f31
        case NSF32FunctionKey:
            return .f32
        case NSF33FunctionKey:
            return .f33
        case NSF34FunctionKey:
            return .f34
        case NSF35FunctionKey:
            return .f35
        default:
            return nil
        }
    }

    private func kittyTextForFunctionalKey(_ key: KittyFunctionalKey, event: NSEvent) -> String? {
        switch key {
        case .keypad0, .keypad1, .keypad2, .keypad3, .keypad4,
             .keypad5, .keypad6, .keypad7, .keypad8, .keypad9,
             .keypadDecimal, .keypadDivide, .keypadMultiply, .keypadSubtract,
             .keypadAdd, .keypadEqual, .keypadSeparator:
            let text = event.characters ?? event.charactersIgnoringModifiers
            return text?.isEmpty == false ? text : nil
        default:
            return nil
        }
    }

    private func kittyModifierKey(from keyCode: UInt16) -> KittyFunctionalKey? {
        switch keyCode {
        case 54:
            return .rightSuper
        case 55:
            return .leftSuper
        case 56:
            return .leftShift
        case 57:
            return .capsLock
        case 58:
            return .leftAlt
        case 59:
            return .leftControl
        case 60:
            return .rightShift
        case 61:
            return .rightAlt
        case 62:
            return .rightControl
        default:
            return nil
        }
    }

    private func modifierFlag(for key: KittyFunctionalKey) -> NSEvent.ModifierFlags? {
        switch key {
        case .leftShift, .rightShift:
            return .shift
        case .leftControl, .rightControl:
            return .control
        case .leftAlt, .rightAlt:
            return .option
        case .leftSuper, .rightSuper:
            return .command
        case .capsLock:
            return .capsLock
        default:
            return nil
        }
    }

    private static let kittyBaseLayoutKeyMap: [UInt16: UnicodeScalar] = {
        func scalar(_ char: Character) -> UnicodeScalar {
            char.unicodeScalars.first!
        }
        return [
            0: scalar("a"),
            1: scalar("s"),
            2: scalar("d"),
            3: scalar("f"),
            4: scalar("h"),
            5: scalar("g"),
            6: scalar("z"),
            7: scalar("x"),
            8: scalar("c"),
            9: scalar("v"),
            11: scalar("b"),
            12: scalar("q"),
            13: scalar("w"),
            14: scalar("e"),
            15: scalar("r"),
            16: scalar("y"),
            17: scalar("t"),
            18: scalar("1"),
            19: scalar("2"),
            20: scalar("3"),
            21: scalar("4"),
            22: scalar("6"),
            23: scalar("5"),
            24: scalar("="),
            25: scalar("9"),
            26: scalar("7"),
            27: scalar("-"),
            28: scalar("8"),
            29: scalar("0"),
            30: scalar("]"),
            31: scalar("o"),
            32: scalar("u"),
            33: scalar("["),
            34: scalar("i"),
            35: scalar("p"),
            37: scalar("l"),
            38: scalar("j"),
            39: scalar("'"),
            40: scalar("k"),
            41: scalar(";"),
            42: scalar("\\"),
            43: scalar(","),
            44: scalar("/"),
            45: scalar("n"),
            46: scalar("m"),
            47: scalar("."),
            49: scalar(" "),
            50: scalar("`")
        ]
    }()

    private func kittyBaseLayoutKey(from event: NSEvent) -> UnicodeScalar? {
        Self.kittyBaseLayoutKeyMap[event.keyCode]
    }

    private func kittyTextEvent(from event: NSEvent, eventType: KittyKeyboardEventType, text: String? = nil) -> KittyKeyEvent? {
        guard let chars = event.charactersIgnoringModifiers,
              let scalar = chars.unicodeScalars.first else {
            return nil
        }
        let baseScalar = String(scalar).lowercased().unicodeScalars.first ?? scalar
        let shiftedScalar = event.modifierFlags.contains(.shift) ? event.characters?.unicodeScalars.first : nil
        let baseLayout = kittyBaseLayoutKey(from: event)
        let baseLayoutKey = baseLayout == baseScalar ? nil : baseLayout
        let modifiers = kittyModifiers(from: event, includeOption: optionAsMetaKey)
        return KittyKeyEvent(key: .unicode(baseScalar.value),
                             modifiers: modifiers,
                             eventType: eventType,
                             text: text,
                             shiftedKey: shiftedScalar,
                             baseLayoutKey: baseLayoutKey,
                             composing: kittyIsComposing)
    }

    private func kittyKeyEvent(from event: NSEvent, eventType: KittyKeyboardEventType, text: String? = nil) -> KittyKeyEvent? {
        if let functionKey = kittyFunctionalKey(from: event) {
            let modifiers = kittyModifiers(from: event, includeOption: optionAsMetaKey)
            return KittyKeyEvent(key: .functional(functionKey),
                                 modifiers: modifiers,
                                 eventType: eventType,
                                 text: text,
                                 shiftedKey: nil,
                                 baseLayoutKey: nil,
                                 composing: kittyIsComposing)
        }
        return kittyTextEvent(from: event, eventType: eventType, text: text)
    }

    private func kittyTextEventFromText(_ text: String) -> KittyKeyEvent {
        return KittyKeyEvent(key: .none,
                             modifiers: [],
                             eventType: .press,
                             text: text,
                             shiftedKey: nil,
                             baseLayoutKey: nil,
                             composing: kittyIsComposing)
    }

    @discardableResult
    private func sendKittyEvent(_ event: KittyKeyEvent) -> Bool {
        guard let bytes = kittyEncoder().encode(event) else { return false }
        send(bytes)
        return true
    }

    @discardableResult
    private func sendKittyFunctionalKey(_ key: KittyFunctionalKey, modifiers: KittyKeyboardModifiers = [], eventType: KittyKeyboardEventType = .press) -> Bool {
        let event = KittyKeyEvent(key: .functional(key),
                                  modifiers: modifiers,
                                  eventType: eventType,
                                  text: nil,
                                  shiftedKey: nil,
                                  baseLayoutKey: nil,
                                  composing: kittyIsComposing)
        return sendKittyEvent(event)
    }
    
    // NSTextInputClient protocol implementation
    open func unmarkText() {
        markedTextStorage = nil
        markedSelectedRange = NSRange(location: NSNotFound, length: 0)
        kittyIsComposing = false
        updateMarkedTextOverlay()
    }
    
    // NSTextInputClient protocol implementation
    open func selectedRange() -> NSRange {
        withTerminal { terminal in
            if let selection = self.selection, selection.active {
                let displayBuffer = terminal.displayBuffer
                var startLocation = (selection.start.row * displayBuffer.rows) + selection.start.col
                var endLocation = (selection.end.row * displayBuffer.rows) + selection.end.col
                if startLocation > endLocation {
                    swap(&startLocation, &endLocation)
                }
                let length = endLocation - startLocation
                if length > 0 {
                    return NSRange(location: startLocation, length: length)
                }
            }
            let cursorLocation = terminal.buffer.y * terminal.cols + terminal.buffer.x
            return NSRange(location: cursorLocation, length: 0)
        }
    }
    
    // NSTextInputClient protocol implementation
    open func markedRange() -> NSRange {
        guard let marked = markedTextStorage else {
            return NSRange.empty
        }
        return NSRange(location: 0, length: marked.length)
    }
    
    // NSTextInputClient protocol implementation
    open func hasMarkedText() -> Bool {
        markedTextStorage != nil
    }
    
    // NSTextInputClient protocol implementation
    open func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        // Return the marked text when the requested range overlaps it.
        if let marked = markedTextStorage, range.location != NSNotFound, range.location < marked.length {
            let clampedLength = min(range.length, marked.length - range.location)
            if clampedLength > 0 {
                let clampedRange = NSRange(location: range.location, length: clampedLength)
                actualRange?.pointee = clampedRange
                return marked.attributedSubstring(from: clampedRange)
            }
        }
        return nil
    }

    // NSTextInputClient Protocol implementation
    open func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .markedClauseSegment, .glyphInfo]
    }
    
    // NSTextInputClient protocol implementation
    open func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        
        if let r = window?.convertToScreen(convert(caretView!.frame, to: nil)) {
            return r
        }
        
        return .zero
    }
    
    // NSTextInputClient protocol implementation
    open func characterIndex(for point: NSPoint) -> Int {
        let local = convert(point, from: nil)
        let col = Int(local.x / cellDimension.width)
        let row = Int((bounds.height - local.y) / cellDimension.height)
        return withTerminal { terminal in
            row * terminal.cols + col
        }
    }
    
    open func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        //print ("Validating selector: \(item.action)")
        switch item.action {
        case #selector(performFindPanelAction(_:)):
            switch item.tag {
            case Int(NSFindPanelAction.showFindPanel.rawValue):
                return true
            case Int(NSFindPanelAction.next.rawValue):
                return true
            case Int(NSFindPanelAction.previous.rawValue):
                return true
            case Int(NSFindPanelAction.setFindString.rawValue):
                return withTerminal { _ in selection.active }
            default:
                return false
            }
        case #selector(performTextFinderAction(_:)):
            if let fa = NSTextFinder.Action (rawValue: item.tag) {
                switch fa {
                case .showFindInterface:
                    return true
                case .showReplaceInterface:
                    return true
                case .hideReplaceInterface:
                    return true
                case .hideFindInterface:
                    return true
                case .nextMatch:
                    return true
                case .previousMatch:
                    return true
                case .setSearchString:
                    return withTerminal { _ in selection.active }
                default:
                    return false
                }
            }
            return false
        case #selector(paste(_:)):
            return true
        case #selector(selectAll(_:)):
            return true
        case #selector(copy(_:)):
            return withTerminal { _ in selection.active }
        default:
            print ("Validating User Interface Item: \(item)")
            return false
        }
    }

    @objc open func performFindPanelAction(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem else {
            return
        }
        switch menuItem.tag {
        case Int(NSFindPanelAction.showFindPanel.rawValue):
            showFindBar(prefillSelection: true)
        case Int(NSFindPanelAction.next.rawValue):
            performFind(next: true)
        case Int(NSFindPanelAction.previous.rawValue):
            performFind(next: false)
        case Int(NSFindPanelAction.setFindString.rawValue):
            setFindPasteboardFromSelection()
            showFindBar(prefillSelection: true)
        default:
            break
        }
    }

    open override func performTextFinderAction(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let action = NSTextFinder.Action(rawValue: menuItem.tag) else {
            return
        }

        switch action {
        case .nextMatch:
            performFind(next: true)
        case .previousMatch:
            performFind(next: false)
        case .setSearchString:
            setFindPasteboardFromSelection()
            showFindBar(prefillSelection: true)
        case .showFindInterface:
            showFindBar(prefillSelection: true)
        case .hideFindInterface:
            hideFindBar()
        default:
            break
        }
    }

    private func performFind(next: Bool) {
        let termFromBar = (findBar?.isHidden == false) ? findBar?.searchText : nil
        guard let term = termFromBar ?? findPasteboardString(), !term.isEmpty else {
            return
        }
        updateFindPasteboard(term)
        let options = findBar?.options ?? SearchOptions()
        if next {
            _ = findNext(term, options: options)
        } else {
            _ = findPrevious(term, options: options)
        }
    }

    private func setFindPasteboardFromSelection() {
        let selected = withTerminal { _ in
            selection.getSelectedText()
        }
        guard !selected.isEmpty else {
            return
        }
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.clearContents()
        pasteboard.setString(selected, forType: .string)
    }

    private func findPasteboardString() -> String? {
        let pasteboard = NSPasteboard(name: .find)
        return pasteboard.string(forType: .string)
    }

    private func updateFindPasteboard(_ term: String) {
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.clearContents()
        pasteboard.setString(term, forType: .string)
    }

    private func ensureFindBar() -> TerminalFindBarView {
        if let findBar {
            return findBar
        }
        let bar = TerminalFindBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = true
        bar.onSearchChanged = { [weak self] term in
            self?.handleFindBarSearchChanged(term)
        }
        bar.onFindNext = { [weak self] in
            self?.performFind(next: true)
        }
        bar.onFindPrevious = { [weak self] in
            self?.performFind(next: false)
        }
        bar.onClose = { [weak self] in
            self?.hideFindBar()
        }
        bar.onOptionsChanged = { [weak self] options in
            self?.handleFindBarOptionsChanged(options)
        }

        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            bar.widthAnchor.constraint(lessThanOrEqualToConstant: 520)
        ])
        findBar = bar
        return bar
    }

    private func showFindBar(prefillSelection: Bool) {
        let bar = ensureFindBar()
        bar.isHidden = false
        let selectedText = prefillSelection ? withTerminal({ _ in selection.getSelectedText() }) : nil
        let initial = (selectedText?.isEmpty == false) ? selectedText : findPasteboardString()
        if let initial {
            bar.searchText = initial
            handleFindBarSearchChanged(initial)
        }
        bar.focus()
    }

    private func hideFindBar() {
        findBar?.isHidden = true
        window?.makeFirstResponder(self)
    }

    private func handleFindBarSearchChanged(_ term: String) {
        findBarTerm = term
        if term.isEmpty {
            clearSearch()
            return
        }
        updateFindPasteboard(term)
        _ = findNext(term, options: findBarOptions)
    }

    private func handleFindBarOptionsChanged(_ options: SearchOptions) {
        findBarOptions = options
        if !findBarTerm.isEmpty {
            _ = findNext(findBarTerm, options: options)
        }
    }
    
    open func selectionChanged(source: Terminal) {
        onMain { [weak self] in
            guard let self, self.terminal != nil else { return }
            // Every renderer, not just Metal: the Core Graphics path draws from
            // `currentSnapshot` too, so `needsDisplay` on its own repainted the
            // previous frame and the selection never showed up.
            self.invalidateTerminalContents()
        }
    }
    
    func cut (sender: Any?) {}
    
    @objc
    open func paste(_ sender: Any)
    {
        let clipboard = NSPasteboard.general
        let text = clipboard.string(forType: .string)
        insertText(text ?? "", replacementRange: NSRange(location: 0, length: 0), isPaste: true)
    }
    
    @objc
    open func copy(_ sender: Any)
    {
        // find the selected range of text in the buffer and put in the clipboard
        let str = withTerminal { _ in
            selection.getSelectedText()
        }
        
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        clipboard.setString(str, forType: .string)
    }
    
    public override func selectAll(_ sender: Any?)
    {
        selectAll ()
    }
    
    //func undo (sender: Any) {}
    //func redo (sender: Any) {}
    func zoomIn (sender: Any) {}
    func zoomOut (sender: Any) {}
    func zoomReset (sender: Any) {}
    
    // Returns the vt100 mouseflags
    func encodeMouseEvent (with event: NSEvent, overwriteRelease: Bool = false) -> Int
    {
        withTerminal { _ in
            encodeMouseEventLocked(with: event, overwriteRelease: overwriteRelease)
        }
    }

    func encodeMouseEventLocked (with event: NSEvent, overwriteRelease: Bool = false) -> Int
    {
        terminal.terminalLock.preconditionLocked()
        let flags = event.modifierFlags
        let isReleaseEvent = overwriteRelease || [NSEvent.EventType.leftMouseUp, .otherMouseUp, .rightMouseUp].contains(event.type)
        
        return terminal.encodeButton(button: event.buttonNumber, release: isReleaseEvent, shift: flags.contains(.shift), meta: flags.contains(.option), control: flags.contains(.control))
    }
    
    func calculateMouseHit (with event: NSEvent) -> (grid: Position, pixels: Position)
    {
        let point = convert(event.locationInWindow, from: nil)
        return calculateMouseHit(at: point)
    }

    func calculateMouseHit (at point: CGPoint) -> (grid: Position, pixels: Position)
    {
        withTerminal { _ in
            calculateMouseHitLocked(at: point)
        }
    }

    func calculateMouseHitLocked (at point: CGPoint) -> (grid: Position, pixels: Position)
    {
        terminal.terminalLock.preconditionLocked()
        func toInt (_ p: NSPoint) -> Position {

            let x = min (max (p.x, 0), bounds.width)
            let y = min (max (p.y, 0), bounds.height)
            return Position (col: Int (x), row: Int (bounds.height-y))
        }
        let displayBuffer = terminal.displayBuffer
        let col = Int (point.x / cellDimension.width)
        let row = Int ((frame.height-point.y) / cellDimension.height)
        var colValue = min (max (0, col), terminal.cols-1)
        let bufferRow = row + displayBuffer.yDisp
        let maxRow = max (0, displayBuffer.lines.count - 1)
        let rowValue = min (max (0, bufferRow), maxRow)
        // In BiDi rows the clicked (visual) column is translated back to the
        // logical buffer column it displays.
        if rowValue < displayBuffer.lines.count,
           let bidiLayout = TerminalBidi.layout(row: rowValue, buffer: displayBuffer,
                                                cols: terminal.cols, terminal: terminal,
                                                font: fontSet.normal,
                                                hostPolicy: bidiHostPolicy),
           colValue < bidiLayout.visualToLogicalCol.count {
            colValue = bidiLayout.visualToLogicalCol[colValue]
        }
        return (Position(col: colValue, row: rowValue), toInt (point))
    }
    
    private func sharedMouseEvent (with event: NSEvent)
    {
        withTerminal { terminal in
            let displayBuffer = terminal.displayBuffer
            let hit = calculateMouseHitLocked(at: convert(event.locationInWindow, from: nil))
            let buttonFlags = encodeMouseEventLocked(with: event)
            let screenRow = max (0, min (displayBuffer.rows - 1, hit.grid.row - displayBuffer.yDisp))
            terminal.sendEvent(buttonFlags: buttonFlags, x: hit.grid.col, y: screenRow, pixelX: hit.pixels.col, pixelY: hit.pixels.row)
        }
    }
    
    private var autoScrollDelta = 0
    private var selectionAutoScrollTimer: Timer?
    // Last mouse location (view coordinates) seen during a selection drag, used
    // to re-extend the selection as the auto-scroll timer advances the viewport
    // while the pointer is held still past the top or bottom edge.
    private var lastSelectionDragPoint: CGPoint?

    private func startSelectionAutoScrollTimer() {
        if selectionAutoScrollTimer != nil {
            return
        }
        // The timer has to fire while the mouse is being tracked: during a drag
        // the run loop is in .eventTracking mode, in which timers scheduled in
        // the default mode are suspended. Add it in .common modes so it keeps
        // ticking while the button is held down at the edge.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] t in
            self?.scrollingTimerElapsed(source: t)
        }
        RunLoop.main.add(timer, forMode: .common)
        selectionAutoScrollTimer = timer
    }

    private func stopSelectionAutoScrollTimer() {
        selectionAutoScrollTimer?.invalidate()
        selectionAutoScrollTimer = nil
    }

    // Callback from the selection auto-scroll timer: advance the viewport while
    // the pointer is held past an edge, and grow the selection to match.
    private func scrollingTimerElapsed (source: Timer)
    {
        if autoScrollDelta == 0 {
            return
        }
        if autoScrollDelta < 0 {
            scrollUp(lines: autoScrollDelta * -1)
        } else {
            scrollDown(lines: autoScrollDelta)
        }
        // Extend the selection to the pointer's position under the new viewport.
        if selection.active, let point = lastSelectionDragPoint {
            let hit = calculateMouseHit(at: point).grid
            selection.dragExtend(bufferPosition: Position(col: hit.col, row: hit.row))
        }
        setNeedsDisplay(bounds)
    }
    
    private func shiftBypassesMouseReporting(for event: NSEvent) -> Bool {
        withTerminal { _ in
            shiftBypassesMouseReportingLocked(for: event)
        }
    }

    private func shiftBypassesMouseReportingLocked(for event: NSEvent) -> Bool {
        terminal.terminalLock.preconditionLocked()
        return event.modifierFlags.contains(.shift) && !terminal.mouseShiftCapture
    }

    private func semanticPromptModifiers(for event: NSEvent) -> SemanticPromptClickModifiers {
        var result: SemanticPromptClickModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    // R6: the gesture state is captured at press time, before any handler
    // mutates it; guards that test live view state after earlier handlers
    // changed it are a known defect class.
    private var pointerPressSnapshot = SemanticPromptPointerSnapshot(
        selectionWasActive: false, didDrag: false, clickCount: 0,
        pressWasSemanticEligible: false)
    private var pendingSemanticClick: DispatchWorkItem?
    var semanticClickCoalescingDelay: TimeInterval = NSEvent.doubleClickInterval
    /// Number of times a semantic-prompt click deferral was scheduled. Used by
    /// tests to confirm the F.5 pre-gate skips scheduling when routing cannot
    /// apply.
    private(set) var semanticDeferralScheduleCount = 0

    open override func mouseDown(with event: NSEvent) {
        pendingSemanticClick?.cancel()
        pendingSemanticClick = nil
        didSelectionDrag = false
        let shouldSendButtonPress = withTerminal { terminal in
            pointerPressSnapshot = SemanticPromptPointerSnapshot(
                selectionWasActive: selection.active,
                didDrag: false,
                clickCount: event.clickCount,
                pressWasSemanticEligible: false)
            if allowMouseReporting && !shiftBypassesMouseReportingLocked(for: event) && terminal.mouseMode.sendButtonPress() {
                return true
            }
            pointerPressSnapshot.pressWasSemanticEligible = true
            let hit = calculateMouseHitLocked(at: convert(event.locationInWindow, from: nil)).grid
            switch event.clickCount {
            case 1:
                if selection.active == true {
                    if event.modifierFlags.contains(.shift) {
                        selection.shiftExtend(bufferPosition: Position(col: hit.col, row: hit.row))
                    } else {
                        selection.active = false
                    }
                }
            case 2:
                let displayBuffer = terminal.displayBuffer
                selection.selectWordOrExpression(at: Position(col: hit.col, row: hit.row), in: displayBuffer)

            default:
                selection.select(row: hit.row)
            }
            return false
        }
        if shouldSendButtonPress {
            sharedMouseEvent(with: event)
            return
        }
        setNeedsDisplay(bounds)
    }
    
    func getPayload (for event: NSEvent) -> Any?
    {
        let hit = calculateMouseHit(with: event).grid
        return withTerminal { terminal in
            let displayBuffer = terminal.displayBuffer
            return displayBuffer.lines[hit.row].packedView(at: hit.col).getPayload()
        }
    }
    
    var didSelectionDrag: Bool = false
    
    open override func mouseUp(with event: NSEvent) {
        defer {
            didSelectionDrag = false
            pointerPressSnapshot.pressWasSemanticEligible = false
        }
        stopSelectionAutoScrollTimer()
        autoScrollDelta = 0
        lastSelectionDragPoint = nil
        let hit = calculateMouseHit(with: event).grid
        updateHoverLink(at: hit, commandOverride: commandActive || event.modifierFlags.contains(.command))
        if !didSelectionDrag,
           let result = linkForClick(at: hit, hasCommandModifier: event.modifierFlags.contains(.command)) {
            terminalDelegate?.requestOpenLink(source: self, link: result.link, params: result.params)
            return
        }
        if withTerminal({ terminal in allowMouseReporting && !shiftBypassesMouseReportingLocked(for: event) && terminal.mouseMode.sendButtonRelease() }) {
            sharedMouseEvent(with: event)
            return
        }

        // The semantic route runs last, after the double-click interval.
        // A second press cancels this work before word selection completes.
        var snapshot = pointerPressSnapshot
        snapshot.didDrag = didSelectionDrag
        guard snapshot.clickCount == 1 else { return }
        let modifiers = semanticPromptModifiers(for: event)
        // F.5: don't schedule the deferral (retaining a line and arming a
        // timer for the full double-click interval) when routing can never
        // apply — before any OSC 133, when disabled, not armed, no click mode,
        // or the gesture disqualifies. Eligibility is re-derived at fire time
        // too; this only skips pointless scheduling.
        let hitLine = withTerminal { terminal -> BufferLine? in
            guard terminal.mightRouteSemanticPromptClick(modifiers: modifiers,
                                                          snapshot: snapshot) else {
                return nil
            }
            return terminal.bufferLine(atRow: hit.row)
        }
        guard let hitLine else { return }
        semanticDeferralScheduleCount += 1
        // Capture the clicked line's identity, not its absolute row: the row
        // index shifts if scrollback trims during the coalescing delay, so
        // re-resolve it at fire time and drop the click if the line is gone.
        let hitColumn = hit.col
        let hitGeneration = hitLine.recycleGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSemanticClick = nil
            let handled = self.withTerminal { terminal in
                guard let resolvedRow = terminal.semanticRow(forLineIdentity: hitLine,
                                                              recycleGeneration: hitGeneration) else {
                    return false
                }
                return terminal.handleSemanticPromptClick(
                    at: Position(col: hitColumn, row: resolvedRow),
                    modifiers: modifiers,
                    snapshot: snapshot)
            }
            if handled {
                self.setNeedsDisplay(self.bounds)
            }
        }
        pendingSemanticClick = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + semanticClickCoalescingDelay,
                                      execute: workItem)

        #if DEBUG
        // let hit = calculateMouseHit(with: event)
        //print ("Up at col=\(hit.col) row=\(hit.row) count=\(event.clickCount) selection.active=\(selection.active) didSelectionDrag=\(didSelectionDrag) ")
        #endif

    }
    
    open override func mouseDragged(with event: NSEvent) {
        let dragInfo = withTerminal { terminal -> (hit: Position, displayYDisp: Int, displayRows: Int, handled: Bool) in
            let displayBuffer = terminal.displayBuffer
            let mouseHit = calculateMouseHitLocked(at: convert(event.locationInWindow, from: nil))
            let hit = mouseHit.grid
            if allowMouseReporting && !shiftBypassesMouseReportingLocked(for: event) {
                if terminal.mouseMode.sendButtonTracking() {
                    let flags = encodeMouseEventLocked(with: event)
                    let screenRow = max (0, min (displayBuffer.rows - 1, hit.row - displayBuffer.yDisp))
                    terminal.sendMotion(buttonFlags: flags, x: hit.col, y: screenRow, pixelX: mouseHit.pixels.col, pixelY: mouseHit.pixels.row)
                    return (hit, displayBuffer.yDisp, displayBuffer.rows, true)
                }
                if terminal.mouseMode != .off {
                    return (hit, displayBuffer.yDisp, displayBuffer.rows, true)
                }
            }

            if selection.active {
                selection.dragExtend(bufferPosition: Position(col: hit.col, row: hit.row))
            } else {
                selection.setSoftStart(bufferPosition: Position(col: hit.col, row: hit.row))
                selection.startSelection()
            }
            return (hit, displayBuffer.yDisp, displayBuffer.rows, false)
        }
        if dragInfo.handled {
            return
        }
        didSelectionDrag = true
        lastSelectionDragPoint = convert(event.locationInWindow, from: nil)
        autoScrollDelta = 0
        let screenRow = dragInfo.hit.row - dragInfo.displayYDisp
        if withTerminal({ _ in selection.active }) {
            if screenRow <= 0 {
                autoScrollDelta = calcScrollingVelocity(delta: screenRow * -1) * -1
            } else if screenRow >= dragInfo.displayRows {
                autoScrollDelta = calcScrollingVelocity(delta: screenRow - dragInfo.displayRows)
            }
        }
        // Keep auto-scrolling while the pointer is held past an edge; the mouse
        // stops emitting drag events once it stops moving, so a timer drives it.
        if autoScrollDelta != 0 {
            startSelectionAutoScrollTimer()
        } else {
            stopSelectionAutoScrollTimer()
        }
        setNeedsDisplay(bounds)
    }
    
    func tryUrlFont () -> NSFont
    {
        for x in ["Optima", "Helvetica", "Helvetica Neue"] {
            if let font = NSFont (name: x, size: 12) {
                return font
            }
        }
        return NSFont.systemFont(ofSize: 12)
    }
    
    var urlPreview: NSTextField?
    private var lastReportedLink: String?
    func previewUrl (payload: String)
    {
        if let (url, _) = urlAndParamsFrom(payload: payload) {
            if let up = urlPreview {
                up.stringValue = url
                up.sizeToFit()
            } else {
                let nup: NSTextField
                if #available(macOS 10.12, *) {
                    nup = NSTextField (string: url)
                } else {
                    nup = NSTextField ()
                }
                nup.isBezeled = false
                nup.font = tryUrlFont ()
                nup.backgroundColor = nativeForegroundColor
                nup.textColor = nativeBackgroundColor
                nup.sizeToFit()
                nup.frame = CGRect (x: 0, y: 0, width: nup.frame.width, height: nup.frame.height)
                addSubview(nup)
                urlPreview = nup
            }
        }
    }
    
    func removePreviewUrl ()
    {
        if let urlPreview = self.urlPreview {
            urlPreview.removeFromSuperview()
            self.urlPreview = nil
        }
    }

    func reportLink(at position: Position)
    {
        guard linkReporting != .none else {
            lastReportedLink = nil
            return
        }
        let mode: Terminal.LinkLookupMode = linkReporting == .explicit ? .explicitOnly : .explicitAndImplicit
        let link = withTerminal { terminal in
            terminal.link(at: .buffer(position), mode: mode)
        }
        if link != lastReportedLink {
            lastReportedLink = link
        }
    }

    func updateHoverLink(at position: Position, commandOverride: Bool? = nil)
    {
        let hoverModes: [LinkHighlightMode] = [.hover, .hoverWithModifier]
        guard hoverModes.contains(linkHighlightMode) else {
            if linkHighlightRange != nil {
                let oldRange = linkHighlightRange
                linkHighlightRange = nil
                invalidateLinkHighlight(oldRange: oldRange, newRange: nil)
                frameDriver.markDirty()
            }
            return
        }
        let effectiveCommandActive = commandOverride ?? commandActive
        if linkHighlightMode == .hoverWithModifier && !effectiveCommandActive {
            if linkHighlightRange != nil {
                let oldRange = linkHighlightRange
                linkHighlightRange = nil
                invalidateLinkHighlight(oldRange: oldRange, newRange: nil)
                frameDriver.markDirty()
            }
            return
        }
        let match = withTerminal { terminal in
            terminal.linkMatch(at: .buffer(position), mode: .explicitAndImplicit)
        }
        let newRange = match?.rowRanges
        if newRange != linkHighlightRange {
            let oldRange = linkHighlightRange
            linkHighlightRange = newRange
            invalidateLinkHighlight(oldRange: oldRange, newRange: newRange)
            frameDriver.markDirty()
        }
    }

    func currentMouseHit() -> Position?
    {
        guard let window else {
            return nil
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return calculateMouseHit(at: point).grid
    }
    
    public override func mouseMoved(with event: NSEvent) {
        if #available(macOS 26, *) {
            // On macOS 26 movement arrives via `acceptsMouseMovedEvents`, which delivers
            // to the first responder regardless of the pointer's location. Ignore moves
            // outside our bounds so we do not report cells the pointer is not over.
            let point = convert(event.locationInWindow, from: nil)
            if !bounds.contains(point) { return }
        }
        let hit = calculateMouseHit(with: event)
        if commandActive {
            if let payload = getPayload(for: event) as? String {
                previewUrl (payload: payload)
            }
            reportLink(at: hit.grid)
        }
        updateHoverLink(at: hit.grid)
        
        if withTerminal({ $0.mouseMode.sendMotionEvent() }) {
            let flags = encodeMouseEvent(with: event, overwriteRelease: true)
            withTerminal { terminal in
                let displayBuffer = terminal.displayBuffer
                let screenRow = max(0, min(displayBuffer.rows - 1, hit.grid.row - displayBuffer.yDisp))
                terminal.sendMotion(buttonFlags: flags, x: hit.grid.col, y: screenRow, pixelX: hit.pixels.col, pixelY: hit.pixels.row)
            }
        }
    }
    
    /* Legacy wheel handler superseded by the precise-scroll implementation below.
    public override func scrollWheel(with event: NSEvent) {
        if event.deltaY == 0 {
            return
        }
        let mouseMode = withTerminal { $0.mouseMode }
        if allowMouseReporting && !shiftBypassesMouseReporting(for: event) && mouseMode != .off {
            let hit = calculateMouseHit(with: event)
            let displayMetrics = withTerminal { terminal in
                (rows: terminal.displayBuffer.rows, yDisp: terminal.displayBuffer.yDisp)
            }
            let screenRow = max (0, min (displayMetrics.rows - 1, hit.grid.row - displayMetrics.yDisp))
            let button = event.deltaY > 0 ? 4 : 5
            let flags = event.modifierFlags
            let buttonFlags = withTerminal { terminal in
                terminal.encodeButton(button: button, release: false, shift: flags.contains(.shift), meta: flags.contains(.option), control: flags.contains(.control))
            }
            let lines = calcScrollingVelocity(delta: Int(abs(event.deltaY)))
            for _ in 0..<lines {
                withTerminal { terminal in
                    terminal.sendEvent(buttonFlags: buttonFlags, x: hit.grid.col, y: screenRow, pixelX: hit.pixels.col, pixelY: hit.pixels.row)
                }
            }
        } else if withTerminal({ $0.isDisplayBufferAlternate }) {
            let lines = calcScrollingVelocity(delta: Int(abs(event.deltaY)))
            for _ in 0..<lines {
                if event.deltaY > 0 {
                    sendKeyUp()
                } else {
                    sendKeyDown()
                }
            }
        } else {
            let velocity = calcScrollingVelocity(delta: Int(abs(event.deltaY)))
            if event.deltaY > 0 {
                scrollUp(lines: velocity)
            } else {
                scrollDown(lines: velocity)
            }
        }
    }
    
    /// Velocity curve used by drag-selection auto-scroll (how fast to scroll
    /// when a selection drag is held past a terminal edge).
    private func calcScrollingVelocity (delta: Int) -> Int
    {
        if delta > 9 {
            return max (withTerminal { $0.rows }, 20)
        }
        if delta > 5 {
            return 10
        }
        if delta > 1 {
            return 3
        }
        return 1
    }
    */

    /// Velocity curve used by drag-selection auto-scroll.
    private func calcScrollingVelocity (delta: Int) -> Int
    {
        if delta > 9 { return max(withTerminal { $0.rows }, 20) }
        if delta > 5 { return 10 }
        if delta > 1 { return 3 }
        return 1
    }

    /// Leftover fractional trackpad scroll (in points) carried between events so
    /// sub-cell precise deltas accumulate instead of being dropped.
    private var scrollAccumulator: CGFloat = 0

    /// Multiplier applied to wheel/trackpad scroll deltas. `1.0` scrolls at the
    /// system's native rate; values below `1.0` slow scrolling down, above speed
    /// it up. Host apps can expose this as a user preference. Clamped to a small
    /// positive floor so it can never disable scrolling entirely.
    public var scrollSensitivity: CGFloat = 1.0 {
        didSet { scrollSensitivity = max(0.05, scrollSensitivity) }
    }

    public override func scrollWheel(with event: NSEvent) {
        // Preserves the previous `deltaY == 0` early exit, restated against the
        // delta this method now reads. Without it a zero delta would fall into
        // the non-precise branch below and be turned into a spurious -1 line.
        if event.scrollingDeltaY == 0 {
            return
        }
        guard let cellHeight = cellDimension?.height, cellHeight > 0 else {
            return
        }

        // Translate the wheel/trackpad delta into a whole number of terminal
        // lines while preserving a 1:1 feel. Precise (trackpad) deltas are pixel
        // values we accumulate and divide by the cell height, keeping the
        // remainder for the next event; classic mouse-wheel deltas already come
        // in line units. This replaces the old step-function velocity that
        // jumped a full page on fast flicks — the cause of the visible line
        // "skipping" during fast scrolls. `scrollSensitivity` scales the delta.
        let scaledDelta = event.scrollingDeltaY * scrollSensitivity
        let lines: Int
        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += scaledDelta
            lines = Int(scrollAccumulator / cellHeight)
            scrollAccumulator -= CGFloat(lines) * cellHeight
        } else {
            scrollAccumulator = 0
            // A non-precise wheel notch must always move at least one line, even
            // when a low sensitivity would otherwise round it away to zero.
            let rounded = Int(scaledDelta.rounded())
            lines = rounded != 0 ? rounded : (event.scrollingDeltaY > 0 ? 1 : -1)
        }
        if lines == 0 {
            return
        }
        let scrollingUp = lines > 0
        let magnitude = abs(lines)

        if withTerminal({ terminal in
            allowMouseReporting && !shiftBypassesMouseReportingLocked(for: event) && terminal.mouseMode != .off
        }) {
            let hit = calculateMouseHit(with: event)
            let button = scrollingUp ? 4 : 5
            let flags = event.modifierFlags
            withTerminal { terminal in
                let displayBuffer = terminal.displayBuffer
                let screenRow = max(0, min(displayBuffer.rows - 1, hit.grid.row - displayBuffer.yDisp))
                let buttonFlags = terminal.encodeButton(button: button, release: false,
                                                        shift: flags.contains(.shift), meta: flags.contains(.option), control: flags.contains(.control))
                for _ in 0..<magnitude {
                    terminal.sendEvent(buttonFlags: buttonFlags, x: hit.grid.col, y: screenRow,
                                       pixelX: hit.pixels.col, pixelY: hit.pixels.row)
                }
            }
        } else if withTerminal({ $0.isDisplayBufferAlternate }) {
            for _ in 0..<magnitude {
                if scrollingUp {
                    sendKeyUp()
                } else {
                    sendKeyDown()
                }
            }
        } else {
            if scrollingUp {
                scrollUp(lines: magnitude)
            } else {
                scrollDown(lines: magnitude)
            }
        }
    }
    
    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }
    
    public func resetFontSize ()
    {
        // Recompute metrics and redraw, but unlike the font setter do not
        // clear the active selection
        fontSet = FontSet (font: FontSet.defaultFont)
        resetFont ()
    }
    
    func getImageScale () -> CGFloat {
        self.window?.backingScaleFactor ?? 1
    }
    
    func scale (image: NSImage, size: CGSize) -> NSImage {
        guard let source = bitmapCGImage(from: image),
              let context = bitmapContext(size: size) else {
            return image
        }
        let srcRatio = image.size.height/image.size.width
        let scaledRatio = size.width/size.height
        let dstRect: CGRect
        
        if srcRatio < scaledRatio {
            let nw = (size.height * image.size.width) / image.size.height
            dstRect = CGRect (x: (size.width-nw)/2, y: 0, width: nw, height: size.height)
        } else {
            let nh = (size.width * image.size.height) / image.size.width
            dstRect = CGRect (x: 0, y: (size.height-nh)/2, width: size.width, height: nh)
        }
        context.interpolationQuality = .high
        context.draw(source, in: dstRect)
        guard let scaled = context.makeImage() else { return image }
        return NSImage(cgImage: scaled, size: size)
    }
    
    func drawImageInStripe (image: TTImage, srcY: CGFloat, width: CGFloat, srcHeight: CGFloat, dstHeight: CGFloat, size: CGSize) -> TTImage? {
        guard image.size.width > 0, image.size.height > 0,
              let source = bitmapCGImage(from: image),
              let context = bitmapContext(size: size) else { return nil }
        let scaleX = CGFloat(source.width) / image.size.width
        let scaleY = CGFloat(source.height) / image.size.height
        let cropRect = CGRect(x: 0,
                              y: (image.size.height - srcY - srcHeight) * scaleY,
                              width: image.size.width * scaleX,
                              height: srcHeight * scaleY).integral
        guard let cropped = source.cropping(to: cropRect) else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: dstHeight))
        guard let stripe = context.makeImage() else { return nil }
        return NSImage(cgImage: stripe, size: size)
    }

    private func bitmapCGImage(from image: NSImage) -> CGImage? {
        for representation in image.representations {
            if let bitmap = representation as? NSBitmapImageRep,
               let cgImage = bitmap.cgImage {
                return cgImage
            }
        }
        var proposedRect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    private func bitmapContext(size: CGSize) -> CGContext? {
        let width = max(1, Int(ceil(size.width)))
        let height = max(1, Int(ceil(size.height)))
        return CGContext(data: nil, width: width, height: height,
                         bitsPerComponent: 8, bytesPerRow: width * 4,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    
    open func showCursor(source: Terminal) {
        frameDriver.markDirty()
    }

    open func hideCursor(source: Terminal) {
        frameDriver.markDirty()
    }
    
    open func cursorStyleChanged (source: Terminal, newStyle: CursorStyle) {
        let style = newStyle
        onMain { [weak self] in
            guard let self else { return }
            self.caretView?.style = style
            self.updateCaretView()
#if canImport(MetalKit)
            self.frameDriver.markDirty()
#endif
        }
    }

    /// Controls how this view responds to the bell character; `.sound`
    /// preserves the historical behavior of invoking the delegate's `bell`
    public var bellStyle: BellStyle = .sound {
        didSet {
            bellPolicy.setStyle(bellStyle)
        }
    }

    /// Gate consulted when a queued bell is delivered on the main thread.
    let bellPolicy = BellPolicy()

    /// Coalescing channel for idempotent notifications (io-gaps.md G6).
    let eventQueue = TerminalEventQueue()

    /// Set by `updateScroller`, applied by `frameTick` under the lock.
    var scrollerNeedsUpdate = false

    /// Last mouse mode reported by the terminal, captured while the notifying
    /// thread held the lock. Read by hit-testing paths that must not take the
    /// terminal lock: `shouldTrackMouse` ran 1 611 times in one measured run.
    private let mouseModeLock = NSLock()
    private var cachedMouseMode: Terminal.MouseMode = .off

    var currentMouseMode: Terminal.MouseMode {
        mouseModeLock.lock()
        defer { mouseModeLock.unlock() }
        return cachedMouseMode
    }

    open func bell(source: Terminal) {
        // Ghostty's shape: the read path pushes a payloadless value and
        // forgets. The style check and the 100 ms debounce happen at the drain,
        // on the main thread. Affordable here only because the queue collapses
        // a burst into one pending drain (io-gaps.md G9 phase 2).
        eventQueue.post(.bell)
    }

    /// Applies one coalesced event. Main thread.
    func applyTerminalEvent (_ event: TerminalEvent) {
        switch event {
        case .bufferActivated:
            updateScroller()
        case .mouseModeChanged:
            if currentMouseMode == .anyEvent {
                startTracking()
            } else {
                deregisterTrackingInterest()
            }
        case .bell:
            deliverBell()
        }
    }

    private func deliverBell () {
        guard bellPolicy.shouldDeliver() else { return }
        onMain { [weak self] in
            guard let self else { return }
            switch self.bellStyle {
            case .none:
                break
            case .sound:
                self.terminalDelegate?.bell(source: self)
            case .visual:
                self.flashVisualBell()
            case .soundAndVisual:
                self.terminalDelegate?.bell(source: self)
                self.flashVisualBell()
            }
        }
    }

    /// Briefly flashes the view with the foreground color, the "visual bell"
    func flashVisualBell ()
    {
        guard let layer = self.layer else { return }
        let flash = CALayer ()
        flash.frame = bounds
        flash.backgroundColor = nativeForegroundColor.cgColor
        flash.opacity = 0
        layer.addSublayer (flash)
        CATransaction.begin ()
        CATransaction.setCompletionBlock { flash.removeFromSuperlayer() }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0.0, 0.35, 0.0]
        animation.keyTimes = [0, 0.3, 1]
        animation.duration = 0.2
        flash.add(animation, forKey: "visualBell")
        CATransaction.commit ()
    }

    public func progressReport(source: Terminal, report: Terminal.ProgressReport) {
        onMain { [weak self] in
            self?.handleProgressReport(report)
        }
    }

    public func isProcessTrusted(source: Terminal) -> Bool {
        true
    }

    public func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? {
        cachedCellPixelSizeValue()
    }
    
    public func mouseModeChanged(source: Terminal) {
        // Captured here, where the notifying thread holds the terminal lock.
        // The drain then applies it without taking the lock at all.
        mouseModeLock.lock()
        cachedMouseMode = source.mouseMode
        mouseModeLock.unlock()
        eventQueue.post(.mouseModeChanged)
    }
    
    public func setTerminalTitle(source: Terminal, title: String) {
        let capturedTitle = title
        onMain { [weak self] in
            guard let self else { return }
            self.terminalDelegate?.setTerminalTitle(source: self, title: capturedTitle)
        }
    }
    
    public func sizeChanged(source: Terminal) {
        let cols = source.cols
        let rows = source.rows
        onMain { [weak self] in
            guard let self else { return }
            self.terminalDelegate?.sizeChanged(source: self, newCols: cols, newRows: rows)
            self.updateScroller()
        }
    }
    
    func ensureCaretIsVisible ()
    {
        let target = withTerminal { terminal -> Int? in
            guard !terminal.synchronizedOutputActive else { return nil }
            let displayBuffer = terminal.displayBuffer
            let realCaret = displayBuffer.y + displayBuffer.yBase
            let viewportEnd = displayBuffer.yDisp + displayBuffer.rows

            if realCaret >= viewportEnd || realCaret < displayBuffer.yDisp {
                return displayBuffer.yBase
            }
            return nil
        }
        if let target {
            scrollTo(row: target)
        }
    }
    
    public func setTerminalIconTitle(source: Terminal, title: String) {
        let _ = title
    }
    
    // Terminal.Delegate method implementation
    public func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? {
        switch command {
        case .bringToFront:
            return nil
        case .deiconifyWindow:
            return nil
        case .iconifyWindow:
            return nil
        case .maximizeWindow:
            return nil
        case .maximizeWindowHorizontally:
            return nil
        case .maximizeWindowVertically:
            return nil
        case .moveWindowTo(_, _):
            return nil
        case .refreshWindow:
            return nil
        case .reportCellSizeInPixels:
            if let cellSize = cachedCellPixelSizeValue() {
                return source.cc.CSI + "6;\(cellSize.height);\(cellSize.width)t".utf8
            }
            return nil
        case .reportIconLabel:
            return nil
        case .reportScreenSizeCharacters:
            return nil
        case .resizeWindowTo(width: let width, height: let height):
            print("Request to resize to \(width)x\(height)")
            return nil
        case .sendToBack:
            return nil
        case .resizeTo(_):
            return nil
        case .resizeTerminal:
            return nil
        case .restoreMaximizedWindow:
            return nil
        case .undoFullScreen:
            return nil
        case .switchToFullScreen:
            return nil
        case .toggleFullScreen:
            return nil
        case .reportTerminalState:
            return nil
        case .reportTerminalPosition:
            return nil
        case .reportTextAreaPosition:
            return nil
        case .reportTextAreaPixelDimension:
            guard let cellSize = cachedCellPixelSizeValue() else { return nil }
            let dimensions = (cols: source.cols, rows: source.rows)
            let h = cellSize.height * dimensions.rows
            let w = cellSize.width * dimensions.cols
            return source.cc.CSI + "4;\(h);\(w)t".utf8
        case .reportSizeOfScreenInPixels:
            return nil
        case .reportTextAreaCharacters:
            // The base implementation is good enough
            return nil
        case .reportWindowTitle:
            return nil
        case .reportTerminalWindowPixelDimension:
            return nil
        }
    }
    
    public func iTermContent (source: Terminal, content: ArraySlice<UInt8>) {
        let capturedContent = Array(content)
        onMain { [weak self] in
            guard let self else { return }
            self.terminalDelegate?.iTermContent(source: self, content: capturedContent[...])
        }
    }
    
    public func clipboardCopy(source: Terminal, content: Data) {
        let capturedContent = content
        onMain { [weak self] in
            guard let self else { return }
            self.terminalDelegate?.clipboardCopy(source: self, content: capturedContent)
        }
    }
    
    public func clipboardRead(source: Terminal) -> Data? {
        if Thread.isMainThread && !source.terminalLock.isLockedByCurrentThread {
            return terminalDelegate?.clipboardRead(source: self)
        }

        // Avoid main.sync here: OSC 52 can query the clipboard while the main
        // thread is parsing with the terminal lock held, which would deadlock.
        let selectionChars = "c"
        DispatchQueue.main.async { [weak self] in
            guard let self, let content = self.terminalDelegate?.clipboardRead(source: self) else {
                return
            }
            let base64 = content.base64EncodedString()
            let reply = Array("\u{1b}]52;\(selectionChars);\(base64)\u{1b}\\".utf8)
            self.send(data: reply[...])
        }
        return nil
    }
}


extension TerminalView {
    /// Opens an explicit URL or an implicit filesystem path with its default handler.
    public static func openDefaultLink (_ link: String)
    {
        guard let url = defaultLinkURL(link) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Converts a link to the URL that the default handler must open.
    static func defaultLinkURL (_ link: String, fileManager: FileManager = .default) -> URL?
    {
        if let url = URL(string: link), url.scheme != nil {
            return url
        }

        let path = NSString(string: link).expandingTildeInPath
        if fileManager.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        // Implicit link detection preserves source locations such as
        // "file.swift:12" and "file.swift:12:4". Check the filesystem path
        // without that suffix if the complete string is not an existing file.
        guard let locationRange = path.range(
            of: #":[0-9]+(?::[0-9]+)?$"#,
            options: .regularExpression
        ) else {
            return nil
        }
        let pathWithoutLocation = String(path[..<locationRange.lowerBound])
        guard fileManager.fileExists(atPath: pathWithoutLocation) else {
            return nil
        }
        return URL(fileURLWithPath: pathWithoutLocation)
    }
}


// Default implementations for TerminalViewDelegate

extension TerminalViewDelegate {
    /**
     * Opens the link with the default handler for its scheme
     */
    func openLink (_ link: String)
    {
        TerminalView.openDefaultLink(link)
    }

    public func requestOpenLink (source: TerminalView, link: String, params: [String:String])
    {
        openLink (link)
    }

    public func bell (source: TerminalView)
    {
        NSSound.beep()
    }
    
    public func iTermContent (source: TerminalView, content: ArraySlice<UInt8>) {
    }
    
    public func clipboardCopy(source: TerminalView, content: Data) {
    }
    
    public func clipboardRead(source: TerminalView) -> Data? {
        return nil
    }
}

/// NSTextView subclass used for the dictation / IME marked-text overlay.
///
/// Fills its background only under the laid-out line fragments rather than
/// across the full frame. Line 1 already has an exclusion path covering the
/// portion occupied by pre-existing terminal text (e.g. the prompt), so this
/// drawing strategy leaves that area untouched while still covering wrapped
/// lines below.
final class DictationOverlayTextView: NSTextView {
    var overlayBackgroundColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawPerFragmentBackground(in: dirtyRect)
        super.draw(dirtyRect)
    }

    private func drawPerFragmentBackground(in dirtyRect: NSRect) {
        guard let layoutManager, let container = textContainer else { return }
        overlayBackgroundColor.setFill()
        let glyphRange = layoutManager.glyphRange(for: container)
        let origin = textContainerOrigin
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, _, _ in
            let r = fragmentRect.offsetBy(dx: origin.x, dy: origin.y)
            if r.intersects(dirtyRect) {
                r.fill()
            }
        }
    }
}
#endif
