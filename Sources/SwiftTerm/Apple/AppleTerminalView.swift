//
//  AppleTerminalView.swift
//
// Shared code for UIKit and Appkit for the terminal view
//
//  Created by Miguel de Icaza on 4/21/20.
//
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import CoreGraphics
import CoreText
#if canImport(MetalKit)
import MetalKit
#endif
#if canImport(ImageIO)
import ImageIO
#endif
import SwiftUI

let SwiftTermUnderlineStyleKey = NSAttributedString.Key("SwiftTermUnderlineStyle")
/// Carries a ``TerminalGlyphPlacementPolicy`` on runs whose font is a host
/// glyph fallback, so both draw paths can apply the placement to each glyph.
let SwiftTermGlyphPolicyKey = NSAttributedString.Key("SwiftTermGlyphPolicy")

#if os(iOS) || os(visionOS)
import UIKit
typealias TTColor = UIColor
typealias TTFont = UIFont
typealias TTRect = CGRect
typealias TTBezierPath = UIBezierPath
public typealias TTImage = UIImage
#endif

#if os(macOS)
import AppKit
typealias TTColor = NSColor
typealias TTFont = NSFont
typealias TTRect = CGRect
typealias TTBezierPath = NSBezierPath
public typealias TTImage = NSImage
#endif

/// Controls how links are discovered during pointer/hover tracking in terminal views.
public enum LinkReporting {
    /// Disable link tracking.
    case none
    /// Track only explicit hyperlinks (OSC 8 payloads).
    case explicit
    /// Track explicit hyperlinks first, then fall back to implicit URL detection.
    case implicit
}

/// Controls how links are highlighted and whether click/tap activation is allowed.
public enum LinkHighlightMode: Sendable {
    /// Underline only when hovering the matched link.
    case hover
    /// Underline only when hovering and the modifier key is pressed.
    case hoverWithModifier
    /// Always underline explicit links.
    case always
    /// Underline explicit links only while the modifier is pressed.
    case alwaysWithModifier
}

/// A platform font that can cross to the render owner.
///
/// This is the only unchecked field in the frame capture. Apple documents
/// `UIFont` as immutable and safe for use from multiple threads. `NSFont` is
/// also immutable, and Cocoa permits immutable objects to move between
/// threads. Copying here prevents a mutable subclass from entering the
/// wrapper. The wrapper exposes no mutation API.
struct ImmutableFontReference: @unchecked Sendable {
    private let storage: TTFont

    @MainActor
    init (_ font: TTFont) {
        storage = font.copy() as! TTFont
    }

    var value: TTFont { storage }
}

/// The four immutable fonts used by one frame.
struct FrameFontSet: Sendable {
    private let normalReference: ImmutableFontReference
    private let boldReference: ImmutableFontReference
    private let italicReference: ImmutableFontReference
    private let boldItalicReference: ImmutableFontReference

    @MainActor
    init (_ fonts: TerminalView.FontSet) {
        normalReference = ImmutableFontReference(fonts.normal)
        boldReference = ImmutableFontReference(fonts.bold)
        italicReference = ImmutableFontReference(fonts.italic)
        boldItalicReference = ImmutableFontReference(fonts.boldItalic)
    }

    var normal: TTFont { normalReference.value }
    var bold: TTFont { boldReference.value }
    var italic: TTFont { italicReference.value }
    var boldItalic: TTFont { boldItalicReference.value }

    func underlinePosition () -> CGFloat {
#if os(macOS)
        normal.underlinePosition
#else
        -1.2
#endif
    }
    func underlineThickness () -> CGFloat {
#if os(macOS)
        normal.underlineThickness
#else
        0.63
#endif
    }
}

/// An sRGB color captured on the main actor and rebuilt by the render owner.
struct FrameColor: Sendable, Hashable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    @MainActor
    init (_ color: TTColor, view: TerminalView) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
#if os(macOS)
        var converted: TTColor?
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            converted = color.usingColorSpace(.sRGB)
        }
        let captured: Bool
        if let converted {
            converted.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            captured = true
        } else {
            captured = false
        }
#else
        let resolved = color.resolvedColor(with: view.traitCollection)
        let captured = resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
#endif
        if !captured {
            // Pattern colors and colors in unsupported spaces use a stable
            // terminal-color fallback. Do this conversion on the main actor.
#if os(macOS)
            let fallback = color.getTerminalColor()
#else
            let fallback = resolved.getTerminalColor()
#endif
            red = CGFloat(fallback.red) / 65535
            green = CGFloat(fallback.green) / 65535
            blue = CGFloat(fallback.blue) / 65535
#if os(macOS)
            alpha = 1
#else
            alpha = resolved.cgColor.alpha
#endif
        }
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
    }

    var nativeColor: TTColor {
#if os(macOS)
        TTColor.make(red: red, green: green, blue: blue, alpha: alpha)
#else
        TTColor(red: red, green: green, blue: blue, alpha: alpha)
#endif
    }
}

/// The colors whose platform resolution can change with the view appearance.
struct FrameAppearance: Sendable, Equatable {
    let effectiveForegroundColor: FrameColor
    let effectiveBackgroundColor: FrameColor
    let selectedTextBackgroundColor: FrameColor
    let selectedTextForegroundColor: FrameColor
    let caretColor: FrameColor
    let caretTextColor: FrameColor
}

/// Caches main-actor font copies and dynamic-color resolution for frame input.
///
/// The cache compares the native inputs on each capture. It rebuilds colors
/// when the platform appearance or trait collection changes, so callers do not
/// need a separate invalidation hook for each color setter.
@MainActor
final class FrameCaptureCache {
    private var sourceFonts: [TTFont] = []
    private var cachedFonts: FrameFontSet?
    private var sourceColors: [TTColor] = []
    private var appearanceSignature = 0
    private var cachedAppearance: FrameAppearance?

#if DEBUG
    private(set) var fontRebuildCount = 0
    private(set) var appearanceRebuildCount = 0
#endif

    func fonts (for view: TerminalView) -> FrameFontSet {
        let current = [view.fontSet.normal, view.fontSet.bold,
                       view.fontSet.italic, view.fontSet.boldItalic]
        if let cachedFonts,
           sourceFonts.count == current.count,
           zip(sourceFonts, current).allSatisfy({ $0.0.isEqual($0.1) }) {
            return cachedFonts
        }

        let result = FrameFontSet(view.fontSet)
        sourceFonts = current
        cachedFonts = result
#if DEBUG
        fontRebuildCount += 1
#endif
        return result
    }

    func appearance (for view: TerminalView) -> FrameAppearance {
        let current = [
            view.effectiveNativeForegroundColor,
            view.effectiveNativeBackgroundColor,
            view.selectedTextBackgroundColor,
            view.selectedTextForegroundColor,
            view.effectiveCaretColor,
            view.effectiveCaretTextColor
        ]
#if os(macOS)
        let signature = view.effectiveAppearance.name.rawValue.hashValue
#else
        let signature = view.traitCollection.hash
#endif
        if let cachedAppearance,
           appearanceSignature == signature,
           sourceColors.count == current.count,
           zip(sourceColors, current).allSatisfy({ $0.0.isEqual($0.1) }) {
            return cachedAppearance
        }

        let result = FrameAppearance(
            effectiveForegroundColor: FrameColor(current[0], view: view),
            effectiveBackgroundColor: FrameColor(current[1], view: view),
            selectedTextBackgroundColor: FrameColor(current[2], view: view),
            selectedTextForegroundColor: FrameColor(current[3], view: view),
            caretColor: FrameColor(current[4], view: view),
            caretTextColor: FrameColor(current[5], view: view))
        sourceColors = current
        appearanceSignature = signature
        cachedAppearance = result
#if DEBUG
        appearanceRebuildCount += 1
#endif
        return result
    }
}

/// A rendered fragment that starts at a specific column and contains a run of
/// characters that all occupy the same number of columns.
struct ViewLineSegment {
    let column: Int
    let columnWidth: Int
    let characterCount: Int
    let attributedString: NSAttributedString
    /// Maps every UTF-16 unit of attributedString to the ordinal of the cell
    /// it belongs to, so glyphs can be positioned by cell (combining marks
    /// share their base's cell instead of shifting the column grid).
    let utf16ToCellOrdinal: [Int]
    /// True when every cell contributed exactly one UTF-16 unit, so the map
    /// is the identity and glyph index arithmetic can position runs directly.
    let utf16IsCellIdentity: Bool

    var columnSpan: Int {
        return max(0, characterCount * columnWidth)
    }

    @inline(__always)
    func cellOrdinal(forUTF16 index: Int) -> Int {
        if index >= 0 && index < utf16ToCellOrdinal.count {
            return utf16ToCellOrdinal[index]
        }
        return max(0, utf16ToCellOrdinal.last ?? 0)
    }
}

/// Attribute key and value pinning CoreText to left-to-right layout. Shared
/// constants, so adding them to a batch dictionary allocates nothing.
let ltrWritingDirectionKey = NSAttributedString.Key(kCTWritingDirectionAttributeName as String)
let ltrWritingDirectionValue: [NSNumber] = [NSNumber(value: 2)]

/// Checked-Sendable names for the CoreText attributes used by the draw pass.
fileprivate struct CoreTextRunAttributeNames: Sendable {
    let font = NSAttributedString.Key.font.rawValue
    let foreground = NSAttributedString.Key.foregroundColor.rawValue
    let background = NSAttributedString.Key.backgroundColor.rawValue
    let selectionBackground = NSAttributedString.Key.selectionBackgroundColor.rawValue
    let underlineStyle = NSAttributedString.Key.underlineStyle.rawValue
    let strikethroughStyle = NSAttributedString.Key.strikethroughStyle.rawValue
    let glyphPolicy = SwiftTermGlyphPolicyKey.rawValue
}

fileprivate let coreTextRunAttributeNames = CoreTextRunAttributeNames()

/// Owner-local bridged keys for unbridged CoreText run dictionaries.
///
/// Each Core Graphics renderer creates these immutable keys once. They do not
/// cross a concurrency boundary, and keyed lookups do not bridge per run.
fileprivate struct CoreTextRunAttributeKeys {
    let font: NSString
    let foreground: NSString
    let background: NSString
    let selectionBackground: NSString
    let underlineStyle: NSString
    let strikethroughStyle: NSString
    let glyphPolicy: NSString

    init(names: CoreTextRunAttributeNames) {
        font = names.font as NSString
        foreground = names.foreground as NSString
        background = names.background as NSString
        selectionBackground = names.selectionBackground as NSString
        underlineStyle = names.underlineStyle as NSString
        strikethroughStyle = names.strikethroughStyle as NSString
        glyphPolicy = names.glyphPolicy as NSString
    }
}

/// Values the draw passes need from a CTRun, extracted once per run so both
/// passes share them and the full attribute dictionary is never bridged on
/// undecorated runs.
struct PreparedRun {
    let run: CTRun
    let font: TTFont?
    let foregroundColor: TTColor?
    let backgroundColor: TTColor?
    let glyphPolicy: TerminalGlyphPlacementPolicy?
    /// True when the run carries underline or strikethrough attributes.
    let hasDecorations: Bool
    let attributes: NSDictionary
}

/// Per-view caches for the main-thread Core Graphics renderer.
///
/// A process-global cache lets two terminal views mutate the same dictionaries
/// at the same time. Keeping the cache with its view gives it the same lifetime
/// and executor as the Core Graphics draw path.
final class CoreGraphicsRenderCache {
    fileprivate let runAttributeKeys = CoreTextRunAttributeKeys(
        names: coreTextRunAttributeNames)
    private var cgColors: [TTColor: CGColor] = [:]
    private struct CTLineCacheKey: Hashable {
        let text: NSAttributedString
        let fallbackTag: UInt64
    }
    private var ctLines: [CTLineCacheKey: CTLine] = [:]

    @inline(__always)
    func cgColor(for color: TTColor) -> CGColor {
        if let cg = cgColors[color] {
            return cg
        }
        if cgColors.count >= 1024 {
            cgColors.removeAll(keepingCapacity: true)
        }
        let cg = color.cgColor
        cgColors[color] = cg
        return cg
    }

    func clearColors() {
        cgColors.removeAll(keepingCapacity: true)
    }

    /// Only short segments are cached. They are isolated BiDi cells whose
    /// layout cost is much greater than the key-copy cost. Host fallback runs
    /// also include the font object identity because platform font equality
    /// can treat two replacement fonts with the same name and size as equal.
    func line(for text: NSAttributedString) -> CTLine {
        let maxLength = 8
        guard text.length <= maxLength else {
            return CTLineCreateWithAttributedString(text)
        }
        var fallbackTag: UInt64 = 0
        if text.length > 0,
           text.attribute(SwiftTermGlyphPolicyKey, at: 0, effectiveRange: nil) != nil,
           let font = text.attribute(.font, at: 0, effectiveRange: nil) as? TTFont {
            fallbackTag = UInt64(bitPattern: Int64(ObjectIdentifier(font).hashValue))
        }
        let key = CTLineCacheKey(text: text, fallbackTag: fallbackTag)
        if let line = ctLines[key] {
            return line
        }
        if ctLines.count >= 2048 {
            ctLines.removeAll(keepingCapacity: true)
        }
        let line = CTLineCreateWithAttributedString(text)
        // The builder supplies NSMutableAttributedString. Store an immutable
        // key so later builder changes cannot invalidate the dictionary.
        ctLines[CTLineCacheKey(text: text.copy() as! NSAttributedString,
                               fallbackTag: fallbackTag)] = line
        return line
    }
}

// Holds the information used to render a line
struct ViewLineInfo {
    // Contains the generated segments for this line
    var segments: [ViewLineSegment]
    // contains an array of (image, column where the image was found)
    var images: [TerminalImage]?
    var kittyPlaceholders: [KittyPlaceholderCell]
    var blockElements: [BlockElementRenderItem]
    var boxDrawings: [BoxDrawingRenderItem]
    var powerlineGlyphs: [PowerlineRenderItem]
}

struct SnapshotSelectionResolver {
    let style: SnapshotStyle
    let cols: Int

    func columns (forRow row: Int) -> Range<Int>? {
        guard style.selectionActive else { return nil }
        let start = style.selectionStart
        let end = style.selectionEnd
        var lower = 0
        var upper = 0

        if start.row == end.row, row == start.row {
            if start.col < end.col {
                lower = start.col
                upper = end.col + (end.col == cols - 1 ? 1 : 0)
            } else if start.col > end.col {
                lower = end.col
                upper = start.col
            }
        } else if end.row > start.row {
            if row == start.row {
                lower = start.col
                upper = cols
            } else if row > start.row, row < end.row {
                upper = cols
            } else if row == end.row {
                upper = end.col + (end.col == cols - 1 ? 1 : 0)
            }
        } else if start.row > end.row {
            if row == end.row {
                lower = end.col
                upper = cols
            } else if row > end.row, row < start.row {
                upper = cols
            } else if row == start.row {
                upper = start.col + (start.col == cols - 1 ? 1 : 0)
            }
        }

        lower = max(0, min(lower, cols))
        upper = max(lower, min(upper, cols))
        return lower < upper ? lower..<upper : nil
    }
}

/// The view state one frame reads, captured as a value on the main thread.
///
/// Preparing a frame — refreshing the snapshot under the terminal lock and
/// building the render context — has to be callable from a render thread
/// (io-gaps.md G1). Reaching into the view from there is a data race: fonts,
/// colors, selection and bounds all change on main. So main captures them once
/// per frame into this struct, and the preparation reads only the struct.
///
/// Adding a field here is fine. Reading live view state from the preparation
/// path instead is not: that is the invariant this type exists to hold.
struct FrameViewState: Sendable {
    // What TerminalSnapshot.refresh reads.
    let linkHighlightRange: [Terminal.LinkMatch.RowRange]?
    let linkHighlightMode: LinkHighlightMode
    let commandActive: Bool
    let textBlinkVisible: Bool
    let notifyUpdateChanges: Bool

    // What SnapshotRenderContext reads, plus the geometry the frame tick uses
    // to compute its dirty region.
    let fonts: FrameFontSet
    let cellDimension: TerminalView.CellDimension
    let viewBounds: CGRect
    let viewFrameHeight: CGFloat
    let renderingScale: CGFloat
    let imageScale: CGFloat
    let metalBufferingMode: MetalBufferingMode
    let fontSmoothing: Bool
    let antiAliasCustomBlockGlyphs: Bool
    let cursorHasFocus: Bool
    let appearance: FrameAppearance
    let customBlockGlyphs: Bool
    let useBrightColors: Bool
    let bidiHostPolicy: BidiHostPolicy
    let glyphFallbackProvider: (any TerminalGlyphFallbackProvider)?

    var effectiveForegroundColor: FrameColor { appearance.effectiveForegroundColor }
    var effectiveBackgroundColor: FrameColor { appearance.effectiveBackgroundColor }
    var selectedTextBackgroundColor: FrameColor { appearance.selectedTextBackgroundColor }
    var selectedTextForegroundColor: FrameColor { appearance.selectedTextForegroundColor }
    var caretColor: FrameColor { appearance.caretColor }
    var caretTextColor: FrameColor { appearance.caretTextColor }

    @MainActor
    init (view: TerminalView) {
        linkHighlightRange = view.linkHighlightRange
        linkHighlightMode = view.linkHighlightMode
        commandActive = view.commandActive
        textBlinkVisible = view.textBlinkVisible
        notifyUpdateChanges = view.notifyUpdateChanges

        fonts = view.frameCaptureCache.fonts(for: view)
        cellDimension = view.cellDimension
        viewBounds = view.bounds
        viewFrameHeight = view.frame.height
#if os(macOS)
        renderingScale = view.metalRenderingScaleFactor()
        fontSmoothing = view.fontSmoothing
        cursorHasFocus = !view.caretViewTracksFocus || view.hasFocus
#else
        renderingScale = view.backingScaleFactor()
        fontSmoothing = true
        cursorHasFocus = !view.caretViewTracksFocus || view.isFirstResponder
#endif
        imageScale = view.getImageScale()
        metalBufferingMode = view.metalBufferingMode
        antiAliasCustomBlockGlyphs = view.antiAliasCustomBlockGlyphs
        appearance = view.frameCaptureCache.appearance(for: view)
        customBlockGlyphs = view.customBlockGlyphs
        useBrightColors = view.useBrightColors
        bidiHostPolicy = view.bidiHostPolicy
        glyphFallbackProvider = view.glyphFallbackProvider
    }
}

struct FrameChangedRange: Sendable, Equatable {
    let start: Int
    let end: Int
}

struct FrameTerminalSize: Sendable, Equatable {
    let cols: Int
    let rows: Int
}

/// The complete render-to-main message for one frame.
///
/// It contains only checked-Sendable values. Cursor render data stays with
/// `PreparedFrame` in the render owner.
struct MainFrameEffects: Sendable {
    var rangeChanged: FrameChangedRange?
    var notifyAccessibility: Bool
    var scrollPosition: Double
    var blinkRows: [Int] = []
    var resizedTo: FrameTerminalSize? = nil
#if os(macOS)
    var scroller: TerminalView.ScrollerState? = nil
#endif
}

/// Platform colors materialized inside the render owner.
struct SnapshotNativeColors {
    let effectiveForegroundColor: TTColor
    let effectiveBackgroundColor: TTColor
    let selectedTextBackgroundColor: TTColor
    let selectedTextForegroundColor: TTColor
    let caretColor: TTColor
    let caretTextColor: TTColor
    let ansiColors: [TTColor]
}

struct SnapshotRenderContext {
    let fonts: FrameFontSet
    let cellDimension: TerminalView.CellDimension
    let viewBounds: CGRect
    let renderingScale: CGFloat
    let imageScale: CGFloat
    let metalBufferingMode: MetalBufferingMode
    let fontSmoothing: Bool
    let antiAliasCustomBlockGlyphs: Bool
    let cursorHasFocus: Bool
    let effectiveForegroundColor: TTColor
    let effectiveBackgroundColor: TTColor
    let selectedTextBackgroundColor: TTColor
    let selectedTextForegroundColor: TTColor
    let caretColor: TTColor
    let caretTextColor: TTColor
    let ansiColors: [TTColor]
    let selection: SnapshotSelectionResolver
    let textBlinkVisible: Bool
    let linkHighlightRange: [Terminal.LinkMatch.RowRange]?
    let linkHighlightMode: LinkHighlightMode
    let commandActive: Bool
    let customBlockGlyphs: Bool
    let useBrightColors: Bool
    let bidiHostPolicy: BidiHostPolicy
    let glyphFallbackProvider: (any TerminalGlyphFallbackProvider)?
    let cols: Int

    /// Identifies the values used to build attributed-string dictionaries.
    /// Equal visual inputs produce the same identity across frames, so the
    /// renderer cache stays warm until a font, palette, or default color
    /// changes.
    let identity: UInt64

