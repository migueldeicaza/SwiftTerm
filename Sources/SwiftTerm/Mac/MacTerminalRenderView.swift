//
//  MacTerminalRenderView.swift
//  SwiftTerm
//
//  A view that draws terminal frames without running a terminal emulator.
//

#if !SWIFTTERM_EMBEDDED
#if os(macOS)
import AppKit
import CoreText
#if canImport(MetalKit)
import Metal
#endif

/// Draws the frames of a ``TerminalExternalFrameSource`` with the same Core
/// Graphics renderer that `TerminalView` uses.
///
/// The view does no terminal emulation and handles no input. Use it when the
/// terminal runs somewhere else (another process, another machine) and only
/// its visible rows are available here. A subclass or the host adds input,
/// selection and scrolling.
///
/// Call ``requestRedraw()`` when the source has a new frame. The view asks the
/// source for the frame on its next display-link tick.
///
/// ``setUseMetal(_:)`` switches to SwiftTerm's Metal renderer, as in
/// `TerminalView`.
@MainActor
open class TerminalRenderView: NSView, CaretHost {
    /// The source of the frames that the view draws.
    public weak var frameSource: TerminalExternalFrameSource? {
        didSet { invalidateAll() }
    }

    /// Called when the number of columns or rows that fit in the view changes.
    public var onGridSizeChange: ((_ columns: Int, _ rows: Int) -> Void)?

    // MARK: Appearance

    /// The font for the terminal text. Bold and italic variants come from it.
    public var font: NSFont {
        get { fontSet.normal }
        set {
            fontSet = TerminalView.FontSet(font: newValue)
            updateMetrics()
        }
    }

    /// The factor applied to the font's natural line height.
    public var lineSpacing: CGFloat = 1.0 {
        didSet { updateMetrics() }
    }

    public var fontSmoothing: Bool = true { didSet { invalidateAll() } }
    public var antiAliasCustomBlockGlyphs: Bool = false { didSet { invalidateAll() } }
    public var customBlockGlyphs: Bool = true { didSet { invalidateAll() } }
    public var useBrightColors: Bool = true { didSet { invalidateAll() } }
    /// The least contrast, as a WCAG ratio from 1 to 21, that text keeps
    /// against its background; see ``TerminalView/minimumContrastRatio``.
    public var minimumContrastRatio: CGFloat = 1 {
        didSet {
            guard minimumContrastRatio != oldValue else { return }
            colorsChanged()
        }
    }
    public var glyphFallbackProvider: (any TerminalGlyphFallbackProvider)? { didSet { invalidateAll() } }
    /// Whether rows use the bidi state that the terminal set on them, as in
    /// `TerminalView`. `.legacyLeftToRight` draws every row in logical order.
    public var bidiHostPolicy: BidiHostPolicy = .respectTerminal { didSet { invalidateAll() } }
    /// How the Metal renderer builds its GPU buffers, as in `TerminalView`.
    public var metalBufferingMode: MetalBufferingMode = .perRowPersistent { didSet { invalidateAll() } }

    public var nativeForegroundColor: NSColor = .textColor { didSet { colorsChanged() } }
    public var nativeBackgroundColor: NSColor = .textBackgroundColor { didSet { colorsChanged() } }
    public var selectedTextBackgroundColor = NSColor(srgbRed: 0, green: 166.0 / 255.0, blue: 178.0 / 255.0, alpha: 1.0) {
        didSet { colorsChanged() }
    }
    public var selectedTextForegroundColor: NSColor = .black { didSet { colorsChanged() } }
    /// The caret color; nil uses the foreground color.
    public var caretColor: NSColor? { didSet { colorsChanged() } }
    /// The color of the text under a block caret; nil uses the background color.
    public var caretTextColor: NSColor? { didSet { colorsChanged() } }

    /// Whether the view shows a focused (filled, blinking) caret.
    public var hasFocus: Bool = false {
        didSet {
            caretView?.focused = hasFocus
            invalidateAll()
        }
    }

    // MARK: Geometry

