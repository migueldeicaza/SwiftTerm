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
    public var glyphFallbackProvider: (any TerminalGlyphFallbackProvider)? { didSet { invalidateAll() } }

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
    }
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
        metalBufferingMode = .perRowPersistent
        antiAliasCustomBlockGlyphs = view.antiAliasCustomBlockGlyphs
        appearance = view.frameAppearance()
        customBlockGlyphs = view.customBlockGlyphs
        useBrightColors = view.useBrightColors
        bidiHostPolicy = .legacyLeftToRight
        glyphFallbackProvider = view.glyphFallbackProvider
    }
}

#endif
#endif // !SWIFTTERM_EMBEDDED