    init (viewState: FrameViewState, snapshot: TerminalSnapshot) {
        self.init(viewState: viewState, style: snapshot.style,
                  nativeColors: snapshot.nativeColors(for: viewState.appearance),
                  cols: snapshot.cols)
    }

    init (viewState: FrameViewState, style: SnapshotStyle, ansiColors: [Color],
          cols: Int) {
        let appearance = viewState.appearance
        self.init(
            viewState: viewState,
            style: style,
            nativeColors: SnapshotNativeColors(
                effectiveForegroundColor: appearance.effectiveForegroundColor.nativeColor,
                effectiveBackgroundColor: appearance.effectiveBackgroundColor.nativeColor,
                selectedTextBackgroundColor: appearance.selectedTextBackgroundColor.nativeColor,
                selectedTextForegroundColor: appearance.selectedTextForegroundColor.nativeColor,
                caretColor: appearance.caretColor.nativeColor,
                caretTextColor: appearance.caretTextColor.nativeColor,
                ansiColors: ansiColors.map(TTColor.make(color:))),
            cols: cols)
    }

    private init (viewState: FrameViewState, style: SnapshotStyle,
                  nativeColors: SnapshotNativeColors, cols: Int) {
        fonts = viewState.fonts
        cellDimension = viewState.cellDimension
        viewBounds = viewState.viewBounds
        renderingScale = viewState.renderingScale
        fontSmoothing = viewState.fontSmoothing
        cursorHasFocus = viewState.cursorHasFocus
        imageScale = viewState.imageScale
        metalBufferingMode = viewState.metalBufferingMode
        antiAliasCustomBlockGlyphs = viewState.antiAliasCustomBlockGlyphs
        effectiveForegroundColor = nativeColors.effectiveForegroundColor
        effectiveBackgroundColor = nativeColors.effectiveBackgroundColor
        selectedTextBackgroundColor = nativeColors.selectedTextBackgroundColor
        selectedTextForegroundColor = nativeColors.selectedTextForegroundColor
        caretColor = nativeColors.caretColor
        caretTextColor = nativeColors.caretTextColor
        ansiColors = nativeColors.ansiColors
        selection = SnapshotSelectionResolver(style: style, cols: cols)
        textBlinkVisible = style.textBlinkVisible
        linkHighlightRange = style.linkHighlightRange
        linkHighlightMode = style.linkHighlightMode
        commandActive = style.commandActive
        customBlockGlyphs = viewState.customBlockGlyphs
        useBrightColors = viewState.useBrightColors
        bidiHostPolicy = viewState.bidiHostPolicy
        glyphFallbackProvider = viewState.glyphFallbackProvider
        self.cols = cols

        var identityHasher = Hasher()
        identityHasher.combine(fonts.normal.hash)
        identityHasher.combine(fonts.bold.hash)
        identityHasher.combine(fonts.italic.hash)
        identityHasher.combine(fonts.boldItalic.hash)
        identityHasher.combine(glyphFallbackProvider?.cacheIdentity ?? 0)
        identityHasher.combine(effectiveForegroundColor.hash)
        identityHasher.combine(effectiveBackgroundColor.hash)
        identityHasher.combine(selectedTextBackgroundColor.hash)
        identityHasher.combine(selectedTextForegroundColor.hash)
        identityHasher.combine(caretColor.hash)
        identityHasher.combine(caretTextColor.hash)
        for color in self.ansiColors {
            identityHasher.combine(color.hash)
        }
        identityHasher.combine(useBrightColors)
        identity = UInt64(bitPattern: Int64(identityHasher.finalize()))
    }

    /// ``CellGeometry/baselineOffset(normalFont:cellHeight:)`` for the fonts and
    /// cell geometry captured in this frame. Both renderers read it from here so
    /// a frame's text, caret, and scaled glyphs share one baseline.
    var baselineOffset: CGFloat {
        CellGeometry.baselineOffset(normalFont: fonts.normal,
                                    cellHeight: cellDimension.height)
    }

    func glyphSlotFit (font: CTFont, glyph: CGGlyph, columnWidth: Int) -> GlyphSlotFit {
        GlyphSlotFit.calculate(font: font, glyph: glyph, columnWidth: columnWidth,
                               cellDimension: cellDimension, normalFont: fonts.normal)
    }
}

/// Text geometry derived from a cell's size. Not isolated to the main actor:
/// the snapshot renderers do this arithmetic on their own threads, from the
/// fonts and cell dimensions captured for the frame.
enum CellGeometry {
    /// Distance from the bottom of a cell to the glyph baseline.
    ///
    /// ``TerminalView/lineSpacing`` makes the cell taller than the font's
    /// natural line (ascent + descent + leading) in `computeFontDimensions`,
    /// but the baseline used to stay pinned at `descent + leading` from the
    /// cell's bottom, so every bit of the added height piled up above the text
    /// and rows looked bottom-heavy at the larger values (1.4-1.6). This
    /// splits the extra evenly above and below the glyph instead — the
    /// half-leading model iTerm2 and WezTerm use — so text stays vertically
    /// centered in its cell.
    ///
    /// The classic `ceil(descent + leading)` term is kept intact and the
    /// glyph's share of the extra is added as a whole number of points on top,
    /// rather than rounding the sum: that keeps the baseline on the same pixel
    /// grid the old offset landed on, and it makes the default exact rather
    /// than approximate. A cell within two points of the font's natural height
    /// — which pixel-grid snapping alone can produce at `lineSpacing == 1` on
    /// a fractional backing scale — yields the classic offset unchanged, so
    /// nobody who leaves `lineSpacing` alone sees a single pixel move.
    ///
    /// Every renderer — CoreGraphics, Metal, the caret views — and the glyph
    /// slot fitter must derive baselines from this one function. The local
    /// copies of the formula it replaces are how those paths drifted out of
    /// sync in the first place.
    static func baselineOffset (normalFont: CTFont, cellHeight: CGFloat) -> CGFloat
    {
        let descent = CTFontGetDescent (normalFont)
        let leading = CTFontGetLeading (normalFont)
        let naturalHeight = ceil (CTFontGetAscent (normalFont) + descent + leading)
        let extra = max (0, cellHeight - naturalHeight)
        return ceil (descent + leading) + floor (extra / 2)
    }
}

/// How to place a single glyph within its `columnWidth`-cell slot.
///
/// Full-width (CJK) and other substituted glyphs would otherwise be pinned to
/// the left edge of their slot, which dumps the slack between the glyph's
/// advance and the slot width onto the right of every cell — the phantom gap
/// reported for CJK text. ``GlyphSlotFit`` centers the glyph's advance box in
/// the slot so the slack is split evenly instead, matching Terminal.app and the
/// centering Ghostty applies to wide glyphs (its glyph constraint with
/// `align: .center`). As a safety net it also constrains a glyph whose ink
/// overflows its slot — too wide for the columns, or too tall for the cell —
/// scaling it down to fit and re-centering it vertically. That fit-to-cell guard
/// is in the spirit of Ghostty's `size` constraint; it is not Ghostty's
/// cap-height CJK down-scaling (#8709), which corrects an up-scaling we never do.
/// `dx`/`dy` are point offsets applied to the glyph origin; `scale` is a uniform
/// downscale (`<= 1`).
struct GlyphSlotFit {
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1

    /// Uniform scale for the paths that redraw by font size. Every non-policy
    /// fit is uniform; only a `.stretch` placement produces distinct per-axis
    /// scales, and its draw paths read `scaleX`/`scaleY` directly.
    var scale: CGFloat { scaleX }
    var isUniform: Bool { scaleX == scaleY }

    init (dx: CGFloat = 0, dy: CGFloat = 0, scale: CGFloat = 1) {
        self.dx = dx
        self.dy = dy
        scaleX = scale
        scaleY = scale
    }

    init (dx: CGFloat, dy: CGFloat, scaleX: CGFloat, scaleY: CGFloat) {
        self.dx = dx
        self.dy = dy
        self.scaleX = scaleX
        self.scaleY = scaleY
    }

    static let identity = GlyphSlotFit()

    var isIdentity: Bool { dx == 0 && dy == 0 && scaleX == 1 && scaleY == 1 }

    static func calculate (font: CTFont, glyph: CGGlyph, columnWidth: Int,
                           cellDimension: CGSize, normalFont: TTFont) -> GlyphSlotFit {
        guard columnWidth >= 2 else { return .identity }

        let metrics = GlyphMetrics.measure(font: font, glyph: glyph)
        let baselineFromBottom = CellGeometry.baselineOffset(normalFont: normalFont,
                                                             cellHeight: cellDimension.height)
        return calculate(metrics: metrics,
                         columnWidth: columnWidth,
                         cellDimension: cellDimension,
                         baselineFromBottom: baselineFromBottom,
                         renderingScale: 1)
    }

    /// Calculates the fit from metrics measured on a font scaled for rendering.
    /// Metric and geometry arithmetic is in pixels. The returned offsets remain
    /// in points because the existing vertex path applies the rendering scale.
    static func calculate(metrics: GlyphMetrics,
                          columnWidth: Int,
                          cellDimension: CGSize,
                          baselineFromBottom: CGFloat,
                          renderingScale: CGFloat) -> GlyphSlotFit {
        guard columnWidth >= 2, renderingScale > 0 else { return .identity }

        let slotWidth = CGFloat(columnWidth) * cellDimension.width * renderingScale
        let cellHeight = cellDimension.height * renderingScale
        let advance = metrics.horizontalAdvance
        guard advance > 0 else { return .identity }
        let ink = metrics.fitInkBounds

        var scale: CGFloat = 1
        if ink.width > slotWidth || ink.height > cellHeight,
           ink.width > 0, ink.height > 0 {
            scale = max(0.1, min(min(slotWidth / ink.width,
                                     cellHeight / ink.height), 1))
        }

        let dxPixels = (slotWidth - advance * scale) / 2
        var dyPixels: CGFloat = 0
        if scale < 1, ink.height > 0 {
            let inkCenterFromBaseline = (ink.origin.y + ink.height / 2) * scale
            dyPixels = (cellHeight / 2 - baselineFromBottom * renderingScale) -
                inkCenterFromBaseline
        }
        return GlyphSlotFit(dx: dxPixels / renderingScale,
                            dy: dyPixels / renderingScale,
                            scale: scale)
    }

    /// Internal tuning knob for the one-column icon-height limit; 1.0 leaves
    /// the primary font's ascent as the limit. Not public: the spec adds a
    /// host-visible setting only when the host already has one.
    static let adjustIconHeight: CGFloat = 1.0

    /// Applies a host ``TerminalGlyphPlacementPolicy`` to a fallback glyph.
    ///
    /// Unlike the guard-rail overload above this also constrains one-column
    /// glyphs, applies the policy's width limit and padding, honors the
    /// cover/stretch modes, and centers the ink box even when no downscale is
    /// needed. `iconHeight` is the primary font's icon-height limit in pixels
    /// (its ascent at the rendering scale); the grid stays based on the
    /// selected font, never on the fallback face's metrics. Icon placements
    /// never enlarge a glyph past its natural size; `.cover` and `.stretch`
    /// scale in either direction so the glyph fills its slot as specified.
    static func calculate (metrics: GlyphMetrics,
                           policy: TerminalGlyphPlacementPolicy,
                           columnWidth: Int,
                           cellDimension: CGSize,
                           baselineFromBottom: CGFloat,
                           iconHeight: CGFloat,
                           renderingScale: CGFloat) -> GlyphSlotFit {
        guard renderingScale > 0 else { return .identity }

        let cellWidth = cellDimension.width * renderingScale
        let cellHeight = cellDimension.height * renderingScale
        let slotColumns = max(1, min(columnWidth, policy.maximumCellWidth ?? columnWidth))
        let padLeft = policy.padding.left * cellWidth
        let padRight = policy.padding.right * cellWidth
        let padTop = policy.padding.top * cellHeight
        let padBottom = policy.padding.bottom * cellHeight
        let allowedWidth = max(1, CGFloat(slotColumns) * cellWidth - padLeft - padRight)
        let allowedHeight = max(1, cellHeight - padTop - padBottom)

        let ink = metrics.fitInkBounds
        guard ink.width > 0, ink.height > 0 else { return .identity }

        // Grouped icons fit their group's virtual box so that every member of
        // the group lands on the same vertical frame; the glyph's own ink is a
        // `relativeBounds` fraction of that box.
        var fitBox = ink
        if policy.placement == .grouped, let relative = policy.relativeBounds,
           relative.width > 0, relative.height > 0 {
            let groupWidth = ink.width / relative.width
            let groupHeight = ink.height / relative.height
            fitBox = CGRect(x: ink.origin.x - relative.minX * groupWidth,
                            y: ink.origin.y - relative.minY * groupHeight,
                            width: groupWidth,
                            height: groupHeight)
        }

        let scaleX: CGFloat
        let scaleY: CGFloat
        switch policy.placement {
        case .stretch:
            // Fill the padded slot exactly, scaling each axis independently
            // and in either direction. The icon-height limit does not apply.
            scaleX = allowedWidth / fitBox.width
            scaleY = allowedHeight / fitBox.height
        case .cover:
            // Fill the intended cell width, enlarging if needed, bounded only
            // by the cell height — the icon-height limit does not apply.
            let scale = max(0.1, min(allowedWidth / fitBox.width,
                                     allowedHeight / fitBox.height))
            scaleX = scale
            scaleY = scale
        case .icon, .explicitWidth, .grouped:
            let heightLimit = slotColumns == 1 && iconHeight > 0
                ? min(allowedHeight, iconHeight * adjustIconHeight)
                : allowedHeight
            // Contain fit: may shrink, never enlarges past natural size.
            let scale = max(0.1, min(min(allowedWidth / fitBox.width,
                                         heightLimit / fitBox.height), 1))
            scaleX = scale
            scaleY = scale
        }

        // Center the (scaled) box horizontally inside the padded slot and
        // vertically between the padding insets. dx/dy displace the glyph
        // origin, whose pen position sits on the baseline at the slot's left
        // edge, so the ink origin participates in both.
        let dxPixels = padLeft + (allowedWidth - fitBox.width * scaleX) / 2
            - fitBox.origin.x * scaleX
        let boxCenterFromBaseline = (fitBox.origin.y + fitBox.height / 2) * scaleY
        let targetCenterFromBottom = padBottom + allowedHeight / 2
        let dyPixels = (targetCenterFromBottom - baselineFromBottom * renderingScale)
            - boxCenterFromBaseline

        return GlyphSlotFit(dx: dxPixels / renderingScale,
                            dy: dyPixels / renderingScale,
                            scaleX: scaleX,
                            scaleY: scaleY)
    }
}

/// Unrounded Core Text metrics in the coordinate space of `font`.
///
/// The Metal renderer measures a font whose point size already includes the
/// rendering scale. These values are therefore pixel-space metrics there.
struct GlyphMetrics {
    let inkBounds: CGRect
    let horizontalAdvance: CGFloat
    let fontSize: CGFloat
    let fitInkSizeScale: CGFloat

    /// Interprets fixed color-bitmap strikes in the requested pixel space.
    /// Core Text can select a strike whose size differs from the requested
    /// point size. Its center remains in the requested coordinate space, but
    /// its width and height are in strike space.
    var fitInkBounds: CGRect {
        guard fitInkSizeScale != 1 else { return inkBounds }
        let size = CGSize(width: inkBounds.width * fitInkSizeScale,
                          height: inkBounds.height * fitInkSizeScale)
        return CGRect(x: inkBounds.origin.x,
                      y: inkBounds.midY - size.height / 2,
                      width: size.width,
                      height: size.height)
    }

    static func measure(font: CTFont, glyph: CGGlyph,
                        fittingFont: CTFont? = nil,
                        renderingScale: CGFloat = 1) -> GlyphMetrics {
        var glyph = glyph
        var advance = CGSize.zero
        let fittingFont = fittingFont ?? font
        CTFontGetAdvancesForGlyphs(fittingFont, .horizontal, &glyph, &advance, 1)
        var inkBounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &inkBounds, 1)

        var fitInkSizeScale: CGFloat = 1
        if renderingScale != 1,
           CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) {
            let sourceAscent = CTFontGetAscent(fittingFont)
            let strikeAscent = CTFontGetAscent(font)
            if sourceAscent > 0, strikeAscent > 0 {
                let strikeScale = strikeAscent / sourceAscent
                fitInkSizeScale = renderingScale / strikeScale
            }
        }
        return GlyphMetrics(inkBounds: inkBounds,
                            horizontalAdvance: advance.width * renderingScale,
                            fontSize: CTFontGetSize(font),
                            fitInkSizeScale: fitInkSizeScale)
    }
}

private let terminalFramePresentedHandler = LockedVoidCallback()

/// The current terminal grid size.
public struct TerminalDimensions: Sendable, Equatable {
    public let cols: Int
    public let rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

/// A copied row from the visible terminal region.
public struct TerminalVisibleRowSnapshot: Sendable, Equatable {
    public let row: Int
    public let text: String
    public let isWrapped: Bool
    public let bidiState: BidiPresentationState
    /// The display width of each copied cell. Wide cells use `2` for the
    /// leading cell and `0` for the trailing cell.
    public let cellWidths: [Int]

    public init(row: Int, text: String, isWrapped: Bool,
                bidiState: BidiPresentationState, cellWidths: [Int]) {
        self.row = row
        self.text = text
        self.isWrapped = isWrapped
        self.bidiState = bidiState
        self.cellWidths = cellWidths
    }
}

/// A copied terminal state for status displays and diagnostics.
public struct TerminalViewStateSnapshot: Sendable {
    public let dimensions: TerminalDimensions
    public let cursor: Position
    public let viewportRow: Int
    public let currentBidiState: BidiPresentationState
    public let bidiArrowKeySwap: Bool
    public let cursorStyle: CursorStyle
    public let ansi256PaletteStrategy: Ansi256PaletteStrategy
    public let visibleRows: [TerminalVisibleRowSnapshot]
}

/// Delivers input to one main-actor sink in FIFO order.
///
/// At most one drain task is pending. The queue preserves the order in which
/// callers enter ``enqueue(_:)`` without relying on unstructured task order.
private final class TerminalInputMainActorDelivery: Sendable {
    private struct State: Sendable {
        var pending: [[UInt8]] = []
        var drainScheduled = false
    }

    private let state = Locked(State())
    private let sink: @MainActor @Sendable ([UInt8]) -> Void

    init(sink: @escaping @MainActor @Sendable ([UInt8]) -> Void) {
        self.sink = sink
    }

    func enqueue(_ bytes: [UInt8]) {
        let shouldSchedule = state.withLock { state in
            state.pending.append(bytes)
            guard !state.drainScheduled else { return false }
            state.drainScheduled = true
            return true
        }

        guard shouldSchedule else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { drain() }
        } else {
            Task { @MainActor in drain() }
        }
    }

    @MainActor
    private func drain() {
        while true {
            let batch = state.withLock { state -> [[UInt8]]? in
                guard !state.pending.isEmpty else {
                    state.drainScheduled = false
                    return nil
                }
                let batch = state.pending
                state.pending.removeAll(keepingCapacity: true)
                return batch
            }
            guard let batch else { return }
            for bytes in batch {
                sink(bytes)
            }
        }
    }
}

/// A checked handle for sending user input from any thread.
///
/// The handle retains no view. It registers semantic input under the render
/// owner's terminal lock, schedules UI effects on the main actor, and invokes
/// the current checked transport sink.
public final class TerminalInputSender: Sendable {
    private struct State: Sendable {
        var registerInput: (@Sendable ([UInt8]) -> Void)?
        var notifyUI: (@MainActor @Sendable () -> Void)?
        var deliver: (@Sendable ([UInt8]) -> Void)?
        var deliverOnMain: (@MainActor @Sendable ([UInt8]) -> Void)?
    }

    private let state = Locked(State())

    @MainActor
    fileprivate func configure(
        registerInput: @escaping @Sendable ([UInt8]) -> Void,
        notifyUI: @escaping @MainActor @Sendable () -> Void,
        deliver: @escaping @Sendable ([UInt8]) -> Void,
        deliverOnMain: @escaping @MainActor @Sendable ([UInt8]) -> Void
    ) {
        state.withLock { state in
            state.registerInput = registerInput
            state.notifyUI = notifyUI
            state.deliver = deliver
            state.deliverOnMain = deliverOnMain
        }
    }

    @MainActor
    func replaceDelivery(
        _ deliver: @escaping @Sendable ([UInt8]) -> Void
    ) {
        state.withLock { state in
            state.deliver = deliver
            state.deliverOnMain = { bytes in deliver(bytes) }
        }
    }

    /// Sends one input payload. Serial calls preserve their delivery order.
    /// Calls from concurrent threads need external ordering when byte order
    /// between those threads matters.
    public func send(data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        let handlers = state.withLock {
            (register: $0.registerInput, notify: $0.notifyUI,
             deliver: $0.deliver, deliverOnMain: $0.deliverOnMain)
        }
        handlers.register?(bytes)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                handlers.notify?()
                handlers.deliverOnMain?(bytes)
            }
            return
        }
        if let notify = handlers.notify {
            Task { @MainActor in notify() }
        }
        handlers.deliver?(bytes)
    }
}