    /// The size of one cell, in points.
    public var cellSize: CGSize { cellDimension ?? .zero }

    /// The number of columns and rows that fit in `size`.
    public func gridSize (for size: CGSize) -> (columns: Int, rows: Int) {
        guard let cellDimension, cellDimension.width > 0, cellDimension.height > 0 else { return (0, 0) }
        return (max(1, Int(size.width / cellDimension.width)),
                max(1, Int(size.height / cellDimension.height)))
    }

    /// The number of columns and rows that fit in the view.
    public var gridSize: (columns: Int, rows: Int) { gridSize(for: bounds.size) }

    /// The cell under `point` (in view coordinates). Row 0 is the top row.
    public func cell (at point: CGPoint) -> (column: Int, row: Int) {
        guard let cellDimension, cellDimension.width > 0, cellDimension.height > 0 else { return (0, 0) }
        let column = Int(max(0, point.x) / cellDimension.width)
        let row = Int(max(0, bounds.height - point.y) / cellDimension.height)
        return (column, row)
    }

    /// The rectangle of a run of cells. Row 0 is the top row.
    public func rect (column: Int, row: Int, width: Int = 1) -> CGRect {
        guard let cellDimension else { return .zero }
        return CGRect(x: CGFloat(column) * cellDimension.width,
                      y: bounds.height - CGFloat(row + 1) * cellDimension.height,
                      width: CGFloat(width) * cellDimension.width,
                      height: cellDimension.height)
    }

    /// The logical column (the column in the line's cells) shown at a visual
    /// column of a screen row. Rows that bidi reorders map differently;
    /// other rows map each column to itself. Use it for hit testing.
    public func logicalColumn (forVisualColumn column: Int, row: Int) -> Int {
        guard let layout = owner.layout(screenRow: row),
              column >= 0, column < layout.visualToLogicalCol.count else { return column }
        return layout.visualToLogicalCol[column]
    }

    /// The visual column where a logical column of a screen row is shown.
    public func visualColumn (forLogicalColumn column: Int, row: Int) -> Int {
        guard let layout = owner.layout(screenRow: row),
              column >= 0, column < layout.logicalToVisualCol.count else { return column }
        return layout.logicalToVisualCol[column]
    }

    /// The base direction of the paragraph of a screen row, as drawn.
    public func baseDirection (row: Int) -> BidiDirection {
        owner.layout(screenRow: row)?.baseDirection ?? .leftToRight
    }

    /// The caret frame in view coordinates.
    public var caretFrame: CGRect { caretView?.frame ?? .zero }

    /// Asks for a new frame from the source. Safe from any thread.
    public nonisolated func requestRedraw () {
        frameSignal.markDirty()
    }

    // MARK: CoreGraphicsPaintHost

    var cellDimension: TerminalView.CellDimension!
    var fontSet: TerminalView.FontSet
    let coreGraphicsRenderCache = CoreGraphicsRenderCache()
    let textBuilder = SnapshotTextBuilder()
    nonisolated let kittyPlacementImageCache = Locked([KittyPlacementImageKey: TTImage]())

    var effectiveNativeForegroundColor: TTColor { nativeForegroundColor }

    func backingScaleFactor () -> CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    func getImageScale () -> CGFloat {
        window?.backingScaleFactor ?? 1
    }

    func captureFrameViewState () -> FrameViewState? {
        guard cellDimension != nil else { return nil }
        return FrameViewState(renderView: self)
    }

    func withSnapshotForDrawing (viewState: FrameViewState,
                                 _ body: (TerminalSnapshot, SnapshotRenderContext) -> Void) {
        owner.withSnapshotForDrawing(viewState: viewState, body)
    }

    func didDrawCoreGraphicsFrame () {}

    // MARK: Internals

    private let owner = ExternalRenderOwner()
    private let frameDriver: FrameDriver
    private nonisolated let frameSignal: FrameDriverSignal
    private var caretView: CaretView!
    private var lastGrid: (columns: Int, rows: Int) = (0, 0)
    private var cachedFonts: (source: NSFont, fonts: FrameFontSet)?
    private var cachedAppearance: (key: [NSColor], name: NSAppearance.Name, value: FrameAppearance)?

