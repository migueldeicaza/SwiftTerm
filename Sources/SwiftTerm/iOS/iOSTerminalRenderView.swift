//
//  iOSTerminalRenderView.swift
//  SwiftTerm
//
//  A view that draws terminal frames without running a terminal emulator.
//  The UIKit version of MacTerminalRenderView.swift.
//

#if !SWIFTTERM_EMBEDDED
#if os(iOS) || os(visionOS)
import UIKit
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
open class TerminalRenderView: UIView, CaretHost {
    /// The source of the frames that the view draws.
    ///
    /// The view keeps a weak reference. With no source (nil, or released),
    /// the view shows only the background color: no text, no images and no
    /// caret. A release is seen on the next frame tick, for example after
    /// ``requestRedraw()`` or a change of size or appearance.
    public weak var frameSource: TerminalExternalFrameSource? {
        didSet { invalidateAll() }
    }

    /// Called when the number of columns or rows that fit in the view changes.
    public var onGridSizeChange: ((_ columns: Int, _ rows: Int) -> Void)?

    // MARK: Appearance

    /// The font for the terminal text. Bold and italic variants come from it.
    public var font: UIFont {
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

    /// Draws the custom block and box glyphs with anti-aliasing instead of
    /// pixel-aligned edges; see ``TerminalView/antiAliasCustomBlockGlyphs``.
    public var antiAliasCustomBlockGlyphs: Bool = false { didSet { invalidateAll() } }
    /// Draws block elements (U+2580–U+259F) and box drawing characters
    /// (U+2500–U+257F) with custom code instead of the font, so that they
    /// join; see ``TerminalView/customBlockGlyphs``.
    public var customBlockGlyphs: Bool = true { didSet { invalidateAll() } }
    /// Shows bold text in the ANSI colors 0–7 with the bright colors 8–15;
    /// see ``TerminalView/useBrightColors``.
    public var useBrightColors: Bool = true { didSet { invalidateAll() } }
    /// Draws explicit bright ANSI indexes as base colors with a bold font
    /// while `useBrightColors` is false; see
    /// ``TerminalView/collapseBrightColorsToBase``.
    public var collapseBrightColorsToBase: Bool = true {
        didSet {
            guard collapseBrightColorsToBase != oldValue else { return }
            colorsChanged()
        }
    }
    /// The least contrast, as a WCAG ratio from 1 to 21, that text keeps
    /// against its background; see ``TerminalView/minimumContrastRatio``.
    public var minimumContrastRatio: CGFloat = 1 {
        didSet {
            guard minimumContrastRatio != oldValue else { return }
            colorsChanged()
        }
    }
    /// Supplies the symbol glyphs (for example Nerd Font icons) that the font
    /// does not have. Nil, the default, turns this off. See
    /// ``TerminalGlyphFallbackProvider``.
    public var glyphFallbackProvider: (any TerminalGlyphFallbackProvider)? { didSet { invalidateAll() } }
    /// Whether rows use the bidi state that the terminal set on them, as in
    /// `TerminalView`. `.legacyLeftToRight` draws every row in logical order.
    public var bidiHostPolicy: BidiHostPolicy = .respectTerminal { didSet { invalidateAll() } }
    /// How the Metal renderer builds its GPU buffers, as in `TerminalView`.
    public var metalBufferingMode: MetalBufferingMode = .perRowPersistent { didSet { invalidateAll() } }

    /// The default foreground color: the color of text with no explicit color.
    public var nativeForegroundColor: UIColor = .label { didSet { colorsChanged() } }
    /// The default background color. The view fills its background with it.
    public var nativeBackgroundColor: UIColor = .systemBackground { didSet { colorsChanged() } }
    /// The background color of selected text.
    public var selectedTextBackgroundColor = UIColor(red: 0, green: 166.0 / 255.0, blue: 178.0 / 255.0, alpha: 1.0) {
        didSet { colorsChanged() }
    }
    /// The color of selected text.
    public var selectedTextForegroundColor: UIColor = .black { didSet { colorsChanged() } }
    /// The color of the selection handles that the Core Graphics renderer
    /// draws at the ends of the frame's selection, as in `TerminalView`.
    public var selectionHandleColor: UIColor = .systemBlue { didSet { invalidateAll() } }
    /// The caret color; nil uses the foreground color.
    public var caretColor: UIColor? { didSet { colorsChanged() } }
    /// The color of the text under a block caret; nil uses the background color.
    public var caretTextColor: UIColor? { didSet { colorsChanged() } }
    /// The color of highlighted links, as in `TerminalView.linkColor`; nil
    /// keeps the colors of the links.
    public var linkColor: UIColor? { didSet { colorsChanged() } }
    /// The underline color of highlighted links, as in
    /// `TerminalView.linkUnderlineColor`; nil keeps the underline color.
    public var linkUnderlineColor: UIColor? { didSet { colorsChanged() } }

    /// Whether the view shows a focused (filled, blinking) caret.
    ///
    /// The view does not take the first responder itself; a host that
    /// handles input sets this when it gains or loses the keyboard.
    public var hasFocus: Bool = false {
        didSet {
            caretView?.updateCursorStyle()
            invalidateAll()
        }
    }

    // MARK: Geometry

    /// The size of one cell, in points.
    public var cellSize: CGSize { cellDimension }

    /// The number of columns and rows that fit in `size`.
    public func gridSize (for size: CGSize) -> (columns: Int, rows: Int) {
        guard cellDimension.width > 0, cellDimension.height > 0 else { return (0, 0) }
        return (max(1, Int(size.width / cellDimension.width)),
                max(1, Int(size.height / cellDimension.height)))
    }

    /// The number of columns and rows that fit in the view.
    public var gridSize: (columns: Int, rows: Int) { gridSize(for: bounds.size) }

    /// The cell under `point` (in view coordinates). Row 0 is the top row.
    public func cell (at point: CGPoint) -> (column: Int, row: Int) {
        guard cellDimension.width > 0, cellDimension.height > 0 else { return (0, 0) }
        let column = Int(max(0, point.x) / cellDimension.width)
        let row = Int(max(0, point.y) / cellDimension.height)
        return (column, row)
    }

    /// The rectangle of a run of cells. Row 0 is the top row.
    public func rect (column: Int, row: Int, width: Int = 1) -> CGRect {
        CGRect(x: CGFloat(column) * cellDimension.width,
               y: CGFloat(row) * cellDimension.height,
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

    var cellDimension: TerminalView.CellDimension
    var fontSet: TerminalView.FontSet
    let coreGraphicsRenderCache = CoreGraphicsRenderCache()
    let textBuilder = SnapshotTextBuilder()
    nonisolated let kittyPlacementImageCache = Locked([KittyPlacementImageKey: TTImage]())

    var effectiveNativeForegroundColor: TTColor { nativeForegroundColor }

    func backingScaleFactor () -> CGFloat {
        // As in the iOS TerminalView, so that both views snap cells alike.
#if os(visionOS)
        1.0
#else
        UIScreen.main.scale
#endif
    }

    func getImageScale () -> CGFloat {
        window?.contentScaleFactor ?? 1
    }

    func captureFrameViewState () -> FrameViewState? {
        FrameViewState(renderView: self)
    }

    func withSnapshotForDrawing (viewState: FrameViewState,
                                 _ body: (TerminalSnapshot, SnapshotRenderContext) -> Void) {
        owner.withSnapshotForDrawing(viewState: viewState, body)
    }

    func didDrawCoreGraphicsFrame () {}

    func firstPaintedRow (snapshot: TerminalSnapshot) -> Int {
        // The view shows the frame's rows only, from its top line.
        snapshot.yDisp
    }

    // MARK: Internals

    private let owner = ExternalRenderOwner()
    private let frameDriver: FrameDriver
    private nonisolated let frameSignal: FrameDriverSignal
    private var caretView: CaretView!
    private var lastGrid: (columns: Int, rows: Int) = (0, 0)
    private var lastLayoutSize: CGSize = .zero
    private var cachedFonts: (source: UIFont, fonts: FrameFontSet)?
    private var cachedAppearance: (key: [UIColor], traits: UITraitCollection, value: FrameAppearance)?

    /// Creates a view with no frame source.
    ///
    /// - Parameters:
    ///   - frame: The frame of the view.
    ///   - font: The font of the terminal text. Nil uses the default font of
    ///     `TerminalView`.
    public init (frame: CGRect, font: UIFont? = nil) {
        fontSet = TerminalView.FontSet(font: font ?? TerminalView.FontSet.defaultFont)
        cellDimension = CGSize(width: 1, height: 1)
        let driver = FrameDriver()
        frameDriver = driver
        frameSignal = driver.signal
        super.init(frame: frame)
        // draw(_:) clears what it repaints; the layer supplies the background.
        isOpaque = false
        contentMode = .redraw
        cellDimension = computeCellDimension()
        caretView = CaretView(frame: CGRect(origin: .zero, size: cellDimension),
                              cursorStyle: .blinkBlock, terminal: self)
        driver.onTick = { [weak self] in self?.frameTick() }
        driver.setWindowAttachedOnMain(window != nil)
        updateLayerBackground()
    }

    public required init? (coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        frameDriver.invalidate()
        progressTimer?.invalidate()
    }

    open override func didMoveToWindow () {
        super.didMoveToWindow()
        frameDriver.setWindowAttachedOnMain(window != nil)
        if window != nil {
            updateMetrics()
        }
    }

    open override func traitCollectionDidChange (_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // Dynamic colors (.label, .systemBackground) resolve per appearance.
        colorsChanged()
    }

    open override func layoutSubviews () {
        super.layoutSubviews()
        guard bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
        reportGridSizeIfChanged()
        updateProgressBarFrame()
        setNeedsDisplay()
        invalidateAll()
    }

    open override func draw (_ dirtyRect: CGRect) {
#if canImport(MetalKit)
        // The Metal surface covers the view, except while it is hidden
        // because there is no frame.
        if metalRenderer != nil, metalSurface?.isHidden == false { return }
#endif
        guard let context = UIGraphicsGetCurrentContext() else { return }
        // Clear old glyphs; the layer supplies the background.
        context.clear(dirtyRect)
        // The painter and CoreText expect the AppKit coordinate system.
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -frame.height)
        drawTerminalContents(dirtyRect: dirtyRect, context: context, bufferOffset: owner.snapshot.yDisp)
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
        layer.backgroundColor = nativeBackgroundColor.resolvedColor(with: traitCollection).cgColor
#if canImport(MetalKit)
        metalSurface?.metalLayer.isOpaque = nativeBackgroundColor.cgColor.alpha >= 1
#endif
    }

    private func computeCellDimension () -> TerminalView.CellDimension {
        // As in TerminalView.computeFontDimensions on iOS.
        let normal = fontSet.normal
        let height = ceil((CTFontGetAscent(normal) + CTFontGetDescent(normal) + CTFontGetLeading(normal)) * lineSpacing)
        let width = "W".size(withAttributes: [.font: normal]).width
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

    func frameFonts () -> FrameFontSet {
        if let cachedFonts, cachedFonts.source.isEqual(fontSet.normal) {
            return cachedFonts.fonts
        }
        let fonts = FrameFontSet(fontSet)
        cachedFonts = (fontSet.normal, fonts)
        return fonts
    }

    func frameAppearance () -> FrameAppearance {
        let caret = caretColor ?? nativeForegroundColor
        let caretText = caretTextColor ?? nativeBackgroundColor
        let key = [nativeForegroundColor, nativeBackgroundColor, selectedTextBackgroundColor,
                   selectedTextForegroundColor, caret, caretText]
        let traits = traitCollection
        if let cachedAppearance,
           !cachedAppearance.traits.hasDifferentColorAppearance(comparedTo: traits),
           zip(cachedAppearance.key, key).allSatisfy({ $0.0.isEqual($0.1) }) {
            return cachedAppearance.value
        }
        let value = FrameAppearance(
            effectiveForegroundColor: FrameColor(key[0], traitCollection: traits),
            effectiveBackgroundColor: FrameColor(key[1], traitCollection: traits),
            selectedTextBackgroundColor: FrameColor(key[2], traitCollection: traits),
            selectedTextForegroundColor: FrameColor(key[3], traitCollection: traits),
            caretColor: FrameColor(key[4], traitCollection: traits),
            caretTextColor: FrameColor(key[5], traitCollection: traits),
            linkColor: linkColor.map { FrameColor($0, traitCollection: traits) },
            linkUnderlineColor: linkUnderlineColor.map { FrameColor($0, traitCollection: traits) })
        cachedAppearance = (key, traits, value)
        return value
    }

    func frameTick () {
        guard let source = frameSource else {
            showEmpty()
            return
        }
        guard let viewState = captureFrameViewState(),
              let prepared = owner.prepare(source: source, viewState: viewState) else { return }
#if canImport(MetalKit)
        if let metalRenderer {
            metalSurface?.isHidden = false
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
            setNeedsDisplay()
        case .rows(let rows):
            for row in rows {
                setNeedsDisplay(rect(column: 0, row: row, width: max(prepared.columns, gridSize.columns)))
            }
        }
        updateCaret(prepared.cursor, rows: prepared.rows)
    }

    /// The state with no source: the background color only.
    private func showEmpty () {
        var changed = owner.hasSnapshot
        owner.clear()
        caretView?.removeFromSuperview()
#if canImport(MetalKit)
        // The renderer cannot draw without a snapshot, so hide its surface
        // and let draw(_:) clear to the background.
        if let metalSurface, !metalSurface.isHidden {
            metalSurface.isHidden = true
            changed = true
        }
#endif
        if changed { setNeedsDisplay() }
    }

    private func updateCaret (_ cursor: SnapshotCursor?, rows: Int) {
        guard let caretView else { return }
        guard let cursor, !cursor.hidden, cursor.screenRow >= 0, cursor.screenRow < rows else {
            caretView.removeFromSuperview()
            return
        }
        if caretView.superview !== self {
            // Below the progress bar.
            if let progressBarView, progressBarView.superview === self {
                insertSubview(caretView, belowSubview: progressBarView)
            } else {
                addSubview(caretView)
            }
        }
        if caretView.style != owner.snapshot.cursorStyle {
            caretView.style = owner.snapshot.cursorStyle
        }
        let doubled: CGFloat = cursor.renderMode == .single ? 1 : 2
        let origin = CGPoint(x: cellDimension.width * doubled * CGFloat(cursor.visualCol),
                             y: cellDimension.height * CGFloat(cursor.screenRow))
        caretView.frame = CGRect(origin: origin,
                                 size: CGSize(width: cellDimension.width * doubled * CGFloat(cursor.columnWidth),
                                              height: cellDimension.height))
        caretView.powerlineRenderMode = cursor.renderMode
        caretView.setText(cursor.renderData)
    }

    /// Restarts the caret blink so the caret stays visible while the user types.
    public func resetCaretBlink () {
        caretView?.resetBlinkAfterInput()
#if canImport(MetalKit)
        metalRenderer?.resetCursorBlinkAfterInput()
#endif
    }

    // MARK: Progress (OSC 9;4)

    private var progressBarView: TerminalProgressBarView?
    private var progressTimer: Timer?

    /// The progress report that the view shows, or nil when it shows none.
    public private(set) var progressReport: Terminal.ProgressReport?

    /// Shows a progress report (OSC 9;4) as a bar at the top of the view, as
    /// `TerminalView` does. The bar goes away on a `.remove` report, or
    /// `duration` seconds after the last report (15, as in `TerminalView`).
    /// A host that shows a report that came earlier gives the time that is
    /// left.
    public func showProgress (_ report: Terminal.ProgressReport, duration: TimeInterval = 15) {
        guard report.state != .remove, duration > 0 else {
            clearProgress()
            return
        }
        let bar: TerminalProgressBarView
        if let progressBarView {
            bar = progressBarView
        } else {
            bar = TerminalProgressBarView(frame: .zero)
            progressBarView = bar
        }
        // Above the Metal surface and the caret.
        if subviews.last !== bar {
            addSubview(bar)
        }
        updateProgressBarFrame()
        progressReport = report
        bar.apply(state: report.state, progress: report.progress)
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearProgress() }
        }
    }

    private func clearProgress () {
        progressTimer?.invalidate()
        progressTimer = nil
        progressReport = nil
        progressBarView?.apply(state: .remove, progress: nil)
    }

    private func updateProgressBarFrame () {
        guard let progressBarView else { return }
        progressBarView.frame = CGRect(x: 0, y: 0, width: bounds.width,
                                       height: TerminalProgressBarView.preferredHeight)
    }

#if canImport(MetalKit)
    // MARK: Metal

    private var metalSurface: TerminalMetalLayerView?
    private var metalRenderer: MetalTerminalRenderer?

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
        let surface = TerminalMetalLayerView(frame: bounds)
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.isUserInteractionEnabled = false
        surface.renderDevice = device
        surface.metalLayer.isOpaque = nativeBackgroundColor.cgColor.alpha >= 1
        surface.renderContentsScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : backingScaleFactor()
        let renderer = try MetalTerminalRenderer(target: surface)
        let signal = frameSignal
        renderer.requestRedraw = { signal.markDirty() }
        surface.onNeedsDisplay = { signal.markDirty() }
        // Below every other subview, so that the host's overlays stay on top.
        insertSubview(surface, at: 0)
        metalSurface = surface
        metalRenderer = renderer
        caretView?.disableAnimations()
        caretView?.isHidden = true
        invalidateAll()
    }

    private func removeMetal () {
        _ = metalRenderer?.waitForIdle()
        metalSurface?.onNeedsDisplay = nil
        metalSurface?.removeFromSuperview()
        metalSurface = nil
        metalRenderer = nil
        caretView?.isHidden = false
        caretView?.updateCursorStyle()
        setNeedsDisplay()
        invalidateAll()
    }

    private func renderMetalFrame (_ renderer: MetalTerminalRenderer, viewState: FrameViewState) {
        owner.withSnapshotForDrawing(viewState: viewState) { snapshot, context in
            renderer.prepareSnapshotForImmediateDraw(snapshot: snapshot, context: context)
            renderer.render()
            renderer.discardPreparedSnapshot()
        }
    }
#endif
}

#endif
#endif // !SWIFTTERM_EMBEDDED