/// A checked handle for feeding parser input from any thread.
public final class TerminalFeedSender: Sendable {
    private struct State: Sendable {
        var feedBytes: (@Sendable ([UInt8]) -> Void)?
        var feedText: (@Sendable (String) -> Void)?
    }

    private let state = Locked(State())

    @MainActor
    fileprivate func configure(
        feedBytes: @escaping @Sendable ([UInt8]) -> Void,
        feedText: @escaping @Sendable (String) -> Void
    ) {
        state.withLock { state in
            state.feedBytes = feedBytes
            state.feedText = feedText
        }
    }

    public func feed(byteArray: ArraySlice<UInt8>) {
        let bytes = Array(byteArray)
        state.withLock { $0.feedBytes }?(bytes)
    }

    public func feed(text: String) {
        state.withLock { $0.feedText }?(text)
    }
}

/// Identifies one cropped Kitty placement bitmap in `kittyPlacementImageCache`.
///
/// The crop depends on the placement, on the pixels of the frame on display and
/// on the part of the image the placement currently shows, so all three take
/// part in the key: a cache hit is only valid while none of them has changed.
struct KittyPlacementImageKey: Hashable {
    let token: UInt64
    let contentGeneration: UInt64
    let source: KittyGraphicsPixelRect
}

struct TerminalViewCrossThreadState: Sendable {
    var reverseColorsActive = false
    var cachedCellPointSize: CGSize?
    var cachedImageScale: CGFloat?
    var cachedCellPixelSize: (width: Int, height: Int)?
    var cachedNativeColors: (foreground: Color, background: Color)?
    var scrolledDirty = false
    var allowMouseReporting = true
}

extension TerminalView {

    /// Diagnostics hook: called when a frame has been drawn.
    ///
    /// Metal calls it on a Metal thread as the command buffer completes; Core
    /// Graphics calls it on the main thread at the end of `draw`. It exists to
    /// measure input-to-glyph latency, which cannot be derived from the frame
    /// counters — those say how many frames ran, not when the one carrying a
    /// particular byte reached the screen (io-gaps.md C0.2 case 3).
    ///
    /// Static rather than per-view for two reasons. Only one terminal is under
    /// measurement at a time, so per-view state would buy nothing; and a public
    /// stored property on `TerminalView` puts its accessors in the class
    /// vtable, where `LocalProcessTerminalView`'s metadata references them and
    /// `-dead_strip` then removes them — the SwiftPM executables failed to link
    /// with exactly that undefined symbol.
    ///
    /// Nil in normal use. Keep the closure short: it runs on the render path.
    public nonisolated static var onFramePresented: (@Sendable () -> Void)? {
        get { terminalFramePresentedHandler.current }
        set { terminalFramePresentedHandler.replace(with: newValue) }
    }

    @MainActor
    func configureInputSender() {
        let owner = renderOwner
        let notifyUI: @MainActor @Sendable () -> Void = { [weak self] in
            self?.ensureCaretIsVisible()
        }
        let deliverOnMain: @MainActor @Sendable ([UInt8]) -> Void = { [weak self] bytes in
            guard let self else { return }
            self.terminalDelegate?.send(source: self, data: bytes[...])
        }
        let mainDelivery = TerminalInputMainActorDelivery(sink: deliverOnMain)
        inputSender.configure(
            registerInput: { bytes in owner.registerUserInput(bytes) },
            notifyUI: notifyUI,
            deliver: { bytes in mainDelivery.enqueue(bytes) },
            deliverOnMain: { bytes in mainDelivery.enqueue(bytes) })
    }

    @MainActor
    func configureFeedSender() {
        let owner = renderOwner
        let signal = frameSignal
        let crossThreadState = crossThreadState
        let diagnosticsState = diagnosticsState
        feedSender.configure(
            feedBytes: { bytes in
                signal.markDirty()
                let parse = Profiling.begin(.ioParse, "bytes=%d", bytes.count)
                _ = owner.feed(
                    bytes: bytes[...],
                    allowMouseReporting: crossThreadState.withLock {
                        $0.allowMouseReporting
                    })
                parse.end()
                diagnosticsState.withLock { diagnostics in
                    diagnostics.bytesFed += bytes.count
                    diagnostics.batches += 1
                }
                signal.markDirty()
            },
            feedText: { text in
                signal.markDirty()
                _ = owner.feed(
                    text: text,
                    allowMouseReporting: crossThreadState.withLock {
                        $0.allowMouseReporting
                    })
                diagnosticsState.withLock { diagnostics in
                    diagnostics.bytesFed += text.utf8.count
                    diagnostics.batches += 1
                }
                signal.markDirty()
            })
    }

    typealias CellDimension = CGSize

    // Reads the viewStateLock-guarded mirror of `terminal.reverseColors`,
    // refreshed synchronously by the colorChanged delegate (which DECSCNM
    // always fires, under the terminal lock). Reading the terminal directly
    // here would race the parse thread: these properties are used on unlocked
    // main-thread draw paths (caret layer, Metal clear color, IME overlay).
    nonisolated func reverseColorsActiveValue () -> Bool
    {
        crossThreadState.withLock { $0.reverseColorsActive }
    }

    nonisolated func setReverseColorsActive (_ value: Bool)
    {
        crossThreadState.withLock { $0.reverseColorsActive = value }
    }

    var effectiveNativeForegroundColor: TTColor {
#if os(macOS)
        reverseColorsActiveValue() ? nativeBackgroundColor : nativeForegroundColor
#else
        guard reverseColorsActiveValue() else { return nativeForegroundColor }
        if nativeBackgroundColor.cgColor.alpha > 0 {
            return nativeBackgroundColor
        }
        if let savedBackground = reverseColorsSavedLayerBackground {
            return TTColor(cgColor: savedBackground)
        }
        return nativeBackgroundColor
#endif
    }

    var effectiveNativeBackgroundColor: TTColor {
        reverseColorsActiveValue() ? nativeForegroundColor : nativeBackgroundColor
    }

    var effectiveCaretColor: TTColor {
        cursorColorIsDefault ? effectiveNativeForegroundColor : caretColor
    }

    var effectiveCaretTextColor: TTColor {
        cursorTextColorIsDefault
            ? effectiveNativeBackgroundColor
            : (caretTextColor ?? effectiveNativeForegroundColor)
    }

#if os(macOS)
    /// Controls whether font smoothing (sub-pixel rendering) is enabled during glyph drawing.
    /// Set to `false` to get thinner strokes on Retina displays, matching iTerm2's "Thin strokes" setting.
    /// Defaults to `true` (standard macOS font smoothing).
    @objc open var fontSmoothing: Bool {
        get { _fontSmoothing }
        set { _fontSmoothing = newValue }
    }
#endif

    /// Multiplier for vertical line spacing. 1.0 = default (ascent + descent + leading).
    /// Set to 1.1 for 110% vertical spacing (matches iTerm2's vertical spacing setting).
    /// The extra height is split evenly above and below each glyph (see
    /// ``CellGeometry/baselineOffset(normalFont:cellHeight:)``), so text stays vertically
    /// centered within its cell.
    /// Triggers a font reset and terminal resize when changed.
    @objc open var lineSpacing: CGFloat {
        get { _lineSpacing }
        set {
            _lineSpacing = newValue
            resetFont()
        }
    }

    func resetCaches ()
    {
        self.attributes = [:]
        self.urlAttributes = [:]
        self.colors = Array(repeating: nil, count: 256)
        self.trueColors = [:]
    }
    
    // This is invoked when the font changes to recompute state
    func resetFont()
    {
        resetCaches()
        self.cellDimension = computeFontDimensions ()
        refreshCachedViewState()
        if (frame.width > 0) && (frame.height > 0) {
            // Use getEffectiveWidth so the scroller's reserved width is taken
            // into account, matching processSizeChange(). Computing columns from
            // the raw frame width here would over-count by the scroller width,
            // so zooming the font in and back out would drift the column count.
            let newCols = Int(getEffectiveWidth(size: frame.size) / cellDimension.width)
            let newRows = Int(frame.height / cellDimension.height)
            resize(cols: newCols, rows: newRows)
        }
        updateCaretView()
        
        #if os(macOS)
        needsDisplay = true
        #else
        setNeedsDisplay(frame)
        #endif
    }
    
    func updateCaretView ()
    {
        guard let caretView else { return }
        caretView.frame.size = CGSize(width: cellDimension.width, height: cellDimension.height)
        caretView.updateCursorStyle()
    }
    
    /// The frame used by the caretView
    public var caretFrame: CGRect {
        return caretView?.frame ?? CGRect.zero
    }
    
    func setupOptions(width: CGFloat, height: CGFloat)
    {
        resetCaches ()
        // Calculation assume that all glyphs in the font have the same advancement.
        // Get the ascent + descent + leading from the font, already scaled for the font's size
        self.cellDimension = computeFontDimensions ()

        let zeroSizedView = width == 0 && height == 0
        let creatingTerminal = terminal == nil
        var terminalOptions = terminal?.options ?? startupOptions
        if !zeroSizedView {
            terminalOptions.cols = Int(width / cellDimension.width)
            terminalOptions.rows = Int(height / cellDimension.height)
        }

        if creatingTerminal {
            terminal = ManagedFeedTerminal(delegate: self, options: terminalOptions)
        } else if !zeroSizedView {
            terminal.terminalLock.withLock {
                terminal.options = terminalOptions
                terminal.setup(isReset: false)
            }
        }
        let cursorStyle = terminal.terminalLock.withLock {
            terminal.backgroundColor = Color.defaultBackground
            terminal.foregroundColor = Color.defaultForeground
            selection = SelectionService(terminal: terminal)
            return terminal.options.cursorStyle
        }

        // Install carret view
        if caretView == nil {
            let v = CaretView(frame: CGRect(origin: .zero, size: CGSize(width: cellDimension.width, height: cellDimension.height)), cursorStyle: cursorStyle, terminal: self)
            addSubview(v)
            caretView = v
        } else {
            updateCaretView ()
        }
        
        search = SearchService (terminal: terminal)
        renderOwner.attach(terminal: terminal, selection: selection, search: search)
        refreshCachedViewState()
        
        #if os(macOS)
        needsDisplay = true
        #else
        setNeedsDisplay(frame)
        #endif
    }

    /// Runs `body` while holding the terminal lock.
    ///
    /// The closure must not call another API that synchronously acquires the
    /// terminal lock. Helpers that assume the lock is held use the `Locked`
    /// suffix and assert that contract in DEBUG builds.
    func withTerminal<T> (_ body: (Terminal) throws -> T, caller: StaticString = #function) rethrows -> T
    {
        if ProfilingStats.enabled && Thread.isMainThread {
            ProfilingLockCallers.shared.record(caller)
        }
        return try terminal.terminalLock.withLock {
            try body(terminal)
        }
    }

    /// Returns the current terminal grid size as a copied value.
    public nonisolated var terminalDimensions: TerminalDimensions {
        renderOwner.dimensions()
    }

    /// Returns copied terminal state for status displays and diagnostics.
    public nonisolated func terminalStateSnapshot() -> TerminalViewStateSnapshot {
        renderOwner.stateSnapshot()
    }

    /// Copies terminal buffer contents without exposing the mutable terminal.
    public nonisolated func getBufferAsData(
        kind: Terminal.BufferKind = .active,
        encoding: String.Encoding = .utf8
    ) -> Data {
        renderOwner.bufferData(kind: kind, encoding: encoding)
    }

    /// Returns the closest primary semantic-prompt row above the viewport.
    public nonisolated func previousSemanticPromptRow() -> Int? {
        renderOwner.semanticPromptRow(searchingUpward: true)
    }

    /// Returns the closest primary semantic-prompt row below the viewport.
    public nonisolated func nextSemanticPromptRow() -> Int? {
        renderOwner.semanticPromptRow(searchingUpward: false)
    }

    /// Performs DECSTR through the normal parser feed path.
    public nonisolated func softReset() {
        feedSender.feed(text: "\u{1b}[!p")
    }

    /// Performs RIS through the normal parser feed path.
    public nonisolated func resetToInitialState() {
        feedSender.feed(text: "\u{1b}c")
    }

    /// Strategy used to derive palette entries 16 through 255.
    public var ansi256PaletteStrategy: Ansi256PaletteStrategy {
        get { renderOwner.ansi256PaletteStrategy() }
        set {
            renderOwner.setAnsi256PaletteStrategy(newValue)
            frameSignal.markDirty()
        }
    }

    /// Maximum number of rows in one bidi paragraph.
    public var maximumBidiParagraphRows: Int {
        get { renderOwner.maximumBidiParagraphRows() }
        set {
            renderOwner.setMaximumBidiParagraphRows(newValue)
            frameSignal.markDirty()
        }
    }

    nonisolated func onMain (_ body: @escaping @MainActor @Sendable () -> Void,
                            caller: StaticString = #function)
    {
        let recordedBody: @MainActor @Sendable () -> Void = { [weak self] in
            self?.recordMainHop()
            body()
        }
        let dispatchBody: @Sendable () -> Void = {
            MainActor.assumeIsolated {
                recordedBody()
            }
        }
        if ProfilingStats.enabled {
            ProfilingHopCounter.shared.record(caller)
        }
        DispatchQueue.main.async(execute: dispatchBody)
    }

    func recordMainHop ()
    {
        diagnosticsState.withLock { $0.mainHops += 1 }
    }
    
    /// This function computes the new columns and rows for the terminal when a pixel-size changes
    /// Returns true if this changed the number of columns/rows, false otherwise
    /// Records a size for the next frame to apply, instead of resizing the
    /// terminal now.
    ///
    /// A live window drag calls `setFrameSize` on every step, and each
    /// synchronous `processSizeChange` took the terminal lock, resized, soft
    /// reset the scroll region, invalidated search and notified the delegate —
    /// which does the pty `ioctl`. Coalescing to one resize per frame is what
    /// Ghostty does with a timer on its IO thread (io-gaps.md G5b).
    ///
    /// The geometry is computed here, on main, on purpose: it reads
    /// `cellDimension` and the scroller's width, which are view state. Only
    /// the resulting cell counts cross to the frame path, which may run on the
    /// render loop.
    ///
    /// **Only use this during a live resize.** Deferring `sizeChanged` to a
    /// later frame breaks the re-entrancy guard that hosts write around it:
    ///
    /// ```swift
    /// func sizeChanged(...) {
    ///     if changingSize { return }        // never true any more
    ///     changingSize = true
    ///     window.setFrame(optimalSize, display: true, animate: true)
    ///     changingSize = false              // reset before the callback lands
    /// }
    /// ```
    ///
    /// Synchronously, the frame change re-enters `sizeChanged` inside that
    /// guard and stops. Deferred, the callback arrives a frame later with the
    /// flag already cleared, so every intermediate frame of the animation
    /// starts another animation. Measured on the resize-under-flood case:
    /// main-thread stall p99 went from 16–28 ms to 133–205 ms. MacTerminal is
    /// the host in question and the pattern is entirely ordinary.
    func queueSizeChange (newSize: CGSize) {
        if newSize.width == 0 && newSize.height == 0 {
            return
        }
        let newRows = Int (newSize.height / cellDimension.height)
        let newCols = Int (getEffectiveWidth (size: newSize) / cellDimension.width)

        renderOwner.mailbox.queueSize(cols: newCols, rows: newRows)
        frameDriver?.markDirty()
    }

    /// Resizes the terminal immediately.
    ///
    /// Still the right call for a one-off change — a font change, a
    /// programmatic resize, iOS layout — where the caller expects
    /// `terminal.cols` to be correct when it returns. The live-drag path uses
    /// `queueSizeChange` instead.
    @discardableResult
    func processSizeChange (newSize: CGSize) -> Bool {
        if newSize.width == 0 && newSize.height == 0 {
            return false
        }
        let newRows = Int (newSize.height / cellDimension.height)
        let newCols = Int (getEffectiveWidth (size: newSize) / cellDimension.width)
        
        var didResize = false
        withTerminal { terminal in
            if newCols != terminal.cols || newRows != terminal.rows {
                selection.active = false
                terminal.resize (cols: newCols, rows: newRows)
                search.invalidate ()
                didResize = true
            }
        }
        if didResize {
            accessibility.invalidate ()
            terminalDelegate?.sizeChanged (source: self, newCols: newCols, newRows: newRows)
            updateScroller()
            return true
        }
        return false
    }

    func refreshCachedViewState ()
    {
        let scale = backingScaleFactor()
        let imageScale = getImageScale()
        let pixelSize: (width: Int, height: Int)?
        let currentCellDimension: CellDimension? = cellDimension
        if let currentCellDimension {
            pixelSize = (Int(round(currentCellDimension.width * scale)), Int(round(currentCellDimension.height * scale)))
        } else {
            pixelSize = nil
        }
        let nativeColors: (foreground: Color, background: Color)?
        if _nativeFg != nil && _nativeBg != nil {
            nativeColors = (nativeForegroundColor.getTerminalColor(), nativeBackgroundColor.getTerminalColor())
        } else {
            nativeColors = nil
        }

        crossThreadState.withLock { state in
            state.cachedCellPointSize = currentCellDimension
            state.cachedImageScale = imageScale
            state.cachedCellPixelSize = pixelSize
            state.cachedNativeColors = nativeColors
        }
    }

    nonisolated func cachedCellPixelSizeValue () -> (width: Int, height: Int)?
    {
        crossThreadState.withLock { $0.cachedCellPixelSize }
    }

    nonisolated func cachedNativeColorsValue () -> (foreground: Color, background: Color)?
    {
        crossThreadState.withLock { $0.cachedNativeColors }
    }

    nonisolated func cachedImageMetricsValue () -> (cellSize: CGSize, imageScale: CGFloat)?
    {
        crossThreadState.withLock { state in
            guard let cellSize = state.cachedCellPointSize,
                  let imageScale = state.cachedImageScale else {
                return nil
            }
            return (cellSize, imageScale)
        }
    }

    nonisolated func markScrolledDirty ()
    {
        crossThreadState.withLock { $0.scrolledDirty = true }
    }

    func consumeScrolledDirty () -> Bool
    {
        crossThreadState.withLock { state in
            let dirty = state.scrolledDirty
            state.scrolledDirty = false
            return dirty
        }
    }

    private func setAccessibilityNotificationForNextFrame (_ shouldNotify: Bool) {
        renderOwner.mailbox.setAccessibilityNotification(shouldNotify)
    }
    
    // Computes the font dimensions once font.normal has been set
    func computeFontDimensions () -> CellDimension
    {
        let lineAscent = CTFontGetAscent (fontSet.normal)
        let lineDescent = CTFontGetDescent (fontSet.normal)
        let lineLeading = CTFontGetLeading (fontSet.normal)
        let cellHeight = ceil((lineAscent + lineDescent + lineLeading) * _lineSpacing)
        #if os(macOS)
        // The following is a more robust way of getting the largest ascii character width, but comes with a performance hit.
        // See: https://github.com/migueldeicaza/SwiftTerm/issues/286
        // var sizes = UnsafeMutablePointer<NSSize>.allocate(capacity: 95)
        // let ctFont = (font as CTFont)
        // var glyphs = (32..<127).map { CTFontGetGlyphWithName(ctFont, String(Unicode.Scalar($0)) as CFString) }
        // withUnsafePointer(to: glyphs[0]) { glyphsPtr in
        //     fontSet.normal.getAdvancements(NSSizeArray(sizes), forCGGlyphs: glyphsPtr, count: 95)
        // }
        // let cellWidth = (0..<95).reduce(into: 0) { partialResult, idx in
        //     partialResult = max(partialResult, sizes[idx].width)
        // }
        let glyph = fontSet.normal.glyph(withName: "W")
        let cellWidth = fontSet.normal.advancement(forGlyph: glyph).width
        #else
        let fontAttributes = [NSAttributedString.Key.font: fontSet.normal]
        let cellWidth = "W".size(withAttributes: fontAttributes).width
        #endif
        // Snap to pixel grid to avoid sub-pixel seams between adjacent cells
        let scale = backingScaleFactor()
        let snappedWidth = (cellWidth * scale).rounded() / scale
        let snappedHeight = ceil(cellHeight * scale) / scale
        return CellDimension(width: max(1, snappedWidth), height: max(min(snappedHeight, 8192), 1))
    }

    /// ``CellGeometry/baselineOffset(normalFont:cellHeight:)`` for this view's
    /// current font and cell geometry.
    var baselineOffset: CGFloat {
        let currentCellDimension: CellDimension? = cellDimension
        return CellGeometry.baselineOffset (normalFont: fontSet.normal,
                                            cellHeight: currentCellDimension?.height ?? 0)
    }

    /// Computes how to center `glyph` within its `columnWidth`-cell slot (and
    /// scale it down if its ink overflows). Returns ``GlyphSlotFit/identity`` for
    /// ordinary single-cell glyphs, so Latin text in a monospace font is rendered
    /// exactly as before and the hot path stays untouched. Shared by the
    /// CoreGraphics and Metal glyph renderers so they stay pixel-consistent.
    func glyphSlotFit (font: CTFont, glyph: CGGlyph, columnWidth: Int) -> GlyphSlotFit
    {
        let currentCellDimension: CellDimension? = cellDimension
        guard let currentCellDimension else { return .identity }
        return GlyphSlotFit.calculate(font: font, glyph: glyph,
                                      columnWidth: columnWidth,
                                      cellDimension: currentCellDimension,
                                      normalFont: fontSet.normal)
    }

    /// Policy-aware variant for host glyph-fallback runs: applies the run's
    /// ``TerminalGlyphPlacementPolicy`` to one- and multi-column glyphs. Point
    /// space, like the CoreGraphics draw path that calls it.
    func glyphSlotFit (font: CTFont, glyph: CGGlyph, columnWidth: Int,
                       policy: TerminalGlyphPlacementPolicy) -> GlyphSlotFit
    {
        let currentCellDimension: CellDimension? = cellDimension
        guard let currentCellDimension else { return .identity }
        let normalFont = fontSet.normal
        let metrics = GlyphMetrics.measure(font: font, glyph: glyph)
        let baselineFromBottom = CellGeometry.baselineOffset(
            normalFont: normalFont, cellHeight: currentCellDimension.height)
        return GlyphSlotFit.calculate(metrics: metrics,
                                      policy: policy,
                                      columnWidth: columnWidth,
                                      cellDimension: currentCellDimension,
                                      baselineFromBottom: baselineFromBottom,
                                      iconHeight: CTFontGetAscent(normalFont),
                                      renderingScale: 1)
    }

    func mapColor (color: Attribute.Color, isFg: Bool, isBold: Bool, useBrightColors: Bool = true) -> TTColor
    {
        // Reads terminal.ansiColors below; only reachable from Locked helpers.
        terminal.terminalLock.preconditionLocked()
        switch color {
        case .defaultColor:
            if isFg {
                return effectiveNativeForegroundColor
            } else {
                return effectiveNativeBackgroundColor
            }
        case .defaultInvertedColor:
            // Reverse video *swaps* the default pair, it does not invert its RGB. Inverting
            // produced the expected pixels only for a pure black/white pair; with any other
            // palette it produced a color that belongs to neither side (inverting Solarized's
            // base03 background yields a pink block), and over a translucent background it
            // produced an unreadable highlight: the block inherited the background's alpha and
            // vanished, leaving text painted in the inverse of the foreground over whatever the
            // window showed through.
            //
            // The swapped colors are forced opaque, the way Terminal.app draws reverse video
            // over a translucent background: the highlight is the one thing that must stay
            // readable at any `backgroundOpacity`.
            if isFg {
                return effectiveNativeBackgroundColor.withAlphaComponent(1)
            } else {
                return effectiveNativeForegroundColor.withAlphaComponent(1)
            }
        case .ansi256(let ansi):
            var midx: Int
            // if high - bright colors are enabled we will represent bold text by using more intense colors
            // otherwise we will reduce colors but use bold fonts
            if useBrightColors {
                midx = ansi < 7 ? (Int (ansi) + (isBold ? 8 : 0)) : Int (ansi)
            } else {
                midx = ansi > 7 ? (Int (ansi) - 8) : Int(ansi)
            }
            if let c = colors [midx] {
                return c
            }
            let tcolor = terminal.ansiColors [midx]
            let newColor = TTColor.make (color: tcolor)
            colors [midx] = newColor
            return newColor
        case .trueColor(let r, let g, let b):
            if let tc = trueColors [color] {
                return tc
            }
            let newColor = TTColor.make(red: CGFloat (r) / 255.0,
                                        green: CGFloat (g) / 255.0,
                                        blue: CGFloat (b) / 255.0,
                                        alpha: 1.0)
            // Truecolor content can use an unbounded number of distinct
            // colors; keep the cache from growing (and rehashing) forever.
            if trueColors.count >= 4096 {
                trueColors.removeAll(keepingCapacity: true)
            }
            trueColors [color] = newColor
            return newColor
        }
    }



    // Clears the cached state for colors and triggers a full display
    func colorsChanged ()
    {
        withTerminal { _ in
            colorsChangedLocked()
        }
    }

    func colorsChangedLocked ()
    {
        urlAttributes = [:]
        attributes = [:]
        terminal.terminalLock.preconditionLocked()
        // Refresh the mirror while we hold the terminal lock; every
        // reverseColors change funnels through here via colorChanged.
        // (terminalLock -> viewStateLock is the sanctioned lock order.)
        setReverseColorsActive(terminal.reverseColors)
        coreGraphicsRenderCache.clearColors()

#if os(macOS)
        if !isUsingMetalRenderer {
            layer?.backgroundColor = effectiveNativeBackgroundColor.cgColor
        }
#else
        if reverseColorsActiveValue() {
            let opacity = layer.backgroundColor?.alpha ?? 1
            if let savedBackground = reverseColorsSavedLayerBackground {
                reverseColorsSavedLayerBackground = savedBackground.copy(alpha: opacity)
            } else {
                reverseColorsSavedLayerBackground = layer.backgroundColor
            }
            layer.backgroundColor = effectiveNativeBackgroundColor.cgColor.copy(alpha: opacity)
        } else if let savedBackground = reverseColorsSavedLayerBackground {
            layer.backgroundColor = savedBackground
            reverseColorsSavedLayerBackground = nil
        }
#endif

        terminal.updateFullScreen ()
        frameDriver.markDirty()
    }

    func colorsChangedOnMain ()
    {
        // May be queued from a callback fired during Terminal.init, before
        // the constructing thread finished assigning `terminal`.
        guard terminal != nil else { return }
        withTerminal { _ in
            colorsChangedLocked()
        }
    }

    @MainActor
    func setupTextBlinking() {
        guard textBlinkObservers.isEmpty else { return }
#if os(macOS)
        textBlinkApplicationActive = NSApplication.shared.isActive
        let appCenter = NotificationCenter.default
        let becameActive = appCenter.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                  object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.textBlinkApplicationActive = true
                self?.updateTextBlinkLifecycle()
            }
        }
        let resignedActive = appCenter.addObserver(forName: NSApplication.willResignActiveNotification,
                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.textBlinkApplicationActive = false
                self?.updateTextBlinkLifecycle()
            }
        }
        textBlinkObservers.append((appCenter, becameActive))
        textBlinkObservers.append((appCenter, resignedActive))

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let accessibilityChanged = workspaceCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateTextBlinkLifecycle()
                }
            }
        textBlinkObservers.append((workspaceCenter, accessibilityChanged))