    public init (frame: CGRect, font: NSFont? = nil) {
        fontSet = TerminalView.FontSet(font: font ?? TerminalView.FontSet.defaultFont)
        let driver = FrameDriver()
        frameDriver = driver
        frameSignal = driver.signal
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        cellDimension = computeCellDimension()
        caretView = CaretView(frame: CGRect(origin: .zero, size: cellDimension),
                              cursorStyle: .blinkBlock, terminal: self)
        caretView.focused = hasFocus
        driver.onTick = { [weak self] in self?.frameTick() }
        updateLayerBackground()
    }

    public required init? (coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        frameDriver.invalidate()
    }

    open override var isFlipped: Bool { false }

    open override func viewDidMoveToWindow () {
        super.viewDidMoveToWindow()
        frameDriver.bind(to: window == nil ? nil : self)
        if window != nil {
            updateMetrics()
        }
#if canImport(MetalKit)
        // A CAMetalLayer does not follow its view into another window (see
        // TerminalView.rebindMetalRendererToWindow), so build a new surface.
        if metalRenderer != nil, let window, window !== metalBoundWindow {
            removeMetal()
            try? installMetal()
        }
#endif
    }

    open override func viewDidChangeBackingProperties () {
        super.viewDidChangeBackingProperties()
        updateMetrics()
    }

    open override func viewDidChangeEffectiveAppearance () {
        super.viewDidChangeEffectiveAppearance()
        colorsChanged()
    }

    open override func setFrameSize (_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportGridSizeIfChanged()
        invalidateAll()
    }

    open override func draw (_ dirtyRect: NSRect) {
#if canImport(MetalKit)
        // The Metal surface covers the view.
        if metalRenderer != nil { return }
#endif
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Layer-backed drawing can pass an unbounded rectangle.
        let clipped = dirtyRect.intersection(bounds)
        let rect = clipped.isNull || clipped.isInfinite ? bounds : clipped
        nativeBackgroundColor.setFill()
        context.fill(rect)
        drawTerminalContents(dirtyRect: rect, context: context, bufferOffset: 0)
    }

    private func invalidateAll () {
        owner.invalidate()
        frameDriver.markDirty()
    }

    private func colorsChanged () {
        cachedAppearance = nil
        coreGraphicsRenderCache.clearColors()
        updateLayerBackground()
        invalidateAll()
    }

    private func updateLayerBackground () {
        layer?.backgroundColor = nativeBackgroundColor.cgColor
#if canImport(MetalKit)
        metalSurface?.metalLayer.isOpaque = nativeBackgroundColor.alphaComponent >= 1
#endif
    }

    private func computeCellDimension () -> TerminalView.CellDimension {
        let normal = fontSet.normal
        let height = ceil((CTFontGetAscent(normal) + CTFontGetDescent(normal) + CTFontGetLeading(normal)) * lineSpacing)
        let glyph = normal.glyph(withName: "W")
        let width = normal.advancement(forGlyph: glyph).width
        let scale = backingScaleFactor()
        let snappedWidth = (width * scale).rounded() / scale
        let snappedHeight = ceil(height * scale) / scale
        return CGSize(width: max(1, snappedWidth), height: max(min(snappedHeight, 8192), 1))
    }

    private func updateMetrics () {
        cachedFonts = nil
        cellDimension = computeCellDimension()
        caretView?.frame.size = cellDimension
        caretView?.updateCursorStyle()
        reportGridSizeIfChanged()
        invalidateAll()
    }

    private func reportGridSizeIfChanged () {
        let grid = gridSize
        guard grid.columns != lastGrid.columns || grid.rows != lastGrid.rows else { return }
        lastGrid = grid
        onGridSizeChange?(grid.columns, grid.rows)
    }

    fileprivate func frameFonts () -> FrameFontSet {
        if let cachedFonts, cachedFonts.source.isEqual(fontSet.normal) {
            return cachedFonts.fonts
        }
        let fonts = FrameFontSet(fontSet)
        cachedFonts = (fontSet.normal, fonts)
        return fonts
    }

    fileprivate func frameAppearance () -> FrameAppearance {
        let caret = caretColor ?? nativeForegroundColor
        let caretText = caretTextColor ?? nativeBackgroundColor
        let key = [nativeForegroundColor, nativeBackgroundColor, selectedTextBackgroundColor,
                   selectedTextForegroundColor, caret, caretText]
        let name = effectiveAppearance.name
        if let cachedAppearance, cachedAppearance.name == name,
           zip(cachedAppearance.key, key).allSatisfy({ $0.0.isEqual($0.1) }) {
            return cachedAppearance.value
        }
        let appearance = effectiveAppearance
        let value = FrameAppearance(
            effectiveForegroundColor: FrameColor(key[0], appearance: appearance),
            effectiveBackgroundColor: FrameColor(key[1], appearance: appearance),
            selectedTextBackgroundColor: FrameColor(key[2], appearance: appearance),
            selectedTextForegroundColor: FrameColor(key[3], appearance: appearance),
            caretColor: FrameColor(key[4], appearance: appearance),
            caretTextColor: FrameColor(key[5], appearance: appearance))
        cachedAppearance = (key, name, value)
        return value
    }

    func frameTick () {
        guard let source = frameSource, let viewState = captureFrameViewState(),
              let prepared = owner.prepare(source: source, viewState: viewState) else { return }
#if canImport(MetalKit)
        if let metalRenderer {
            // The renderer draws the whole frame, cursor included. It keeps
            // the rows it built, so an unchanged row costs little.
            renderMetalFrame(metalRenderer, viewState: viewState)
            return
        }
#endif
        switch prepared.damage {
        case .none:
            break
        case .all:
            setNeedsDisplay(bounds)
        case .rows(let rows):
            for row in rows {
                setNeedsDisplay(rect(column: 0, row: row, width: max(prepared.columns, gridSize.columns)))
            }
        }
        updateCaret(prepared.cursor, rows: prepared.rows)
    }

    private func updateCaret (_ cursor: SnapshotCursor?, rows: Int) {
        guard let caretView else { return }
        guard let cursor, !cursor.hidden, cursor.screenRow >= 0, cursor.screenRow < rows else {
            caretView.removeFromSuperview()
            return
        }
        if caretView.superview !== self { addSubview(caretView) }
        if caretView.style != owner.snapshot.cursorStyle {
            caretView.style = owner.snapshot.cursorStyle
        }
        let doubled: CGFloat = cursor.renderMode == .single ? 1 : 2
        let origin = CGPoint(x: cellDimension.width * doubled * CGFloat(cursor.visualCol),
                             y: bounds.height - cellDimension.height * CGFloat(cursor.screenRow + 1))
        caretView.frame = CGRect(origin: origin,
                                 size: CGSize(width: cellDimension.width * doubled * CGFloat(cursor.columnWidth),
                                              height: cellDimension.height))
        caretView.setText(cursor.renderData)
    }

    /// Restarts the caret blink so the caret stays visible while the user types.
    public func resetCaretBlink () {
        caretView?.resetBlinkAfterInput()
#if canImport(MetalKit)
        metalRenderer?.resetCursorBlinkAfterInput()
#endif
    }

#if canImport(MetalKit)
    // MARK: Metal

    private var metalSurface: TerminalMetalLayerView?
    private var metalRenderer: MetalTerminalRenderer?
    private weak var metalBoundWindow: NSWindow?

    /// Whether the view draws with the Metal renderer.
    public var isUsingMetalRenderer: Bool { metalRenderer != nil }

    /// Draws with SwiftTerm's Metal renderer instead of Core Graphics, as
    /// `TerminalView.setUseMetal(_:)` does. The renderer draws the cursor too.
    ///
    /// Frames are drawn on the main thread, on the frame-driver tick: an
    /// external frame is one viewport, so there is no render loop.
    ///
    /// - Throws: ``MetalError`` when there is no Metal device or the renderer
    ///   cannot be built. The view then stays with Core Graphics.
    public func setUseMetal (_ enabled: Bool) throws {
        guard enabled != isUsingMetalRenderer else { return }
        if enabled {
            try installMetal()
        } else {
            removeMetal()
        }
    }