#else
        textBlinkApplicationActive = UIApplication.shared.applicationState == .active
        let center = NotificationCenter.default
        let becameActive = center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.textBlinkApplicationActive = true
                self?.updateTextBlinkLifecycle()
            }
        }
        let resignedActive = center.addObserver(forName: UIApplication.willResignActiveNotification,
                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.textBlinkApplicationActive = false
                self?.updateTextBlinkLifecycle()
            }
        }
        let motionChanged = center.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateTextBlinkLifecycle()
                }
            }
        textBlinkObservers.append((center, becameActive))
        textBlinkObservers.append((center, resignedActive))
        textBlinkObservers.append((center, motionChanged))
#endif
        updateTextBlinkLifecycle()
    }

    @MainActor
    func stopTextBlinking() {
        textBlinkTimer?.invalidate()
        textBlinkTimer = nil
        textBlinkVisible = true
        for (center, observer) in textBlinkObservers {
            center.removeObserver(observer)
        }
        textBlinkObservers.removeAll()
    }

    @MainActor
    private var textBlinkMotionReduced: Bool {
#if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
#else
        UIAccessibility.isReduceMotionEnabled
#endif
    }

    private func visibleBlinkRowsLocked(_ terminal: Terminal) -> [Int] {
        terminal.terminalLock.preconditionLocked()
        let buffer = terminal.displayBuffer
        guard !buffer.lines.isEmpty else { return [] }
        let first = max(0, buffer.yDisp)
        let last = min(buffer.lines.count, first + buffer.rows)
        guard first < last else { return [] }
        var result: [Int] = []
        for row in first..<last {
            let line = buffer.lines[row]
            for column in 0..<buffer.cols where line.packedAttribute(at: column).style.contains(.blink) {
                result.append(row)
                break
            }
        }
        return result
    }

    func visibleBlinkRows() -> [Int] {
        guard terminal != nil else { return [] }
        return withTerminal { terminal in
            visibleBlinkRowsLocked(terminal)
        }
    }

    /// Walks the snapshot for rows carrying blinking text.
    ///
    /// Called from frame preparation, which means it can run on the render
    /// loop. Its result is published to `lastBlinkRows` so the blink timer,
    /// which runs on main, never has to touch the snapshot itself.
    /// The blinking rows the last prepared frame found. Safe on any thread.
    func publishedBlinkRows() -> [Int] {
        renderOwner.mailbox.currentBlinkRows()
    }

    @MainActor
    func updateTextBlinkLifecycle(blinkRows suppliedBlinkRows: [Int]? = nil) {
        let blinkRows: [Int]
        if let suppliedBlinkRows {
            blinkRows = suppliedBlinkRows
        } else {
            blinkRows = visibleBlinkRows()
        }
        let canBlink = window != nil && textBlinkApplicationActive
            && !textBlinkMotionReduced && !blinkRows.isEmpty
        guard canBlink else {
            textBlinkTimer?.invalidate()
            textBlinkTimer = nil
            if !textBlinkVisible {
                textBlinkVisible = true
                if suppliedBlinkRows == nil {
                    invalidateTextBlinkRows(blinkRows)
                }
            }
            return
        }
        guard textBlinkTimer == nil else { return }
        textBlinkVisible = true
        let timer = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.textBlinkVisible.toggle()
                // The published copy, not the snapshot: this fires on main,
                // and the render loop may be mid-frame inside the snapshot.
                self.invalidateTextBlinkRows(self.publishedBlinkRows())
            }
        }
        textBlinkTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @MainActor
    func setTextBlinkVisibleForTesting(_ visible: Bool) {
        textBlinkTimer?.invalidate()
        textBlinkTimer = nil
        textBlinkVisible = visible
        withTerminal { terminal in
            let buffer = terminal.displayBuffer
            for row in visibleBlinkRowsLocked(terminal) {
                terminal.updateRange(borrowing: buffer, row - buffer.yDisp)
            }
        }
    }

    private func invalidateTextBlinkRows(_ absoluteRows: [Int]) {
        withTerminal { terminal in
            let buffer = terminal.displayBuffer
            for row in absoluteRows {
                terminal.updateRange(borrowing: buffer, row - buffer.yDisp)
            }
        }
        frameDriver.markDirty()
    }
    
    public nonisolated func hostCurrentDirectoryUpdated (source: Terminal)
    {
        let directory = source.hostCurrentDirectory
        onMain { [weak self] in
            guard let self else { return }
            self.terminalDelegate?.hostCurrentDirectoryUpdate(source: self, directory: directory)
        }
    }

    public nonisolated func hostCurrentDocumentUpdated (source: Terminal)
    {
        let _ = source.hostCurrentDocument
    }

    
    /// Installs the new colors as the default colors and recomputes the
    /// current and ansi palette.   This installs both the colors into the terminal
    /// engine and updates the UI accordingly.
    /// 
    /// - Parameter colors: this should be an array of 16 values that correspond to the 16 ANSI colors,
    /// if the array does not contain 16 elements, it will not do anything
    public func installColors (_ colors: [Color])
    {
        withTerminal { terminal in
            terminal.installPalette(colors: colors)
            self.colors = Array(repeating: nil, count: 256)
            self.colorsChangedLocked()
        }
    }
    
    public nonisolated func colorChanged (source: Terminal, idx: Int?)
    {
        // Fires under the terminal lock. Mirror reverseColors synchronously so
        // draw paths (and callers that assert right after feed returns) see
        // the DECSCNM flip without waiting for the main-queue hop.
        setReverseColorsActive(source.reverseColors)
        let index = idx
        onMain { [weak self] in
            guard let self else { return }
            if let index {
                self.colors [index] = nil
            } else {
                self.colors = Array(repeating: nil, count: 256)
            }
            self.colorsChangedOnMain()
        }
    }

    public nonisolated func synchronizedOutputChanged (source: Terminal, active: Bool)
    {
        // Only deactivation needs a repaint/notification: while the flag is
        // set the renderers keep showing the last frame on purpose.
        guard !active else { return }
        source.terminalLock.preconditionLocked()
        let displayBuffer = source.displayBuffer
        let position: Double
        if source.isDisplayBufferAlternate || displayBuffer.yDisp <= 0 {
            position = 0
        } else {
            let maxScrollback = displayBuffer.lines.count - displayBuffer.rows
            position = displayBuffer.yDisp >= maxScrollback
                ? 1
                : Double(displayBuffer.yDisp) / Double(maxScrollback)
        }
        onMain { [weak self] in
            guard let self else { return }
            self.updateScroller()
            self.frameDriver.markDirty()
            self.terminalDelegate?.scrolled(source: self, position: position)
        }
    }

    public nonisolated func setBackgroundColor(source: Terminal, color: Color) {
        let nativeColor = TTColor.make(color: color)
        onMain { [weak self] in
            guard let self else { return }
            self.setNativeBackgroundColorFromTerminal(nativeColor)
            self.colorsChangedOnMain()
        }
    }
    
    public nonisolated func setForegroundColor(source: Terminal, color: Color) {
        let nativeColor = TTColor.make(color: color)
        onMain { [weak self] in
            guard let self else { return }
            self.setNativeForegroundColorFromTerminal(nativeColor)
            self.colorsChangedOnMain()
        }
    }
    
    /// Sets the color for the cursor block, and the text when it is under that cursor in block mode
    public func setCursorColor(source: Terminal, color: Color?, textColor: Color?) {
        let nativeColor = color.map { TTColor.make(color: $0) }
        let nativeTextColor = textColor.map { TTColor.make(color: $0) }
        onMain { [weak self] in
            guard let self else { return }
            if let nativeColor {
                self.cursorColorIsDefault = false
                self.caretColor = nativeColor
            } else if let caretView = self.caretView {
                self.cursorColorIsDefault = true
                caretView.caretColor = caretView.defaultCaretColor
            }
            if let nativeTextColor {
                self.cursorTextColorIsDefault = false
                self.caretTextColor = nativeTextColor
            } else if let caretView = self.caretView {
                self.cursorTextColorIsDefault = true
                caretView.caretTextColor = caretView.defaultCaretTextColor
            }
#if canImport(MetalKit) && os(macOS)
            self.frameDriver.markDirty()
#endif
        }
    }

    public nonisolated func getColors (source: Terminal) -> (foreground: Color, background: Color)
    {
        cachedNativeColorsValue() ?? (source.foregroundColor, source.backgroundColor)
    }

    public nonisolated func notify(source: Terminal, title: String, body: String)
    {
        let capturedTitle = title
        let capturedBody = body
        onMain {
            let _ = capturedTitle
            let _ = capturedBody
        }
    }
    
    //
    // Given a vt100 attribute, return the NSAttributedString attributes used to render it
    //
    func getAttributes (_ attribute: Attribute, withUrl: Bool) -> [NSAttributedString.Key:Any]?
    {
        if let result = withUrl ? urlAttributes [attribute] : attributes [attribute] {
            return result
        }

        let flags = attribute.style
        var bg = attribute.bg
        var fg = attribute.fg

        if flags.contains (.inverse) {
            swap (&bg, &fg)

            if fg == .defaultColor {
                fg = .defaultInvertedColor
            }
            if bg == .defaultColor {
                bg = .defaultInvertedColor
            }
        }
        
        var useBoldForBrightColor: Bool = false
        // if high - bright colors are disabled in settings we will use bold font instead
        if case .ansi256(let code) = fg, code > 7, !useBrightColors {
            useBoldForBrightColor = true
        }
        var tf: TTFont
        let isBold = flags.contains(.bold)
        
        if isBold || useBoldForBrightColor {
            if flags.contains (.italic) {
                tf = fontSet.boldItalic
            } else {
                tf = fontSet.bold
            }
        } else if flags.contains (.italic) {
            tf = fontSet.italic
        } else {
            tf = fontSet.normal
        }
        
        var fgColor = mapColor (color: fg, isFg: true, isBold: isBold, useBrightColors: useBrightColors)
        let bgColor = mapColor (color: bg, isFg: false, isBold: false)
        // Apply dim/faint attribute (SGR 2)
        if flags.contains (.dim) {
            fgColor = fgColor.dimmedColor (towards: bgColor)
        }
        var nsattr: [NSAttributedString.Key:Any] = [
            .font: tf,
            .foregroundColor: fgColor,
            .backgroundColor: bgColor
        ]
        if flags.contains (.underline) {
            let underlineColor = attribute.underlineColor.map {
                mapColor(color: $0, isFg: true, isBold: isBold, useBrightColors: useBrightColors)
            } ?? fgColor
            let underlineVariant = attribute.underlineStyle == .none ? .single : attribute.underlineStyle
            nsattr [.underlineColor] = underlineColor
            nsattr [.underlineStyle] = nsUnderlineStyle(underlineVariant).rawValue
            nsattr [SwiftTermUnderlineStyleKey] = Int(underlineVariant.rawValue)
        }
        if flags.contains (.crossedOut) {
            nsattr [.strikethroughColor] = fgColor
            nsattr [.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        if withUrl {
            nsattr [.underlineStyle] = NSUnderlineStyle.single.rawValue
            nsattr [.underlineColor] = fgColor
            nsattr [SwiftTermUnderlineStyleKey] = Int(UnderlineStyle.dashed.rawValue)

            // Add to cache; truecolor attributes are unbounded, so cap it
            if urlAttributes.count >= 4096 {
                urlAttributes.removeAll(keepingCapacity: true)
            }
            urlAttributes [attribute] = nsattr
        } else {
            // Just add to cache; truecolor attributes are unbounded, so cap it
            if attributes.count >= 4096 {
                attributes.removeAll(keepingCapacity: true)
            }
            attributes [attribute] = nsattr
        }
        return nsattr
    }




    nonisolated private func kittyImageFromRgba(bytes: [UInt8], width: Int, height: Int) -> TTImage? {
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.last.rawValue)
        let data = Data(bytes)
        guard let providerRef = CGDataProvider(data: data as CFData) else {
            return nil
        }
        guard let cgimage = CGImage(width: width,
                                    height: height,
                                    bitsPerComponent: 8,
                                    bitsPerPixel: 32,
                                    bytesPerRow: width * 4,
                                    space: rgbColorSpace,
                                    bitmapInfo: bitmapInfo,
                                    provider: providerRef,
                                    decode: nil,
                                    shouldInterpolate: true,
                                    intent: .defaultIntent) else {
            return nil
        }
        return TTImage(cgImage: cgimage, size: CGSize(width: width, height: height))
    }

    private func kittyAspectFitRect(imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, rect.width > 0, rect.height > 0 else {
            return rect
        }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: rect.origin.x + (rect.width - width) / 2,
                      y: rect.origin.y + (rect.height - height) / 2,
                      width: width,
                      height: height)
    }
    
    //
    // Helper used by buildAttributedString to construct segments.
    //
    struct ViewLineSegmentBuilder {
        let column: Int
        let columnWidth: Int
        private var attributedString = NSMutableAttributedString()
        private var characterCount: Int = 0
        private var utf16ToCellOrdinal: [Int] = []
        private var cellCount: Int = 0
        private var utf16IsCellIdentity = true
        
        init(column: Int, columnWidth: Int) {
            self.column = column
            self.columnWidth = columnWidth
        }
        
        var isEmpty: Bool {
            characterCount == 0
        }
        
        /// Appends a batch of text; `cellUTF16Lengths` holds one entry per
        /// terminal cell in the batch (its text length in UTF-16 units).
        mutating func append(text: String, attributes: SnapshotTextAttributes,
                             cellUTF16Lengths: [Int]) {
            let location = attributedString.length
            let length = text.utf16.count
            let mutableString = attributedString as CFMutableAttributedString
            CFAttributedStringReplaceString(
                mutableString,
                CFRange(location: location, length: 0),
                text as CFString)
            if length > 0 {
                CFAttributedStringSetAttributes(
                    mutableString,
                    CFRange(location: location, length: length),
                    attributes.objectiveC as CFDictionary,
                    true)
            }
            characterCount += 1
            for length in cellUTF16Lengths {
                let units = max(1, length)
                if units != 1 {
                    utf16IsCellIdentity = false
                }
                for _ in 0..<units {
                    utf16ToCellOrdinal.append(cellCount)
                }
                cellCount += 1
            }
        }

        func buildIfNeeded() -> ViewLineSegment? {
            guard !isEmpty else {
                return nil
            }
            return ViewLineSegment(column: column, columnWidth: columnWidth, characterCount: characterCount, attributedString: attributedString, utf16ToCellOrdinal: utf16ToCellOrdinal, utf16IsCellIdentity: utf16IsCellIdentity)
        }
    }
    
    //
    // Given a line of text with attributes, returns column-aware segments that can be drawn later.
    //
    func buildAttributedStringLocked (row: Int, line: BufferLine, cols: Int) -> ViewLineInfo
    {
        terminal.terminalLock.preconditionLocked()
        let snapshotRow = TerminalSnapshot.Row(source: line, borrowing: true)
        snapshotRow.sourceGeneration = line.generation
        snapshotRow.bidiParagraphRevision = TerminalBidi.layoutRevision(
            row: row, buffer: terminal.displayBuffer,
            maximumRows: terminal.options.maximumBidiParagraphRows)
        snapshotRow.bidiLayout = TerminalBidi.layout(
            row: row, buffer: terminal.displayBuffer, cols: cols,
            terminal: terminal, font: fontSet.normal, hostPolicy: bidiHostPolicy)
        snapshotRow.needsDirectionOverride = snapshotRow.bidiLayout != nil ||
            TerminalBidi.mayNeedBidi(line: line, cols: cols, terminal: terminal)
        var column = 0
        while column < min(cols, line.count) {
            let cell = line.packedView(at: column)
            if !cell.isSimpleRune {
                snapshotRow.resolvedCharacters[column] = cell.getCharacter()
            }
            column += max(1, Int(cell.width))
        }
        let liveStyle = SnapshotStyle(
            selectionActive: selection?.active == true,
            selectionStart: selection?.start ?? Position(col: 0, row: 0),
            selectionEnd: selection?.end ?? Position(col: 0, row: 0),
            linkHighlightRange: linkHighlightRange,
            linkHighlightMode: linkHighlightMode,
            commandActive: commandActive,
            textBlinkVisible: textBlinkVisible)
        let context = SnapshotRenderContext(viewState: FrameViewState(view: self),
                                            style: liveStyle,
                                            ansiColors: terminal.ansiColors, cols: cols)
        var result = textBuilder.buildAttributedString(row: snapshotRow, absoluteRow: row,
                                                       context: context)
        result.images = line.images
        return result
    }
    // The payload contains terminal data expected to be in the form:
    // "k=v:k2=v2;URL"
    func urlAndParamsFrom(payload: String) -> (String, [String:String])?
    {
        let split = payload.split(separator: ";", maxSplits: Int.max, omittingEmptySubsequences: false)
        if split.count > 1 {
            let pairs = split[0].split(separator: ":")
            var params: [String:String] = [:]
            for p in pairs {
                let kv = p.split(separator: "=")
                if kv.count == 2 {
                    params[String(kv[0])] = String(kv[1])
                }
            }
            return (String(split[1]), params)
        }
        return nil
    }

    func payloadString(at position: Position) -> String?
    {
        withTerminal { _ in
            payloadStringLocked(at: position)
        }
    }

    func payloadStringLocked(at position: Position) -> String?
    {
        terminal.terminalLock.preconditionLocked()
        let buffer = terminal.displayBuffer
        guard position.row >= 0 && position.row < buffer.lines.count else {
            return nil
        }
        let line = buffer.lines[position.row]
        let maxCol = max(0, min(terminal.cols - 1, line.count - 1))
        let col = max(0, min(position.col, maxCol))
        let cell = line.packedView(at: col)
        if let payload = cell.getPayload() as? String {
            return payload
        }
        if cell.code == 0 && col > 0 && line.packedWidth(at: col - 1) == 2 {
            let base = line.packedView(at: col - 1)
            if let payload = base.getPayload() as? String {
                return payload
            }
        }
        return nil
    }

    func invalidateLinkHighlight(oldRange: [Terminal.LinkMatch.RowRange]?, newRange: [Terminal.LinkMatch.RowRange]?)
    {
        let oldRows = Set(oldRange?.map(\.row) ?? [])
        let newRows = Set(newRange?.map(\.row) ?? [])
        for row in oldRows.union(newRows) {
            invalidateLinkHighlightRow(row)
        }
    }

    func invalidateLinkHighlightRow(_ bufferRow: Int)
    {
        withTerminal { _ in
            invalidateLinkHighlightRowLocked(bufferRow)
        }
    }

    func invalidateLinkHighlightRowLocked(_ bufferRow: Int)
    {
        terminal.terminalLock.preconditionLocked()
        let displayBuffer = terminal.displayBuffer
        let screenRow = bufferRow - displayBuffer.yDisp
        guard screenRow >= 0 && screenRow < terminal.rows else {
            return
        }
        terminal.updateRange(borrowing: displayBuffer, screenRow)
    }

    func linkVisibleForClick(match: Terminal.LinkMatch, hasCommandModifier: Bool) -> Bool
    {
        switch linkHighlightMode {
        case .always:
            return match.isExplicit
        case .alwaysWithModifier:
            return match.isExplicit && hasCommandModifier
        case .hover:
            return linkHighlightRange == match.rowRanges
        case .hoverWithModifier:
            return hasCommandModifier && linkHighlightRange == match.rowRanges
        }
    }

    /// Whether an implicit (regex-detected) match could possibly be accepted by
    /// `linkVisibleForClick` under the current highlight mode. Implicit detection runs a
    /// backtracking-prone regular expression over the whole wrapped line group, so when the
    /// result is guaranteed to be discarded we must not pay for it. Mirrors the early-out
    /// `updateHoverLink` already performs on the hover path.
    func implicitLinkCouldBeVisible(hasCommandModifier: Bool) -> Bool
    {
        switch linkHighlightMode {
        case .always, .alwaysWithModifier:
            // Both branches return `match.isExplicit`, so an implicit match never qualifies.
            return false
        case .hover:
            return linkHighlightRange != nil
        case .hoverWithModifier:
            return hasCommandModifier && linkHighlightRange != nil
        }
    }

    func linkForClick(at position: Position, hasCommandModifier: Bool) -> (link: String, params: [String:String])?
    {
        withTerminal { _ in
            linkForClickLocked(at: position, hasCommandModifier: hasCommandModifier)
        }
    }

    func linkForClickLocked(at position: Position, hasCommandModifier: Bool) -> (link: String, params: [String:String])?
    {
        terminal.terminalLock.preconditionLocked()
        let mode: Terminal.LinkLookupMode = implicitLinkCouldBeVisible(hasCommandModifier: hasCommandModifier)
            ? .explicitAndImplicit
            : .explicitOnly
        guard let match = terminal.linkMatch(at: .buffer(position), mode: mode) else {
            return nil
        }
        guard linkVisibleForClick(match: match, hasCommandModifier: hasCommandModifier) else {
            return nil
        }
        if match.isExplicit,
           let payload = payloadStringLocked(at: position),
           let (url, params) = urlAndParamsFrom(payload: payload) {
            return (url, params)
        }
        return (match.text, [:])
    }
    
    /// Returns the selection range for the specified row, if any.
    func selectedColumnsRange(row: Int, cols: Int) -> Range<Int>? {
        terminal.terminalLock.preconditionLocked()
        guard let selection = self.selection, selection.active else {
            return nil
        }

        let startRow = selection.start.row
        let endRow = selection.end.row
        let startCol = selection.start.col
        let endCol = selection.end.col

        var selectionRange: NSRange = .empty

        // single row
        if endRow == startRow && startRow == row {
            if startCol < endCol {
                let extra = endCol == terminal.cols-1 ? 1 : 0
                selectionRange = NSRange(location: startCol, length: endCol - startCol + extra)
            } else if startCol > endCol {
                selectionRange = NSRange(location: endCol, length: startCol - endCol)
            }
        } else if endRow > startRow {
            // first row
            if startRow == row && endRow > row {
                selectionRange = NSRange(location: startCol, length: cols - startCol)
            }

            // in between
            if startRow < row && endRow > row {
                selectionRange = NSRange(location: 0, length: cols)
            }

            // last row
            if startRow < row && endRow == row {
                let extra = endCol == terminal.cols-1 ? 1 : 0
                selectionRange = NSRange(location: 0, length: endCol + extra)
            }
        } else if endRow < startRow {
            // first row
            if endRow == row && startRow > row {
                selectionRange = NSRange(location: endCol, length: cols - endCol)
            }

            // in between
            if startRow > row && endRow < row {
                selectionRange = NSRange(location: 0, length: cols)
            }

            // last row
            if endRow < row && startRow == row {
                let extra = startCol == terminal.cols-1 ? 1 : 0
                selectionRange = NSRange(location: 0, length: startCol + extra)
            }
        }

        if selectionRange == .empty || selectionRange.length == 0 {
            return nil
        }

        let lowerBound = max(0, min(selectionRange.location, cols))
        let upperBound = max(lowerBound, min(cols, selectionRange.location + selectionRange.length))
        if lowerBound == upperBound {
            return nil
        }
        return lowerBound..<upperBound
    }
    

    func drawRunAttributes(_ attributes: [NSAttributedString.Key : Any], glyphPositions positions: [CGPoint], in currentContext: CGContext) {
        currentContext.saveGState()

        let scale = backingScaleFactor()

        if attributes.keys.contains(.underlineStyle) {
            // draw underline at font.normal.underlinePosition baseline
            let underlineColor = attributes[.underlineColor] as? TTColor ?? effectiveNativeForegroundColor
            let underlinePosition = fontSet.underlinePosition ()
            let underlineThickness = max(round(scale * fontSet.underlineThickness ()) / scale, 0.5)
            let dashLength = max(underlineThickness * 2, 2)
            let dotLength = max(underlineThickness, 1)

            func resolveUnderlineStyle(_ attributes: [NSAttributedString.Key: Any]) -> UnderlineStyle {
                if let raw = attributes[SwiftTermUnderlineStyleKey] as? Int,
                   let style = UnderlineStyle(rawValue: UInt8(raw)) {
                    return style
                }
                let rawStyle = attributes[.underlineStyle] as? NSUnderlineStyle.RawValue ?? 0
                let underlineStyle = NSUnderlineStyle(rawValue: rawStyle)
                if underlineStyle.contains(.double) {
                    return .double
                }
                if underlineStyle.contains(.patternDot) {
                    return .dotted
                }
                if underlineStyle.contains(.patternDash) || underlineStyle.contains(.patternDashDot) || underlineStyle.contains(.patternDashDotDot) {
                    return .dashed
                }
                return underlineStyle.isEmpty ? .none : .single
            }

            func strokePatternedLine(from start: CGPoint, to end: CGPoint, thickness: CGFloat, style: UnderlineStyle) {
                let path = TTBezierPath()
                path.move(to: start)
                path.addLine(to: end)
                path.lineWidth = thickness
                switch style {
                case .dashed:
                    let pattern: [CGFloat] = [dashLength]
                    path.setLineDash(pattern, count: pattern.count, phase: 0)
                case .dotted:
                    let pattern: [CGFloat] = [dotLength, dotLength * 2]
                    path.lineCapStyle = .round
                    path.setLineDash(pattern, count: pattern.count, phase: 0)
                default:
                    break
                }
                path.stroke()
            }

            func strokeWavyLine(from start: CGPoint, to end: CGPoint, thickness: CGFloat) {
                let amplitude = max(thickness, 1)
                let wavelength = max(thickness * 4, 4)
                let step = max(thickness, 1)
                let path = TTBezierPath()
                path.lineWidth = thickness
                var x = start.x
                path.move(to: CGPoint(x: start.x, y: start.y))
                while x <= end.x {
                    let phase = Double((x - start.x) / wavelength * (CGFloat.pi * 2))
                    let y = start.y + amplitude * CGFloat(sin(phase))
                    path.addLine(to: CGPoint(x: x, y: y))
                    x += step
                }
                path.stroke()
            }

            let underlineStyle = resolveUnderlineStyle(attributes)

            currentContext.setShouldAntialias(false)
            currentContext.setStrokeColor(coreGraphicsRenderCache.cgColor(for: underlineColor))

            for p in positions {
                let start = p.applying(.init(translationX: 0, y: underlinePosition))
                let end = p.applying(.init(translationX: ceil(cellDimension.width), y: underlinePosition))
                switch underlineStyle {
                case .none:
                    break
                case .double:
                    strokePatternedLine(from: start, to: end, thickness: underlineThickness, style: .single)
                    let offset = underlineThickness + 1
                    let start2 = p.applying(.init(translationX: 0, y: underlinePosition - offset))
                    let end2 = p.applying(.init(translationX: ceil(cellDimension.width), y: underlinePosition - offset))
                    strokePatternedLine(from: start2, to: end2, thickness: underlineThickness, style: .single)
                case .curly:
                    strokeWavyLine(from: start, to: end, thickness: underlineThickness)
                case .dotted, .dashed, .single:
                    strokePatternedLine(from: start, to: end, thickness: underlineThickness, style: underlineStyle)
                }
            }
        }

        if attributes.keys.contains(.strikethroughStyle) {
            let strikeStyle = NSUnderlineStyle(rawValue: attributes[.strikethroughStyle] as? NSUnderlineStyle.RawValue ?? 0)
            let strikeColor = attributes[.strikethroughColor] as? TTColor ?? effectiveNativeForegroundColor
            let font = (attributes[.font] as? TTFont) ?? fontSet.normal
            let ctFont = font as CTFont
            let strikeThickness = max(round(scale * CTFontGetUnderlineThickness(ctFont)) / scale, 0.5)
            let strikePosition = (CTFontGetXHeight(ctFont) + strikeThickness) * 0.5

            currentContext.setShouldAntialias(false)
            currentContext.setStrokeColor(coreGraphicsRenderCache.cgColor(for: strikeColor))

            for p in positions {
                let path = TTBezierPath()
                path.move(to: p.applying(.init(translationX: 0, y: strikePosition)))
                path.addLine(to: p.applying(.init(translationX: ceil(cellDimension.width), y: strikePosition)))
                path.lineWidth = strikeThickness

                if strikeStyle.contains(.patternDash) {
                    let pattern: [CGFloat] = [2.0]
                    path.setLineDash(pattern, count: pattern.count, phase: 0)
                }
                path.stroke()

                if strikeStyle.contains(.double) {
                    let path2 = TTBezierPath()
                    let offset = strikeThickness + 1
                    path2.move(to: p.applying(.init(translationX: 0, y: strikePosition - offset)))
                    path2.addLine(to: p.applying(.init(translationX: ceil(cellDimension.width), y: strikePosition - offset)))
                    path2.lineWidth = strikeThickness
                    if strikeStyle.contains(.patternDash) {
                        let pattern: [CGFloat] = [2.0]
                        path2.setLineDash(pattern, count: pattern.count, phase: 0)
                    }
                    path2.stroke()
                }
            }
        }
        currentContext.restoreGState()
    }

    private func alignToPixel(_ value: CGFloat, scale: CGFloat, rule: FloatingPointRoundingRule) -> CGFloat {
        guard scale > 0 else {
            return value
        }
        return (value * scale).rounded(rule) / scale
    }

    private func pixelAlignedRect(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let minX = alignToPixel(rect.minX, scale: scale, rule: .down)
        let maxX = alignToPixel(rect.maxX, scale: scale, rule: .up)
        let minY = alignToPixel(rect.minY, scale: scale, rule: .down)
        let maxY = alignToPixel(rect.maxY, scale: scale, rule: .up)
        return CGRect(x: minX,
                      y: minY,
                      width: max(0, maxX - minX),
                      height: max(0, maxY - minY))
    }

    private func drawBlockElements(_ elements: [BlockElementRenderItem], lineOrigin: CGPoint, in context: CGContext) {
        guard !elements.isEmpty else {
            return
        }
        context.saveGState()
        let useAntialias = antiAliasCustomBlockGlyphs
        context.setShouldAntialias(useAntialias)
        context.setAllowsAntialiasing(useAntialias)

        let scale = backingScaleFactor()
        let cellHeight = cellDimension.height

        for element in elements {
            let cellWidth = cellDimension.width * CGFloat(element.columnWidth)
            let cellOrigin = CGPoint(x: lineOrigin.x + CGFloat(element.column) * cellDimension.width,
                                     y: lineOrigin.y)
            let xEighth = cellWidth / 8.0
            let yEighth = cellHeight / 8.0
            let baseAlpha = element.foregroundColor.cgColor.alpha

            for rect in element.rects {
                var drawRect = rect.rect(in: cellOrigin, xEighth: xEighth, yEighth: yEighth, cellHeight: cellHeight)
                if !useAntialias {
                    drawRect = pixelAlignedRect(drawRect, scale: scale)
                }
                if drawRect.width <= 0 || drawRect.height <= 0 {
                    continue
                }
                let resolvedAlpha = max(0, min(1, baseAlpha * rect.alpha.rawValue))
                let fillColor = element.foregroundColor.withAlphaComponent(resolvedAlpha)
                context.setFillColor(fillColor.cgColor)
                context.fill(drawRect)
            }
        }
        context.restoreGState()
    }

    private func drawBoxDrawings(_ items: [BoxDrawingRenderItem], lineOrigin: CGPoint, in context: CGContext) {
        guard !items.isEmpty else {
            return
        }
        context.saveGState()
        context.setShouldAntialias(false)
        context.setAllowsAntialiasing(false)

        let scale = backingScaleFactor()
        let boxThicknessScale: CGFloat = 1.35
        let minThicknessPx = max(1, Int(round(scale)))
        let baseThicknessPx = max(minThicknessPx,
                                  Int(round(scale * fontSet.underlineThickness() * boxThicknessScale)))
        let baseCellWidthPx = max(1, Int(round(cellDimension.width * scale)))
        let baseCellHeightPx = max(1, Int(round(cellDimension.height * scale)))
        let cellHeight = CGFloat(baseCellHeightPx) / scale
        let lineOriginPxX = round(lineOrigin.x * scale)
        let lineOriginPxY = round(lineOrigin.y * scale)

        for item in items {
            let cellWidthPx = baseCellWidthPx * item.columnWidth
            let cellWidth = CGFloat(cellWidthPx) / scale
            let cellOrigin = CGPoint(x: (lineOriginPxX + CGFloat(item.column * baseCellWidthPx)) / scale,
                                     y: lineOriginPxY / scale)
            let baseAlpha = item.foregroundColor.cgColor.alpha
            let resolvedAlpha = max(0, min(1, baseAlpha))
            let color = item.foregroundColor.withAlphaComponent(resolvedAlpha)
            BoxDrawingRenderer.draw(codePoint: item.codePoint,
                                    in: context,
                                    cellOrigin: cellOrigin,
                                    cellSize: CGSize(width: cellWidth, height: cellHeight),
                                    scale: scale,
                                    color: color,
                                    baseThicknessPx: baseThicknessPx)
        }

        context.restoreGState()
    }

    private func drawPowerlineGlyphs(_ items: [PowerlineRenderItem],
                                     lineOrigin: CGPoint,
                                     renderMode: BufferLine.RenderLineMode,
                                     in context: CGContext) {
        guard !items.isEmpty else { return }
        let scale = backingScaleFactor()
        let scaleX = renderMode == .single ? scale : scale * 2
        let scaleY: CGFloat
        switch renderMode {
        case .doubledDown, .doubledTop: scaleY = scale * 2
        case .single, .doubleWidth: scaleY = scale
        }
        for item in items {
            let cellRect = CGRect(x: lineOrigin.x + CGFloat(item.column) * cellDimension.width,
                                  y: lineOrigin.y,
                                  width: CGFloat(item.columnWidth) * cellDimension.width,
                                  height: cellDimension.height)
            PowerlineRenderer.draw(codePoint: item.codePoint,
                                   in: context,
                                   cellRect: cellRect,
                                   scaleX: scaleX,
                                   scaleY: scaleY,
                                   color: item.foregroundColor.cgColor)
        }
    }

    
    // TODO: this should not render any lines outside the dirtyRect
    func drawTerminalContents (dirtyRect: TTRect, context: CGContext, bufferOffset: Int)
    {
        // The Core Graphics draw: glyph shaping and painting from the snapshot,
        // with no terminal lock held. The Metal path has its own Metal.Draw
        // signpost. Without this interval a main-thread stall cannot be
        // attributed, because the frame tick and the lock are both far too
        // short to explain the stalls the baselines show.
        let drawInterval = Profiling.begin(.frameDraw)
        defer { drawInterval.end() }
        diagnosticsState.withLock { $0.renders += 1 }

        guard let viewState = captureFrameViewState() else { return }
        let kittyCellWidth = cellDimension.width
        let kittyCellHeight = cellDimension.height
        let kittyImageScale = getImageScale()
        renderOwner.withSnapshotForDrawing(viewState: viewState) { snapshot, renderContext in
        let yOffset = renderContext.baselineOffset
        #if os(macOS)
        let renderBufferOffset = snapshot.yDisp
        #else
        let renderBufferOffset = bufferOffset
        #endif
        let frameCellHeight = cellDimension.height

        func calcLineOffset (forRow: Int) -> CGFloat {
            frameCellHeight * CGFloat (forRow-renderBufferOffset+1)
        }
        // draw lines
        #if os(iOS) || os(visionOS)
        // On iOS, use contentOffset.y to determine the first visible row rather than
        // dirtyRect.minY. UIKit coalesces dirty rects across scroll and data updates and
        // can deliver a rect with minY=0 even when the scroll position (contentOffset.y)
        // is non-zero. This causes SwiftTerm to draw scrollback-buffer rows at viewport
        // positions, producing garbled output. contentOffset.y is always correct because
        // the scroll view is kept in sync with yDisp (contentOffset.y == yDisp * cellHeight).
        let cellHeight = cellDimension.height
        let firstRow = Int(contentOffset.y / cellHeight)
        let lastRow = firstRow + Int(ceil(bounds.height / cellHeight))
        #else
        // On Mac, we are drawing the terminal buffer
        let cellHeight = cellDimension.height
        let boundsMaxY = bounds.maxY
        let firstRow = snapshot.yDisp+Int ((boundsMaxY-dirtyRect.maxY)/cellHeight)
        let lastRow = snapshot.yDisp+Int((boundsMaxY-dirtyRect.minY)/cellHeight)
        #endif

        let kittyRenderSnapshot = snapshot.kitty.renderSnapshot
        let virtualPlacementsByImageId = Dictionary(
            grouping: kittyRenderSnapshot.placements.filter(\.isVirtual),
            by: \.imageId)

        // Drop the crops that this snapshot can no longer use - a removed
        // placement, a new animation frame, a new visible source rectangle -
        // and keep the rest for the placements this pass does not repaint.
        var liveKittyImageKeys = Set<KittyPlacementImageKey>()
        liveKittyImageKeys.reserveCapacity(kittyRenderSnapshot.placements.count)
        for placement in kittyRenderSnapshot.placements {
            guard let image = kittyRenderSnapshot.imagesById[placement.imageId] else { continue }
            liveKittyImageKeys.insert(KittyPlacementImageKey(
                token: placement.token,
                contentGeneration: image.contentGeneration,
                source: placement.visibleSource))
        }
        kittyPlacementImageCache.withLock { cache in
            if cache.contains(where: { !liveKittyImageKeys.contains($0.key) }) {
                cache = cache.filter { liveKittyImageKeys.contains($0.key) }
            }
        }

        func kittyRenderImage(_ placement: KittyGraphicsRenderPlacement) -> TTImage? {
            guard let image = kittyRenderSnapshot.imagesById[placement.imageId] else {
                return nil
            }
            let source = placement.visibleSource
            let key = KittyPlacementImageKey(
                token: placement.token,
                contentGeneration: image.contentGeneration,
                source: source)
            if let cached = kittyPlacementImageCache.withLock({ $0[key] }) { return cached }
            var rgba = [UInt8]()
            rgba.reserveCapacity(source.width * source.height * 4)
            for row in source.y..<(source.y + source.height) {
                let start = (row * image.width + source.x) * 4
                let end = start + source.width * 4
                rgba.append(contentsOf: image.rgba[start..<end])
            }
            guard let decoded = kittyImageFromRgba(
                bytes: rgba, width: source.width, height: source.height) else { return nil }
            kittyPlacementImageCache.withLock { $0[key] = decoded }
            return decoded
        }

        func drawKittyPlacements(
            onScreenRow screenRow: Int,
            lineOrigin: CGPoint,
            belowText: Bool
        ) {
            let offsetScale = kittyImageScale
            let lineRect = CGRect(
                x: 0, y: lineOrigin.y,
                width: CGFloat(snapshot.cols) * kittyCellWidth,
                height: kittyCellHeight)
            for placement in kittyRenderSnapshot.placements where !placement.isVirtual {
                guard (placement.zIndex < 0) == belowText else { continue }
                let geometry = placement.geometry
                guard screenRow >= geometry.row,
                      screenRow < geometry.row + geometry.rows,
                      let image = kittyRenderImage(placement) else { continue }
                let offsetX = CGFloat(placement.pixelOffsetX) / offsetScale
                let offsetY = CGFloat(placement.pixelOffsetY) / offsetScale
                let rowsBelow = geometry.row + geometry.rows - 1 - screenRow
                let rect = CGRect(
                    x: CGFloat(geometry.column) * kittyCellWidth + offsetX,
                    y: lineOrigin.y - CGFloat(rowsBelow) * kittyCellHeight + offsetY,
                    width: max(0, CGFloat(geometry.columns) * kittyCellWidth - offsetX),
                    height: max(0, CGFloat(geometry.rows) * kittyCellHeight - offsetY))
                guard rect.width > 0, rect.height > 0 else { continue }
                context.saveGState()
                context.clip(to: lineRect)
                image.draw(in: rect)
                context.restoreGState()
            }
        }

        #if os(macOS)
        // Clear the invalidated region before painting. We fill only cells that carry
        // an explicit background; default-background cells rely on transparent backing-
        // store pixels showing the layer's background color. AppKit clears the backing
        // store only on a full-view redraw, so a partial repaint (a restricted DECSTBM
        // scroll region, line insert/delete) otherwise keeps stale glyphs/backgrounds.
        // Clear to transparent — not fill — so a translucent background is preserved.
        context.clear(dirtyRect)
        #endif

        for row in firstRow...lastRow {
            if row < 0 {
                continue
            }
            guard let snapshotRow = snapshot.row(atAbsolute: row) else {
                continue
            }
            let renderMode = snapshotRow.line.renderMode
            let lineOffset = calcLineOffset(forRow: row)
            let lineOrigin = CGPoint(x: 0, y: frame.height - lineOffset)

            switch renderMode {
            case .single:
                break
            case .doubledDown:
                context.saveGState()
                let pivot = lineOrigin.y
                let lineRect = CGRect (origin: CGPoint (x: 0, y: lineOrigin.y), size: CGSize (width: dirtyRect.width, height: cellDimension.height))
                context.clip(to: [lineRect])
                // Debug aid
                //  context.setFillColor(CGColor(red: 0, green: Double (row)/25.0, blue: 0, alpha: 1))
                // context.fill([lineRect])

                context.translateBy(x: 0, y: pivot)
                context.scaleBy (x: 2, y: 2)
                context.translateBy(x: 0, y: -pivot)

            case .doubledTop:
                context.saveGState()
                let pivot = lineOrigin.y + cellDimension.height
                let lineRect = CGRect (origin: CGPoint (x: 0, y: lineOrigin.y), size: CGSize (width: dirtyRect.width, height: cellDimension.height))

                context.clip(to: [lineRect])
                
                // Debug Aid
                //context.setFillColor(CGColor(red: Double (row)/25.0, green: 0, blue: 0, alpha: 1))
                //context.fill([lineRect])

                context.translateBy(x: 0, y: pivot)
                context.scaleBy (x: 2, y: 2)
                context.translateBy(x: 0, y: -pivot)
                
            case .doubleWidth:
                context.saveGState()
                context.scaleBy (x: 2, y: 1)
            }
            #if false
            // This optimization is useful, but only if we can get proper exposed regions
            // and while it works most of the time with the BigSur change, there is still
            // a case where we just get full exposes despite requesting only a line
            // repro: fill 300 lines, then clear screen then repeatedly output commands
            // that produce 3-5 lines of text: while we send AppKit the right boundary,
            // AppKit still send everything.  
            let lineRect = CGRect (origin: lineOrigin, size: CGSize (width: dirtyRect.width, height: cellDimension.height))
            
            if !lineRect.intersects(dirtyRect) {
                //print ("Skipping row \(row) because it does nto intersect")
                continue
            } 
            #endif
            let lineInfo = textBuilder.buildAttributedString(row: snapshotRow, absoluteRow: row,
                                                             context: renderContext)
            let rowBase = lineOrigin.y + cellDimension.height
            var otherImages: [SnapshotImage] = []
            if let images = lineInfo.images {
                for basicImage in images {
                    guard let image = basicImage as? SnapshotImage else {
                        continue
                    }
                    otherImages.append(image)
                }
            }

            // Pre-create CTLines and runs once per row to avoid duplicate
            // creation, and extract the attribute values both draw passes need
            // once per run: bridging the whole attribute dictionary per pass is
            // far more expensive than these keyed lookups.
            let runAttributeKeys = coreGraphicsRenderCache.runAttributeKeys
            let preparedSegments: [(segment: ViewLineSegment, ctLine: CTLine, runs: [PreparedRun])] =
                lineInfo.segments.compactMap { segment in
                    guard segment.attributedString.length > 0 else { return nil }
                    let ctLine = coreGraphicsRenderCache.line(for: segment.attributedString)
                    guard let ctRuns = CTLineGetGlyphRuns(ctLine) as? [CTRun] else { return nil }
                    let runs = ctRuns.map { run -> PreparedRun in
                        // Toll-free cast: no per-entry bridging.
                        let attrs = CTRunGetAttributes(run) as NSDictionary
                        let selectionBackground = attrs.object(
                            forKey: runAttributeKeys.selectionBackground) as? TTColor
                        return PreparedRun(
                            run: run,
                            font: attrs.object(forKey: runAttributeKeys.font) as? TTFont,
                            foregroundColor: attrs.object(
                                forKey: runAttributeKeys.foreground) as? TTColor,
                            backgroundColor: selectionBackground
                                ?? attrs.object(
                                    forKey: runAttributeKeys.background) as? TTColor,
                            glyphPolicy: attrs.object(
                                forKey: runAttributeKeys.glyphPolicy)
                                as? TerminalGlyphPlacementPolicy,
                            hasDecorations: attrs.object(
                                forKey: runAttributeKeys.underlineStyle) != nil
                                || attrs.object(
                                    forKey: runAttributeKeys.strikethroughStyle) != nil,
                            attributes: attrs)
                    }
                    return (segment, ctLine, runs)
                }

            // Background fill loop — uses cached CTLines
            context.saveGState()
            context.setShouldAntialias(false)
            context.setLineCap(.square)
            context.setLineWidth(0)

            for prepared in preparedSegments {
                var processedGlyphs = 0
                for preparedRun in prepared.runs {
                    let run = preparedRun.run
                    let runGlyphsCount = CTRunGetGlyphCount(run)
                    if runGlyphsCount == 0 {
                        continue
                    }
                    let startColumn: Int
                    let endColumn: Int
                    if prepared.segment.utf16IsCellIdentity {
                        // One UTF-16 unit per cell: glyph index arithmetic
                        // yields the column span directly.
                        startColumn = prepared.segment.column + (processedGlyphs * prepared.segment.columnWidth)
                        endColumn = startColumn + (runGlyphsCount * prepared.segment.columnWidth)
                    } else {
                        // Span the columns of the cells this run's characters came
                        // from: combining marks add glyphs but not columns.
                        var runIndices = [CFIndex](repeating: 0, count: runGlyphsCount)
                        CTRunGetStringIndices(run, CFRange(), &runIndices)
                        var minOrdinal = Int.max
                        var maxOrdinal = Int.min
                        for index in runIndices {
                            let ordinal = prepared.segment.cellOrdinal(forUTF16: index)
                            minOrdinal = min(minOrdinal, ordinal)
                            maxOrdinal = max(maxOrdinal, ordinal)
                        }
                        startColumn = prepared.segment.column + (minOrdinal * prepared.segment.columnWidth)
                        endColumn = prepared.segment.column + ((maxOrdinal + 1) * prepared.segment.columnWidth)
                    }
                    processedGlyphs += runGlyphsCount

                    // Runs carrying the default background are not filled: the
                    // view's layer background already paints that color, and
                    // filling it again would double-composite when the
                    // background is translucent (backgroundOpacity < 1)
                    if let backgroundColor = preparedRun.backgroundColor,
                       backgroundColor != renderContext.effectiveBackgroundColor {
                        let columnSpan = max(0, endColumn - startColumn)
                        if columnSpan > 0 {
                            var rect = CGRect(
                                x: lineOrigin.x + (CGFloat(startColumn) * cellDimension.width),
                                y: lineOrigin.y,
                                width: CGFloat(columnSpan) * cellDimension.width,
                                height: cellDimension.height)

                            #if (lastLineExtends)
                            if (row-snapshot.yDisp) >= snapshot.rowCount - 1 {
                                let missing = frame.height - (cellDimension.height + CGFloat(row) + 1)
                                rect.size.height += missing
                                rect.origin.y -= missing
                            }
                            #endif

                            // The right margin beyond the last column needs no
                            // fill: the layer background paints it

                            context.setFillColor(coreGraphicsRenderCache.cgColor(for: backgroundColor))
                            context.fill(rect)
                        }
                    }
                }
            }

            context.restoreGState()

            drawKittyPlacements(
                onScreenRow: row - snapshot.yDisp,
                lineOrigin: lineOrigin,
                belowText: true)

            if !lineInfo.boxDrawings.isEmpty {
                drawBoxDrawings(lineInfo.boxDrawings, lineOrigin: lineOrigin, in: context)
            }

            if !lineInfo.blockElements.isEmpty {
                drawBlockElements(lineInfo.blockElements, lineOrigin: lineOrigin, in: context)
            }

            if !lineInfo.powerlineGlyphs.isEmpty {
                drawPowerlineGlyphs(lineInfo.powerlineGlyphs,
                                    lineOrigin: lineOrigin,
                                    renderMode: renderMode,
                                    in: context)
            }

            context.setShouldAntialias(true)
            context.setAllowsAntialiasing(true)
            #if os(macOS)
            context.setShouldSmoothFonts(fontSmoothing)
            context.setAllowsFontSmoothing(fontSmoothing)
            #endif

            // Glyph drawing loop — reuses cached CTLines
            for prepared in preparedSegments {
                var processedGlyphs = 0
                for preparedRun in prepared.runs {
                    let run = preparedRun.run
                    let runGlyphsCount = CTRunGetGlyphCount(run)
                    if runGlyphsCount == 0 {
                        continue
                    }
                    let runFont = preparedRun.font ?? fontSet.normal

                    let runGlyphs = [CGGlyph](unsafeUninitializedCapacity: runGlyphsCount) { (bufferPointer, count) in
                        CTRunGetGlyphs(run, CFRange(), bufferPointer.baseAddress!)
                        count = runGlyphsCount
                    }

                    var coreTextPositions = [CGPoint](repeating: .zero, count: runGlyphsCount)
                    CTRunGetPositions(run, CFRange(), &coreTextPositions)

                    var positions = [CGPoint](repeating: .zero, count: runGlyphsCount)
                    if prepared.segment.utf16IsCellIdentity {
                        // One UTF-16 unit per cell: glyph index arithmetic
                        // yields each glyph's column directly.
                        let startColumn = prepared.segment.column + (processedGlyphs * prepared.segment.columnWidth)
                        for i in 0..<runGlyphsCount {
                            let glyphColumn = startColumn + (i * prepared.segment.columnWidth)
                            positions[i] = CGPoint(
                                x: lineOrigin.x + CGFloat(glyphColumn) * cellDimension.width,
                                y: lineOrigin.y + yOffset + coreTextPositions[i].y)
                        }
                    } else {
                        var runIndices = [CFIndex](repeating: 0, count: runGlyphsCount)
                        CTRunGetStringIndices(run, CFRange(), &runIndices)

                        // Position each glyph at its source cell's column; glyphs
                        // sharing a cell (base + combining marks) keep their
                        // CoreText offsets relative to the cluster's first glyph,
                        // so marks overlay the base instead of shifting columns.
                        // Same-cell glyphs are adjacent in glyph order, so a pair
                        // of locals replaces a per-run anchor dictionary.
                        var anchorOrdinal = -1
                        var anchorX: CGFloat = 0
                        for i in 0..<runGlyphsCount {
                            let ctPosition = coreTextPositions[i]
                            let ordinal = prepared.segment.cellOrdinal(forUTF16: runIndices[i])
                            let intraCluster: CGFloat
                            if ordinal == anchorOrdinal {
                                intraCluster = ctPosition.x - anchorX
                            } else {
                                anchorOrdinal = ordinal
                                anchorX = ctPosition.x
                                intraCluster = 0
                            }
                            let glyphColumn = prepared.segment.column + (ordinal * prepared.segment.columnWidth)
                            positions[i] = CGPoint(
                                x: lineOrigin.x + CGFloat(glyphColumn) * cellDimension.width + intraCluster,
                                y: lineOrigin.y + yOffset + ctPosition.y)
                        }
                    }
                    processedGlyphs += runGlyphsCount

                    context.setFillColor(
                        coreGraphicsRenderCache.cgColor(
                            for: preparedRun.foregroundColor ?? renderContext.effectiveForegroundColor))

                    // Center full-width (CJK) and substituted glyphs within their
                    // multi-cell slot instead of pinning them to the cell's left
                    // edge. `positions` stays grid-aligned for the decorations
                    // below; only `glyphPositions` is shifted/scaled.
                    let ctRunFont = runFont as CTFont
                    var glyphPositions = positions
                    var scaledFits: [GlyphSlotFit]? = nil
                    let glyphPolicy = preparedRun.glyphPolicy
                    if glyphPolicy != nil || prepared.segment.columnWidth >= 2 {
                        var computed = [GlyphSlotFit](repeating: .identity, count: runGlyphsCount)
                        var anyScaled = false
                        for i in 0..<runGlyphsCount {
                            let fit: GlyphSlotFit
                            if let glyphPolicy {
                                fit = glyphSlotFit(font: ctRunFont, glyph: runGlyphs[i],
                                                   columnWidth: prepared.segment.columnWidth,
                                                   policy: glyphPolicy)
                            } else {
                                fit = glyphSlotFit(font: ctRunFont, glyph: runGlyphs[i], columnWidth: prepared.segment.columnWidth)
                            }
                            computed[i] = fit
                            glyphPositions[i].x += fit.dx
                            glyphPositions[i].y += fit.dy
                            if fit.scaleX != 1 || fit.scaleY != 1 { anyScaled = true }
                        }
                        if anyScaled { scaledFits = computed }
                    }

                    if let scaledFits {
                        // Rare path: at least one glyph is scaled and is drawn
                        // individually — uniform scales via a resized font,
                        // per-axis (stretch policy) scales via the CTM.
                        for i in 0..<runGlyphsCount {
                            let fit = scaledFits[i]
                            var g = runGlyphs[i]
                            var p = glyphPositions[i]
                            if fit.isUniform {
                                let s = fit.scale
                                let drawFont: CTFont = s == 1
                                    ? ctRunFont
                                    : CTFontCreateCopyWithAttributes(ctRunFont, CTFontGetSize(ctRunFont) * s, nil, nil)
                                CTFontDrawGlyphs(drawFont, &g, &p, 1, context)
                            } else {
                                context.saveGState()
                                context.translateBy(x: p.x, y: p.y)
                                context.scaleBy(x: fit.scaleX, y: fit.scaleY)
                                var origin = CGPoint.zero
                                CTFontDrawGlyphs(ctRunFont, &g, &origin, 1, context)
                                context.restoreGState()
                            }
                        }
                    } else {
                        CTFontDrawGlyphs(runFont, runGlyphs, &glyphPositions, glyphPositions.count, context)
                    }

                    // Draw other attributes (decorations stay grid-aligned).
                    // The dictionary is only bridged for the rare decorated
                    // runs; undecorated runs skip the call entirely.
                    if preparedRun.hasDecorations {
                        let runAttributes = preparedRun.attributes as? [NSAttributedString.Key: Any] ?? [:]
                        drawRunAttributes(runAttributes, glyphPositions: positions, in: context)
                    }
                }
            }

            if !lineInfo.kittyPlaceholders.isEmpty {
                for placeholder in lineInfo.kittyPlaceholders {
                    guard let records = virtualPlacementsByImageId[placeholder.imageId] else {
                        continue
                    }
                    guard let record = records.first(where: { record in
                        if placeholder.placementId != 0 && record.placementId != placeholder.placementId {
                            return false
                        }
                        return record.geometry.columns > placeholder.placeholderCol &&
                            record.geometry.rows > placeholder.placeholderRow &&
                            record.geometry.columns > 0 &&
                            record.geometry.rows > 0
                    }) else {
                        continue
                    }
                    guard let image = kittyRenderImage(record) else {
                        continue
                    }

                    let offsetScale = getImageScale()
                    let offsetX = CGFloat(record.pixelOffsetX) / offsetScale
                    let offsetY = CGFloat(record.pixelOffsetY) / offsetScale
                    let placementOriginX = lineOrigin.x + CGFloat(placeholder.col - placeholder.placeholderCol) * cellDimension.width + offsetX
                    let placementTopY = lineOrigin.y + CGFloat(placeholder.placeholderRow) * cellDimension.height
                    let placementOriginY = placementTopY - CGFloat(record.geometry.rows - 1) * cellDimension.height + offsetY
                    let placementRect = CGRect(x: placementOriginX,
                                               y: placementOriginY,
                                               width: CGFloat(record.geometry.columns) * cellDimension.width,
                                               height: CGFloat(record.geometry.rows) * cellDimension.height)
                    if placementRect.width <= 0 || placementRect.height <= 0 {
                        continue
                    }
                    let imageRect = kittyAspectFitRect(imageSize: image.size, in: placementRect)
                    let cellRect = CGRect(x: lineOrigin.x + CGFloat(placeholder.col) * cellDimension.width,
                                          y: lineOrigin.y,
                                          width: cellDimension.width,
                                          height: cellDimension.height)
                    context.saveGState()
                    context.clip(to: cellRect)
                    image.draw(in: imageRect)
                    context.restoreGState()
                }
            }

            drawKittyPlacements(
                onScreenRow: row - snapshot.yDisp,
                lineOrigin: lineOrigin,
                belowText: false)
            if !otherImages.isEmpty {
                for image in otherImages {
                    let col = image.col
                    let rect = CGRect(x: CGFloat (col)*cellDimension.width,
                                      y: rowBase - CGFloat (image.pixelHeight),
                                      width: CGFloat (image.pixelWidth),
                                      height: CGFloat (image.pixelHeight))
                    image.image.draw (in: rect)
                }
            }
            switch renderMode {
            case .single:
                break
            case .doubledDown:
                context.restoreGState()
            case .doubledTop:
                context.restoreGState()
            case .doubleWidth:
                context.restoreGState()
            }
        }
        
#if os(macOS)
        // Fills gaps at the end with the default terminal background
        let box = CGRect (x: 0, y: 0, width: bounds.width, height: bounds.height.truncatingRemainder(dividingBy: cellHeight))
        if dirtyRect.intersects(box) {
            renderContext.effectiveBackgroundColor.setFill()
            context.fill ([box])
        }
#elseif false
        // Currently the caller on iOS is clearing the entire dirty region due to the ordering of
        // font change sizes, but once we fix that, we should remove the clearing of the dirty
        // region in the calling code, and enable this code instead.
        let lineOffset = calcLineOffset(forRow: lastRow)
        let lineOrigin = CGPoint(x: 0, y: frame.height - lineOffset)

        let inter = dirtyRect.intersection(CGRect (x: 0, y: lineOrigin.y, width: bounds.width, height: cellHeight))
        if !inter.isEmpty {
            renderContext.effectiveBackgroundColor.setFill()
            context.fill ([inter])
        }
#endif
        
#if os(iOS) || os(visionOS)
        if snapshot.style.selectionActive {
            let start, end: Position

            @MainActor
            func drawSelectionHandle (drawStart: Bool, row: Int) {
                let lineOffset = calcLineOffset(forRow: row)
                let lineOrigin = frame.height - lineOffset
                
                context.saveGState ()
                let start = CGPoint (
                    x: CGFloat (drawStart ? start.col : end.col) * cellDimension.width,
                    y: lineOrigin)
                let end = CGPoint(x: start.x, y: start.y + cellDimension.height)
                
                context.move(to: end)
                context.addLine(to: start)
                let size = 12.0
                let location = drawStart ? end : start
                
                let rect = CGRect (origin:
                                    CGPoint (x: location.x-(size/2.0),
                                             y: location.y - (drawStart ? 0.0 : size)),
                                   size: CGSize (width: size, height: size))
                context.addEllipse(in: rect)
                context.closePath()
                context.setLineWidth(2)
                selectionHandleColor.set ()
                //TTColor.systemBlue.set ()
                context.drawPath(using: .fillStroke)
                context.restoreGState()
            }
            
            // Normalize the selection start/end, regardless of where it started
            let sstart = snapshot.style.selectionStart
            let send = snapshot.style.selectionEnd
            if Position.compare (sstart, send) == .before {
                start = sstart
                end = send
            } else {
                start = send
                end = sstart
            }
            
            drawSelectionHandle (drawStart: true, row: start.row)
            drawSelectionHandle (drawStart: false, row: end.row)
        }
#endif
        }
    }
    
    /// What one prepared frame implies for the main thread.
    ///
    /// `PreparedFrame` stays in the render owner. Only its checked-Sendable
    /// `mainEffects` value crosses to the main actor. The cursor can therefore
    /// keep the framework values that the renderer needs.
    struct PreparedFrame {
        var mainEffects: MainFrameEffects
        var region: CGRect?
        var needsMetalDisplay: Bool
        var cursor: SnapshotCursor?
        /// Snapshot row count at prepare time, so placing the caret
        /// needs no second look at the snapshot.
        var cursorRowCount: Int

        init (region: CGRect?, rangeChanged: (start: Int, end: Int)?,
              notifyAccessibility: Bool, needsMetalDisplay: Bool,
              cursor: SnapshotCursor?, cursorRowCount: Int,
              scrollPosition: Double) {
            mainEffects = MainFrameEffects(
                rangeChanged: rangeChanged.map {
                    FrameChangedRange(start: $0.start, end: $0.end)
                },
                notifyAccessibility: notifyAccessibility,
                scrollPosition: scrollPosition)
            self.region = region
            self.needsMetalDisplay = needsMetalDisplay
            self.cursor = cursor
            self.cursorRowCount = cursorRowCount
        }

        var blinkRows: [Int] {
            get { mainEffects.blinkRows }
            set { mainEffects.blinkRows = newValue }
        }
        var resizedTo: (cols: Int, rows: Int)? {
            get {
                mainEffects.resizedTo.map { (cols: $0.cols, rows: $0.rows) }
            }
            set {
                mainEffects.resizedTo = newValue.map {
                    FrameTerminalSize(cols: $0.cols, rows: $0.rows)
                }
            }
        }
#if os(macOS)
        var scroller: ScrollerState? {
            get { mainEffects.scroller }
            set { mainEffects.scroller = newValue }
        }
#endif
    }

    /// Refreshes the terminal snapshot and submits one frame.
    ///
    /// Always runs on the main thread. When a render loop is active this does
    /// almost nothing: it captures the view state and hands the frame over
    /// (io-gaps.md G1, WO-F4).
    func frameTick ()
    {
        let tick = Profiling.begin(.frameTick)
        defer { tick.end() }
        guard let viewState = captureFrameViewState() else { return }
#if os(macOS) && canImport(MetalKit)
        if usesRenderLoop {
            publishFrameViewState(viewState)
            renderLoop?.signal()
            return
        }
#endif
        guard let prepared = prepareFrame(viewState: viewState) else { return }
        applyFrameSideEffects(prepared.mainEffects)
        updateCursorPosition(from: prepared.cursor, rowCount: prepared.cursorRowCount)
        submitFrameDraw(prepared)
    }

    /// Captures what this frame needs from the view. Main thread only — this is
    /// the boundary the rest of the frame path is not allowed to cross.
    @MainActor
    func captureFrameViewState () -> FrameViewState?
    {
        guard terminal != nil else { return nil }
        return FrameViewState(view: self)
    }

    /// Hands the capture to the render loop.
    ///
    /// Republished every tick rather than invalidated whenever a font, color or
    /// selection changes: capturing costs microseconds and there is no list of
    /// setters to keep in step, which is the failure mode a cache invalidation
    /// scheme would have.
    func publishFrameViewState (_ viewState: FrameViewState)
    {
        renderOwner.mailbox.publish(viewState)
    }

    /// Refreshes the snapshot under the terminal lock and works out what the
    /// frame implies.
    ///
    /// Reads only `viewState` and the terminal, so it is safe to call off the
    /// main thread (io-gaps.md G1, WO-F2/WO-F4). Anything that needs AppKit or
    /// UIKit belongs in `applyFrameSideEffects` instead.
    func prepareFrame (viewState: FrameViewState) -> PreparedFrame?
    {
        renderOwner.prepareFrame(viewState: viewState)
    }

    /// The AppKit/UIKit half of a frame: what `prepareFrame` deliberately left
    /// undone because it touches the view. Main thread only.
    func applyFrameSideEffects (_ effects: MainFrameEffects)
    {
        if let resized = effects.resizedTo {
            // The delegate call is what reaches the pty ioctl, so it runs once
            // per frame now rather than once per drag step.
            accessibility.invalidate()
            terminalDelegate?.sizeChanged(source: self, newCols: resized.cols,
                                          newRows: resized.rows)
            updateScroller()
        }
#if os(macOS)
        if let scroller = effects.scroller {
            applyScrollerState(scroller)
        }
#endif
        updateTextBlinkLifecycle(blinkRows: effects.blinkRows)

        if let changed = effects.rangeChanged {
            terminalDelegate?.rangeChanged(source: self, startY: changed.start,
                                           endY: changed.end)
        }

        if effects.notifyAccessibility {
            accessibility.invalidate()
#if os(iOS)
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
#endif
#if os(macOS)
            NSAccessibility.post(element: self, notification: .valueChanged)
            NSAccessibility.post(element: self, notification: .selectedTextChanged)
#endif
        }

        if consumeScrolledDirty() {
            updateScroller()
            terminalDelegate?.scrolled(source: self, position: effects.scrollPosition)
        }
        updateDebugDisplay()
    }

    /// Hands the prepared frame to whichever renderer is active.
    func submitFrameDraw (_ prepared: PreparedFrame)
    {
#if canImport(MetalKit)
        if prepared.needsMetalDisplay {
            if metalView?.needsExternalDrawCall == true {
                // No display callback exists for this surface: render now.
                // Routing through requestDisplay() here would only mark the
                // driver dirty again and spin without ever drawing.
                renderOwner.renderMetal()
            } else {
                // MTKView: AppKit will call the delegate, which renders.
                metalView?.requestDisplay()
            }
            return
        }
#endif
        if let region = prepared.region {
            setNeedsDisplay(region)
        }
    }