    private func installMetal () throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw MetalError.deviceUnavailable }
        // The same surface configuration as TerminalView.makeMetalView.
        let surface = TerminalMetalLayerView(frame: bounds)
        surface.autoresizingMask = [.width, .height]
        surface.renderDevice = device
        surface.metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        surface.metalLayer.isOpaque = nativeBackgroundColor.alphaComponent >= 1
        surface.renderContentsScale = backingScaleFactor()
        let renderer = try MetalTerminalRenderer(target: surface)
        let signal = frameSignal
        renderer.requestRedraw = { signal.markDirty() }
        surface.onNeedsDisplay = { signal.markDirty() }
        // Below every other subview, so that the host's overlays stay on top.
        addSubview(surface, positioned: .below, relativeTo: nil)
        metalSurface = surface
        metalRenderer = renderer
        metalBoundWindow = window
        caretView?.isHidden = true
        invalidateAll()
    }

    private func removeMetal () {
        _ = metalRenderer?.waitForIdle()
        metalSurface?.onNeedsDisplay = nil
        metalSurface?.removeFromSuperview()
        metalSurface = nil
        metalRenderer = nil
        metalBoundWindow = nil
        caretView?.isHidden = false
        needsDisplay = true
        invalidateAll()
    }

    private func renderMetalFrame (_ renderer: MetalTerminalRenderer, viewState: FrameViewState) {
        owner.withSnapshotForDrawing(viewState: viewState) { snapshot, context in
            renderer.prepareSnapshotForImmediateDraw(snapshot: snapshot, context: context)
            renderer.render()
            renderer.discardPreparedSnapshot()
        }
    }

    /// Asks the source for the current frame and renders it into `target`.
    /// For tests that compare the pixels with `TerminalView`.
    func renderSnapshotForMetal (renderer: MetalTerminalRenderer,
                                 target: any MetalRenderTarget) -> Bool {
        guard let source = frameSource, let viewState = captureFrameViewState(),
              owner.prepare(source: source, viewState: viewState) != nil else { return false }
        var rendered = false
        owner.withSnapshotForDrawing(viewState: viewState) { snapshot, context in
            renderer.prepareSnapshotForImmediateDraw(snapshot: snapshot, context: context)
            defer { renderer.discardPreparedSnapshot() }
            if target.needsExternalDrawCall {
                renderer.render()
            } else if let frame = target.acquireDrawableFrame() {
                renderer.render(frame: frame)
            } else {
                return
            }
            rendered = true
        }
        return rendered
    }
#endif
}

extension FrameViewState {
    @MainActor
    init (renderView view: TerminalRenderView) {
        linkHighlightRange = nil
        linkHighlightMode = .hover
        commandActive = false
        textBlinkVisible = true
        notifyUpdateChanges = false
        fonts = view.frameFonts()
        cellDimension = view.cellDimension
        viewBounds = view.bounds
        viewFrameHeight = view.frame.height
        let scale = view.backingScaleFactor()
        renderingScale = scale
        fontSmoothing = view.fontSmoothing
        cursorHasFocus = view.hasFocus
        cellPixelWidth = Int((cellDimension.width * scale).rounded())
        cellPixelHeight = Int((cellDimension.height * scale).rounded())
        imageScale = view.getImageScale()
        metalBufferingMode = view.metalBufferingMode
        antiAliasCustomBlockGlyphs = view.antiAliasCustomBlockGlyphs
        appearance = view.frameAppearance()
        customBlockGlyphs = view.customBlockGlyphs
        useBrightColors = view.useBrightColors
        minimumContrastRatio = view.minimumContrastRatio
        bidiHostPolicy = view.bidiHostPolicy
        glyphFallbackProvider = view.glyphFallbackProvider
    }
}

#endif
#endif // !SWIFTTERM_EMBEDDED