#if canImport(MetalKit)
    /// Fallback for a draw that arrives with no snapshot prepared for it — a
    /// live resize on the `MTKView` path, where AppKit calls the delegate
    /// outside the frame tick.
    ///
    /// The render loop never needs it: `submitFrameDraw` hands the renderer a
    /// snapshot immediately before every `render()`.
    @MainActor
    func refreshSnapshotForMetal () -> Bool {
        guard let viewState = captureFrameViewState() else { return false }
        return renderOwner.refreshMetalSnapshot(viewState: viewState)
    }

    @MainActor
    func renderSnapshotForMetal (renderer: MetalTerminalRenderer,
                                 target: any MetalRenderTarget) -> Bool {
        guard let viewState = captureFrameViewState() else { return false }
        return renderOwner.renderMetalSnapshot(
            viewState: viewState,
            renderer: renderer,
            target: target)
    }
#endif

    func updateCursorPosition()
    {
        guard let viewState = captureFrameViewState() else { return }
#if canImport(MetalKit)
        // The render loop owns the snapshot, and under Metal the renderer draws
        // the cursor itself — `caretView` is not on screen. Refreshing here
        // would only race the loop for a caret nobody sees.
        if renderOwner.hasMetalRenderer {
            frameDriver?.markDirty()
            return
        }
#endif
        renderOwner.withUpdatedCursor(viewState: viewState) { [weak self] cursor, rowCount in
            self?.updateCursorPosition(from: cursor, rowCount: rowCount)
        }
    }

    func updateCursorPosition (from cursor: SnapshotCursor?, rowCount: Int)
    {
        guard let caretView else { return }
        guard let cursor, cursor.screenRow >= 0,
              cursor.screenRow < rowCount else {
            caretView.removeFromSuperview()
            return
        }
        if !cursor.hidden && caretView.superview != self {
            addSubview(caretView)
        } else if cursor.hidden && caretView.superview == self {
            caretView.removeFromSuperview()
        }
        let doublePosition = cursor.renderMode == .single ? 1.0 : 2.0
        #if os(iOS) || os(visionOS)
        let offset = cellDimension.height * CGFloat(cursor.absoluteRow)
        let lineOrigin = CGPoint(x: 0, y: offset)
        #else
        let offset = cellDimension.height * CGFloat(cursor.screenRow + 1)
        let lineOrigin = CGPoint(x: 0, y: frame.height - offset)
        #endif
        caretView.frame.origin = CGPoint(
            x: lineOrigin.x + cellDimension.width * doublePosition * CGFloat(cursor.visualCol),
            y: lineOrigin.y)
        caretView.frame.size.width = cellDimension.width * doublePosition *
            CGFloat(cursor.columnWidth)
        caretView.setText(cursor.renderData)
    }
    
    /// Queues a frame without waiting for the next display-link callback.
    func updateDisplay ()
    {
        requestImmediateFrame()
    }

    /// Invalidates what is on screen after terminal-visible state changed.
    ///
    /// `needsDisplay`/`setNeedsDisplay` alone is not enough on any renderer.
    /// Drawing reads the render owner's snapshot, and only a frame tick
    /// refreshes it, so
    /// an AppKit invalidation repaints the *previous* frame's state — a
    /// selection highlight that never appears, for example. Under a GPU
    /// renderer it repaints nothing at all, because `draw(_:)` returns
    /// immediately.
    ///
    /// Marking the frame driver dirty is what schedules the refresh. Safe from
    /// any thread.
    func invalidateTerminalContents () {
        frameDriver?.markDirty()
    }

    /// Asks for the terminal to be redrawn.
    ///
    /// Call this after changing custom drawing state that SwiftTerm cannot
    /// observe. View reset, palette and feed APIs mark the frame themselves.
    ///
    /// **`setNeedsDisplay` is not a substitute.** With a GPU renderer the view
    /// does not draw through AppKit at all: `draw(_:)` returns immediately and
    /// frames come from the frame driver, so an invalidation is silently
    /// dropped. That has been true whenever Metal was enabled, and Metal is
    /// the default on macOS since the render loop landed.
    ///
    /// Safe to call from any thread.
    public nonisolated func requestRedraw ()
    {
        frameSignal.markDirty()
    }

    /// Asks for a frame ahead of the display cadence. Safe from any thread.
    ///
    /// With a render loop running this signals the loop directly instead of
    /// posting a main-queue tick. Two reasons, and the second is the one that
    /// bit: signalling is lower latency than a hop through main, and a
    /// main-queue tick is now so cheap that under a flood the main thread spun
    /// on it — 4 134 immediate ticks for 423 drawn frames, against 442 total
    /// ticks on the MTKView path. The old path was self-limiting only because
    /// each tick carried the 6 ms draw.
    func requestImmediateFrame ()
    {
#if os(macOS) && canImport(MetalKit)
        // Not while nothing can see the terminal: signalling the loop bypasses
        // the display link, which is where the occlusion pause lives, so this
        // is the one path that could keep a render thread drawing into an
        // occluded window (io-gaps.md G8b).
        if let loop = activeRenderLoop(), frameDriver?.isVisibilitySuspended != true {
            frameDriver?.markDirty()
            loop.signal()
            return
        }
#endif
        frameDriver.requestImmediateTick()
    }

    /// Counters describing how much data the view consumed and how many frames
    /// it produced over a measurement window.
    ///
    /// Intended for benchmarking and for diagnosing a terminal that feels slow:
    /// a large `bytesFed` with few `frames` means output is being coalesced (a
    /// healthy flood), while many `idleTicks` means the display link is running
    /// with nothing to show. Reset the window with `resetDiagnostics()`.
    public struct Diagnostics: Sendable {
        /// Bytes handed to `feed`, across every overload.
        public var bytesFed: Int = 0
        /// Calls to `feed`. Under a local process this is one per pty batch.
        public var batches: Int = 0
        /// Display or immediate ticks delivered to the frame driver.
        public var ticks: Int = 0
        /// Ticks that produced a frame.
        public var frames: Int = 0
        /// Ticks that found nothing to draw.
        public var idleTicks: Int = 0
        /// Times the frame driver paused the display link after idling.
        public var pauses: Int = 0
        /// Frames requested outside the display cadence.
        public var immediateTicks: Int = 0
        /// Frames actually drawn — GPU submissions on the Metal path, or
        /// completed Core Graphics draws. Compare against `frames`: a large
        /// gap means the driver is ticking without producing anything.
        public var renders: Int = 0
        /// Delegate notifications marshalled to the main queue by `onMain`.
        /// Each one is a main-queue block that may take the terminal lock, so a
        /// large value relative to `frames` means callback amplification.
        public var mainHops: Int = 0
        /// Frames prepared and drawn on the render loop rather than on the main
        /// thread. Zero when no render loop is running.
        public var renderLoopFrames: Int = 0
        /// Render-loop wakeups folded into an already-pending frame. Under a
        /// flood this should be large: it is the producer being coalesced,
        /// which is the intended behaviour.
        public var renderLoopCoalesced: Int = 0
        /// Raw glyph-metrics cache activity in Metal Release profiling runs.
        public var metricsCacheLookups: Int = 0
        public var metricsCacheHits: Int = 0
        public var metricsCacheMisses: Int = 0
        /// Atlas-backed glyph-entry cache activity.
        public var glyphAtlasLookups: Int = 0
        public var glyphAtlasHits: Int = 0
        public var glyphAtlasMisses: Int = 0
        public var permanentEmptyGlyphHits: Int = 0
        public var fullGlyphCacheMisses: Int = 0
        public var glyphRasterizations: Int = 0
        public var bitmapRasterizationResults: Int = 0
        public var emptyRasterizationResults: Int = 0
        public var transientRasterizationFailures: Int = 0
        public var glyphBoundsQueries: Int = 0
        public var glyphDrawCalls: Int = 0
        public var negativeGlyphCacheEvictions: Int = 0
        public var negativeGlyphCacheHighWater: Int = 0
        public var rasterFontRegistryLookups: Int = 0
        public var rasterFontRegistryHits: Int = 0
        public var rasterFontRegistryMisses: Int = 0
        public var rasterFontRegistryHighWater: Int = 0
        public var rasterFontRegistryTeardowns: Int = 0
        public var drawableHitsAvoidedMetricsLookup: Int = 0
        public var drawableHitsRequiredMetricsLookup: Int = 0
        public var metricsReusedFromDrawableMiss: Int = 0
        public var metricsFontRegistryHighWater: Int = 0
        public var fullIdentityTokensAliasingRasterIdentity: Int = 0
        public var fullCacheKeysAliasingRasterGlyphKey: Int = 0
        public var grayscaleAtlasGrows: Int = 0
        public var colorAtlasGrows: Int = 0
        public var grayscaleAtlasResets: Int = 0
        public var colorAtlasResets: Int = 0
        public var metricsEntryLimitResets: Int = 0
        public var metricsFontLimitResets: Int = 0
        public var metalRowsRebuilt: Int = 0
        public var atlasInvalidationBuildAttempts: Int = 0

        /// Mean bytes per `feed` call, or zero when nothing was fed.
        public var meanBatchBytes: Int {
            batches == 0 ? 0 : bytesFed / batches
        }
    }

    /// A snapshot of the current diagnostics. Safe to read from any thread.
    public var diagnostics: Diagnostics {
        var result = diagnosticsState.withLock { $0 }
        let frameCounters = frameDriver?.currentCounters ?? FrameDriverCounters()
        result.ticks = frameCounters.ticks
        result.frames = frameCounters.frames
        result.idleTicks = frameCounters.idleTicks
        result.pauses = frameCounters.pauses
        result.immediateTicks = frameCounters.immediateTicks
#if canImport(MetalKit)
        result.renders += renderOwner.completedMetalRenders
        if let counters = renderOwner.metalProfileCounters {
            result.metricsCacheLookups = counters.metricsCacheLookups
            result.metricsCacheHits = counters.metricsCacheHits
            result.metricsCacheMisses = counters.metricsCacheMisses
            result.glyphAtlasLookups = counters.glyphAtlasLookups
            result.glyphAtlasHits = counters.glyphAtlasHits
            result.glyphAtlasMisses = counters.glyphAtlasMisses
            result.permanentEmptyGlyphHits = counters.permanentEmptyHits
            result.fullGlyphCacheMisses = counters.fullGlyphCacheMisses
            result.glyphRasterizations = counters.rasterizations
            result.bitmapRasterizationResults = counters.bitmapRasterizationResults
            result.emptyRasterizationResults = counters.emptyRasterizationResults
            result.transientRasterizationFailures = counters.transientRasterizationFailures
            result.glyphBoundsQueries = counters.glyphBoundsQueries
            result.glyphDrawCalls = counters.glyphDrawCalls
            result.negativeGlyphCacheEvictions = counters.negativeCacheEvictions
            result.negativeGlyphCacheHighWater = counters.negativeCacheHighWater
            result.rasterFontRegistryLookups = counters.rasterFontRegistryLookups
            result.rasterFontRegistryHits = counters.rasterFontRegistryHits
            result.rasterFontRegistryMisses = counters.rasterFontRegistryMisses
            result.rasterFontRegistryHighWater = counters.rasterFontRegistryHighWater
            result.rasterFontRegistryTeardowns = counters.rasterFontRegistryTeardowns
            result.drawableHitsAvoidedMetricsLookup = counters.drawableHitsAvoidedMetricsLookup
            result.drawableHitsRequiredMetricsLookup = counters.drawableHitsRequiredMetricsLookup
            result.metricsReusedFromDrawableMiss = counters.metricsReusedFromDrawableMiss
            result.metricsFontRegistryHighWater = counters.metricsFontRegistryHighWater
            result.fullIdentityTokensAliasingRasterIdentity =
                counters.fullIdentityTokensAliasingRasterIdentity
            result.fullCacheKeysAliasingRasterGlyphKey =
                counters.fullCacheKeysAliasingRasterGlyphKey
            result.grayscaleAtlasGrows = counters.grayscaleAtlasGrows
            result.colorAtlasGrows = counters.colorAtlasGrows
            result.grayscaleAtlasResets = counters.grayscaleAtlasResets
            result.colorAtlasResets = counters.colorAtlasResets
            result.metricsEntryLimitResets = counters.metricsEntryLimitResets
            result.metricsFontLimitResets = counters.metricsFontLimitResets
            result.metalRowsRebuilt = counters.rowsRebuilt
            result.atlasInvalidationBuildAttempts = counters.atlasInvalidationBuildAttempts
        }
#endif
#if os(macOS) && canImport(MetalKit)
        if let loopCounters = renderLoop?.currentCounters {
            result.renderLoopFrames = loopCounters.frames
            result.renderLoopCoalesced = loopCounters.coalesced
        }
#endif
        return result
    }

    /// Starts a new measurement window.
    public func resetDiagnostics ()
    {
        diagnosticsState.withLock { $0 = Diagnostics() }
        frameDriver?.resetCounters()
#if canImport(MetalKit)
        renderOwner.resetMetalCounters()
#endif
#if os(macOS) && canImport(MetalKit)
        renderLoop?.resetCounters()
#endif
    }

    /// Counts one `feed` call. Called from the parse thread, so it uses its own
    /// small lock rather than the terminal lock: this must not extend the
    /// locked region that G2 is trying to shrink.
    nonisolated func recordFedBytes (_ count: Int)
    {
        diagnosticsState.withLock { diagnostics in
            diagnostics.bytesFed += count
            diagnostics.batches += 1
        }
    }

    func setupFrameDriver () {
        let driver = FrameDriver(signal: frameSignal)
        driver.onTick = { [weak self] in
            self?.frameTick()
        }
        frameDriver = driver
    }
    
    ///
    /// This takes a string returned by events (NSEvent or UIKey) as the 'charactersIngoringModifiers'
    /// and returns the control-version of that, and only applies to a handful of characters
    ///
    func applyControlToEventCharacters (_ ch: String) -> [UInt8]
    {
        let arr = [UInt8](ch.utf8)
        if arr.count == 1 {
            let ch = Character (UnicodeScalar (arr [0]))
            var value: UInt8
            switch ch {
            case "A"..."Z":
                value = (ch.asciiValue! - 0x40 /* - 'A' + 1 */)
            case "a"..."z":
                value = (ch.asciiValue! - 0x60 /* - 'a' + 1 */)
            case "\\":
                value = 0x1c
            case "_":
                value = 0x1f
            case "]":
                value = 0x1d
            case "[":
                value = 0x1b
            case "^", "6":
                value = 0x1e
            case " ":
                value = 0
            default:
                return []
            }
            return [value]
        }
        return []
    }
    /**
     * Returns the thumb size in proportion to the visible content of the entire content, alternate buffers are not scrollable, so this returns 0
     */
    public var scrollThumbsize: CGFloat {
        get {
            withTerminal { terminal in
                scrollThumbsizeLocked()
            }
        }
    }

    func scrollThumbsizeLocked () -> CGFloat {
        terminal.terminalLock.preconditionLocked()
        let displayBuffer = terminal.displayBuffer
        if terminal.isDisplayBufferAlternate {
            return 0
        }

        return max (CGFloat (displayBuffer.rows) / CGFloat (displayBuffer.lines.count), 0.01)
    }
    
    /**
     * Gets a value indicating the relative position of the terminal viewport
     */
    public var scrollPosition: Double {
        get {
            withTerminal { terminal in
                scrollPositionLocked()
            }
        }
    }

    func scrollPositionLocked () -> Double {
        terminal.terminalLock.preconditionLocked()
        let displayBuffer = terminal.displayBuffer
        if terminal.isDisplayBufferAlternate || displayBuffer.yDisp <= 0 {
            return 0
        }

        let maxScrollback = displayBuffer.lines.count - displayBuffer.rows
        if displayBuffer.yDisp >= maxScrollback {
            return 1
        }

        return Double (displayBuffer.yDisp) / Double (maxScrollback)
    }
    
    /// <summary>
    /// Gets a value indicating whether or not the user can scroll the terminal contents
    /// </summary>
    public var canScroll: Bool {
        get {
            withTerminal { terminal in
                canScrollLocked()
            }
        }
    }

    func canScrollLocked () -> Bool {
        terminal.terminalLock.preconditionLocked()
        let displayBuffer = terminal.displayBuffer
        return !terminal.isDisplayBufferAlternate &&
            displayBuffer.hasScrollback &&
            displayBuffer.lines.count > displayBuffer.rows
    }
    
    public func scroll (toPosition: Double)
    {
        let scroll = withTerminal { terminal -> (position: Int, changed: Bool) in
            let displayBuffer = terminal.displayBuffer
            let oldPosition = displayBuffer.yDisp
            let maxScrollback = max(0, displayBuffer.lines.count - displayBuffer.rows)
            let position = max(0, min(Int(Double(maxScrollback) * toPosition), maxScrollback))
            return (position, position != oldPosition)
        }
        if scroll.changed {
            scrollTo(row: scroll.position)
        } else {
            withTerminal { terminal in
                updateUserScrollingStateLocked(for: scroll.position, in: terminal.displayBuffer)
            }
        }
    }

    private func updateUserScrollingStateLocked(for row: Int, in displayBuffer: Buffer) {
        terminal.terminalLock.preconditionLocked()
        let maxScrollback = max(0, displayBuffer.lines.count - displayBuffer.rows)
        let isUserScrolling = row < maxScrollback
        userScrolling = isUserScrolling
        terminal.userScrolling = isUserScrolling
    }
    
    public func scrollTo (row: Int, notifyAccessibility: Bool = true)
    {
#if os(iOS) || os(visionOS)
        resetManualScrollOffsetWithinRow()
#endif
        let didScroll = withTerminal { terminal in
            let displayBuffer = terminal.displayBuffer
            let maxScrollback = max(0, displayBuffer.lines.count - displayBuffer.rows)
            let targetRow = max(0, min(row, maxScrollback))
            updateUserScrollingStateLocked(for: targetRow, in: displayBuffer)
            if targetRow == displayBuffer.yDisp {
                return false
            }
            terminal.setViewYDisp (targetRow)
            
            // tell the terminal we want to refresh all the rows
            terminal.refresh (startRow: 0, endRow: terminal.rows)
            return true
        }
        if didScroll {
            setAccessibilityNotificationForNextFrame(notifyAccessibility)
            frameDriver.markDirty()
            terminalDelegate?.scrolled (source: self, position: scrollPosition)
            updateScroller()
#if os(macOS)
            showOverlayScroller()
#endif
        } else {
#if os(iOS) || os(visionOS)
            // resetManualScrollOffsetWithinRow() changed the visual offset even
            // when the terminal stayed on the same row.
            updateScroller()
#endif
        }
    }
    
    /// Scrolls the content of the terminal one page up
    public func pageUp()
    {
        let state = withTerminal { terminal in
            (terminal.isDisplayBufferAlternate, terminal.rows)
        }
        if state.0 {
            send (EscapeSequences.cmdPageUp)
        } else {
            scrollUp (lines: state.1)
        }
    }
    
    /// Scrolls the content of the terminal one page down
    public func pageDown ()
    {
        let state = withTerminal { terminal in
            (terminal.isDisplayBufferAlternate, terminal.rows)
        }
        if state.0 {
            send (EscapeSequences.cmdPageDown)
        } else {
            scrollDown (lines: state.1)
        }
    }

    /// Scrolls up the content of the terminal the specified number of lines
    public func scrollUp (lines: Int)
    {
        let newPosition = withTerminal { terminal in
            max (terminal.displayBuffer.yDisp - lines, 0)
        }
        scrollTo (row: newPosition)
    }
    
    /// Scrolls down the content of the terminal the specified number of lines
    public func scrollDown (lines: Int)
    {
        let newPosition = withTerminal { terminal in
            let displayBuffer = terminal.displayBuffer
            return max (0, min (displayBuffer.yDisp + lines, displayBuffer.lines.count - displayBuffer.rows))
        }
        scrollTo (row: newPosition)
    }
      
    /// Asks for a frame before the batch is parsed rather than after it.
    ///
    /// Ghostty calls `queueRender()` before parsing, and the reason is the
    /// wakeup, not the frame: when the display link is paused, marking dirty
    /// posts a main-queue block that starts the link. Doing it first overlaps
    /// that hop with the parse instead of queuing it behind one (io-gaps.md
    /// G4, WO-C5).
    ///
    /// A frame that arrives before the batch has landed costs almost nothing:
    /// `refresh` skips unchanged rows and `prepareFrame` returns early when
    /// there is no update range.
    nonisolated func markDirtyBeforeParsing()
    {
        frameSignal.markDirty()
    }

    func feedPrepareLocked()
    {
        terminal.terminalLock.preconditionLocked()
        search.invalidate()
        // Preserve manual selection while output is streaming when mouse reporting is disabled.
        if allowMouseReporting {
            selection.active = false
        }
    }
    
    func feedFinish (synchronizedOutputActive: Bool)
    {
        // No special case for recent user input any more. WO-C5 asks for the
        // frame before the parse rather than after it, and WO-C6 makes the
        // first frame after idle skip the vsync wait — which is what the
        // 150 ms window existed to hide, and it only ever hid it for input
        // (io-gaps.md G4, WO-C7).
        frameDriver.markDirty()
    }

    /// Sends data to the terminal emulator for interpretation, this can be invoked from a background thread
    public nonisolated func feed (byteArray: ArraySlice<UInt8>)
    {
        feedSender.feed(byteArray: byteArray)
    }
    
    /// Sends data to the terminal emulator for interpretation, this can be invoked from a background thread
    public nonisolated func feed (text: String)
    {
        feedSender.feed(text: text)
    }
         
    /**
     * Triggers a resize of the underlying terminal to the desired columsn and rows
     */
    public func resize (cols: Int, rows: Int)
    {
        withTerminal { terminal in
            terminal.resize (cols: cols, rows: rows)
            terminal.softReset()
        }
        terminalDelegate?.sizeChanged(source: self, newCols: cols, newRows: rows)
        updateScroller()
    }

    /**
     * Changes the scrollback size at runtime.
     *
     * - Parameter newScrollback: The new scrollback size in lines. Pass `nil` to disable scrollback.
     */
    public func changeScrollback (_ newScrollback: Int?)
    {
        withTerminal { terminal in
            terminal.changeScrollback(newScrollback)
        }
        updateScroller()
        terminalDelegate?.scrolled(source: self, position: scrollPosition)
        frameDriver.markDirty()
    }

    /**
     * Discards the scrollback history without clearing the visible screen,
     * the equivalent of Terminal.app's "Clear to Start" / Cmd-K affordance.
     */
    public func clearScrollback ()
    {
        withTerminal { terminal in
            terminal.clearScrollback()
        }
        updateScroller()
        terminalDelegate?.scrolled(source: self, position: scrollPosition)
        frameDriver.markDirty()
    }
    
    /**
     * Sends the specified slice of byte arrays to the program running under the terminal emulator
     * - Parameter data: the slice of an array to send to the client
     *
     * Callable from any thread. A host that receives input on a transport
     * thread — SSH, an agent, an automation bridge — can call this directly
     * with no marshalling (io-gaps.md G5a).
     *
     * The one rule: do not call it from inside a terminal delegate callback.
     * Those run with the terminal lock held, and this method takes that lock;
     * the precondition below catches it rather than deadlocking.
     *
     * Ordering between concurrent callers is the caller's problem, and always
     * was: two threads sending at once interleave their bytes in the pty. If
     * the order of two sends matters, the caller must sequence them.
     */
    public nonisolated func send(data: ArraySlice<UInt8>)
    {
        inputSender.send(data: data)
    }
    
    /**
     * Sends the specified string encoded at utf8 to the program running under the terminal emulator
     * - Parameter txt: the string to send to the client
     */
    public func send (txt: String) {
        #if os(iOS) || os(visionOS)
        if TerminalView.textInputDebugEnabled {
            print("UITextInput[\(TerminalView.textInputLogCounter + 1)]: send txt=\(txt.debugDescription)")
            TerminalView.textInputLogCounter += 1
        }
        #endif
        let array = [UInt8] (txt.utf8)
        send (data: array[...])
    }
    
    /**
     * Sends the specified array of bytes to the program running under the terminal emulator
     * - Parameter bytes: the bytes to send to the client
     */
    public func send (_ bytes: [UInt8]) {
        send (data: (bytes)[...])
    }
    
    func sendKeyUp ()
    {
        send (withTerminal { $0.applicationCursor } ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
    }
    
    func sendKeyDown ()
    {
        send (withTerminal { $0.applicationCursor } ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
    }

    private func sendHorizontalKey(left: Bool) {
        let sequence = withTerminal { terminal in
            let buffer = terminal.displayBuffer
            let row = buffer.yBase + buffer.y
            let baseDirection = TerminalBidi.resolvedBaseDirection(
                row: row, buffer: buffer, cols: terminal.cols, terminal: terminal,
                font: fontSet.normal, hostPolicy: bidiHostPolicy)
            let swap = terminal.bidiArrowKeySwap && baseDirection == .rightToLeft
            let sendLeft = swap ? !left : left
            return sendLeft
                ? (terminal.applicationCursor ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal)
                : (terminal.applicationCursor ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal)
        }
        send(sequence)
    }
    
    func sendKeyLeft()
    {
        sendHorizontalKey(left: true)
    }
    
    func sendKeyRight ()
    {
        sendHorizontalKey(left: false)
    }
    
    class AppleImage: TerminalImage {
        var image: TTImage
        var pixelWidth: Int
        var pixelHeight: Int
        var col: Int
        
        init (image: TTImage, width: Int, height: Int, onCol: Int) {
            self.image = image
            self.pixelWidth = width
            self.pixelHeight = height
            self.col = onCol
        }
    }
    // Computes the number of columns and rows used by the image
    func computeCellRows (_ size: CGSize) -> (cols: Int, rows: Int) {
        guard let metrics = cachedImageMetricsValue() else {
            return (0, 0)
        }
        let cellSize = metrics.cellSize
        return (cols: Int ((size.width+cellSize.width-1)/cellSize.width),
                rows: Int ((size.height+cellSize.height-1)/cellSize.height))
    }
    
    public nonisolated func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let pixelData = NSData(bytes: bytes, length: bytes.count)
        guard let providerRef: CGDataProvider = CGDataProvider(data: pixelData) else {
            return
        }
        guard let cgimage: CGImage = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: rgbColorSpace, bitmapInfo: bitmapInfo,
                provider: providerRef, decode: nil, shouldInterpolate: true,
                intent: .defaultIntent) else {
            return
        }
        
        let image = TTImage (cgImage: cgimage, size: CGSize (width: width, height: height))
        guard let metrics = cachedImageMetricsValue() else {
            return
        }
        let terminalWidth = CGFloat(source.cols) * metrics.cellSize.width
        insertImage(image, terminal: source,
                    width: CGFloat(width) > terminalWidth ? .percent(100) : .auto,
                    height: .auto,
                    preserveAspectRatio: true)
    }
   
    public nonisolated func createImage (source: Terminal, data: Data, width widthRequest: ImageSizeRequest, height heightRequest: ImageSizeRequest, preserveAspectRatio: Bool)
    {
        guard let img = TTImage(data: data) else {
            return
        }
        insertImage(img, terminal: source,
                    width: widthRequest,
                    height: heightRequest,
                    preserveAspectRatio: preserveAspectRatio)
    }
    
    // Inserts the specified image at the current buffer position (x, y) using the specified size requests
    // and aspect ratio request.   The insertion is done by adding slices of the image, one per line
    // to the buffer.
    nonisolated func insertImage (_ image: TTImage,
                                  terminal: Terminal,
                                  width widthRequest: ImageSizeRequest,
                                  height heightRequest: ImageSizeRequest,
                                  preserveAspectRatio: Bool)
    {
        guard let metrics = cachedImageMetricsValue() else {
            return
        }
        let cellSize = metrics.cellSize
        let buffer = terminal.buffer
        var img = image
        let displayScale = metrics.imageScale
        
        // Converts a size request in a single dimension into an absolute pixel value, where
        // the `dim` is the request, `regionSize` is the available view space, and `imageSize` is
        // the size of the image along the dimension being requested
        func getPixels (fromDim dim: ImageSizeRequest, regionSize: CGFloat, imageSize: CGFloat, cellSize: CGFloat) -> CGFloat {
            switch dim {
            case .auto:
                return imageSize/displayScale
            case .cells(let n):
                return cellSize * CGFloat (n)
            case .pixels(let n):
                return CGFloat (n)
            case .percent(let pct):
                return CGFloat (pct) * 0.01 * regionSize
            }
        }

        let widthImageSize: CGFloat
        let heightImageSize: CGFloat
        switch widthRequest {
        case .auto:
            widthImageSize = img.size.width
        default:
            widthImageSize = img.size.width
        }
        switch heightRequest {
        case .auto:
            heightImageSize = img.size.height
        default:
            heightImageSize = img.size.height
        }

        let terminalRegion = CGSize(width: CGFloat(terminal.cols) * cellSize.width,
                                    height: CGFloat(terminal.rows) * cellSize.height)
        var width = getPixels (fromDim: widthRequest, regionSize: terminalRegion.width, imageSize: widthImageSize, cellSize: cellSize.width)
        var height = getPixels (fromDim: heightRequest, regionSize: terminalRegion.height, imageSize: heightImageSize, cellSize: cellSize.height)
        
        if preserveAspectRatio {
            switch (widthRequest, heightRequest) {
            case (.auto, .auto):
                break
            case (_, .auto):
                height = (width * img.size.height) / img.size.width
            case (.auto, _):
                width = (height * img.size.width) / img.size.height
            case (_, _):
                img = scale (image: img, size: CGSize (width: width, height: height))
            }
        }
        
        let rows = Int (ceil (height/cellSize.height))
        
        let stripeSize = CGSize (width: width, height: cellSize.height)
        var didScroll = false
        #if os(iOS) || os(visionOS)
        var srcY: CGFloat = 0
        #else
        var srcY: CGFloat = img.size.height
        #endif
        
        let heightRatio = img.size.height/height
        for _ in 0..<rows {
            #if os(macOS)
            srcY -= cellSize.height * heightRatio
            #endif
            guard let stripe = drawImageInStripe (image: img, srcY: srcY, width: width, srcHeight: cellSize.height * heightRatio, dstHeight: cellSize.height, size: stripeSize) else {
                continue
            }
            #if os(iOS) || os(visionOS)
            srcY += cellSize.height * heightRatio
            #endif
            
            let attachedImage = AppleImage (image: stripe, width: Int (stripeSize.width), height: Int (cellSize.height), onCol: terminal.buffer.x)
            buffer.attachImage(attachedImage, toLineAt: buffer.y+buffer.yBase)

            terminal.updateRange (buffer.y)

            // The buffer.x position would have changed depending on the lineFeedMode (LNM)
            // for image rendering, we want the x to remain the same
            let savedX = buffer.x
            let previousYBase = buffer.yBase
            let previousLinesTop = buffer.linesTop
            terminal.cmdLineFeed()
            if buffer.yBase != previousYBase || buffer.linesTop != previousLinesTop {
                didScroll = true
            }
            buffer.x = savedX
        }
        if didScroll {
            terminal.updateFullScreen()
        }
    }
    
    /// Set to true if the selection is active, false otherwise
    public var selectionActive: Bool {
        get {
            withTerminal { _ in
                selection.active
            }
        }
    }
    
    
    /// Returns the contents of the selection, if active, or nil otherwise
    public func getSelection () -> String?
    {
        withTerminal { _ in
            if selection.active {
                return selection.getSelectedText()
            }
            return nil
        }
    }
    
    /// Selects the entire buffer
    public func selectAll () {
        withTerminal { _ in
            selection.selectAll()
        }
    }
    
    /// Clears the selection
    public func selectNone () {
        withTerminal { _ in
            selection.selectNone()
        }
    }

}

#if canImport(UIKit) && DEBUG
#Preview {
    SwiftUITerminalView { t in
        t.nativeBackgroundColor = UIColor.black
        t.selectedTextBackgroundColor = UIColor.red
        t.caretColor = UIColor.blue
        t.feed(text: "م اَلْفِرَاق\n\rbbفِaa\n\r123456\n\r🖐🏾 or 👩‍👩‍👦‍👦")
    }
}
#endif

#endif
