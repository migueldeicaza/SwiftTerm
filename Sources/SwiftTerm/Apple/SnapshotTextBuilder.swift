//
//  SnapshotTextBuilder.swift
//  SwiftTerm
//
//  Turns a `TerminalSnapshot.Row` into the styled segments a renderer draws.
//
//  This used to live on `TerminalView`, which tied the whole text-building path
//  to the main thread even though it reads nothing from the view: every input
//  arrives through `SnapshotRenderContext` (fonts, palette, colors, selection,
//  link highlight, blink state) or through the snapshot row itself.
//
//  Moving it here is what lets a renderer run off the main thread (io-gaps.md
//  G1, WO-F1b). Each renderer owns its own builder, so each gets its own
//  attribute cache and no two threads share one.
//

#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS) || os(macCatalyst)
import Foundation
import CoreGraphics
import CoreText

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One attribute dictionary in both Swift and Foundation form.
///
/// The renderer reads the Swift dictionary when it applies transient changes.
/// Core Foundation reads the bridged dictionary directly when it adds a text
/// run. Keeping both forms prevents a new bridge for each rendered run.
struct SnapshotTextAttributes {
    let values: [NSAttributedString.Key: Any]
    let objectiveC: NSDictionary

    init(_ values: [NSAttributedString.Key: Any]) {
        self.values = values
        objectiveC = values as NSDictionary
    }

    subscript(key: NSAttributedString.Key) -> Any? {
        values[key]
    }
}

/// A color of a plain run. Truecolor stays a value, so a row of cells each in
/// its own color makes no platform colors.
enum PlainColor {
    /// Red in the low byte, then green, then blue.
    case rgb(UInt32)
    case color(TTColor)

    var key: PlainColorKey {
        switch self {
        case .rgb(let value): return .rgb(value)
        case .color(let color): return .object(ObjectIdentifier(color))
        }
    }
}

enum PlainColorKey: Hashable {
    case rgb(UInt32)
    case object(ObjectIdentifier)
}

struct PlainUnderline {
    var color: PlainColor
    /// The `NSUnderlineStyle` raw value the attribute dictionary holds.
    var nsStyle: Int
    var style: UnderlineStyle
}

/// What one run's attribute dictionary holds, as values: the font, colors
/// and decorations `buildAttributes` and the per-batch adjustments put in it.
struct PlainRunStyle {
    /// 0 normal, 1 bold, 2 italic, 3 bold italic.
    var fontIndex: Int
    var foreground: PlainColor
    /// The foreground before `minimumContrastRatio` adjusts it, which the
    /// dictionary holds for shapes (`SwiftTermShapeColorKey`).
    var shapeColor: PlainColor
    var background: PlainColor
    var explicitBackground: Bool
    var selectionBackground: TTColor? = nil
    var underline: PlainUnderline? = nil
    /// The strikethrough color; the style is always single.
    var strikethrough: PlainColor? = nil
}

/// A span of cells `[start, end)` that the attributed string would hold as
/// one run.
struct PlainRun {
    let start: Int
    var end: Int
    let style: PlainRunStyle
}

/// A row of plain cells: the ASCII code drawn in each column and the runs.
struct PlainRow {
    var codes: [UInt8]
    var runs: [PlainRun]
}

private struct DimmedColorKey: Hashable {
    let foreground: PlainColorKey
    let background: PlainColorKey
}

private struct ContrastedColorKey: Hashable {
    let foreground: PlainColorKey
    let background: PlainColorKey
}

/// Builds styled line segments from a snapshot row. Not thread safe on its
/// own: one instance belongs to one renderer.
final class SnapshotTextBuilder {
    private var plainInvertedColorsContextID: UInt64 = .max
    private var plainInvertedForeground: TTColor?
    private var plainInvertedBackground: TTColor?
    /// Dimmed foregrounds by input colors, each kept with its inputs.
    private var dimmedColors: [DimmedColorKey: (dimmed: TTColor, foreground: TTColor, background: TTColor)] = [:]
    /// Contrast-adjusted foregrounds by input colors at `contrastRatio`, each
    /// kept with its inputs.
    private var contrastedColors: [ContrastedColorKey: (adjusted: PlainColor, foreground: TTColor, background: TTColor)] = [:]
    private var contrastRatio: CGFloat = 1

    private struct FallbackFontKey: Hashable {
        let baseFont: ObjectIdentifier
        let character: Character
    }

    private let trueColorCacheCapacity: Int
    private var trueColorCache: [UInt32: TTColor] = [:]

    /// Fonts resolved for characters the base font cannot render. The builder
    /// belongs to one renderer, so this cache cannot race another renderer.
    private var fallbackFonts: [FallbackFontKey: TTFont] = [:]

    init(trueColorCacheCapacity: Int = 4_096) {
        precondition(trueColorCacheCapacity > 0)
        self.trueColorCacheCapacity = trueColorCacheCapacity
        trueColorCache.reserveCapacity(min(trueColorCacheCapacity, 1_024))
    }

    var trueColorCacheCount: Int { trueColorCache.count }

    /// Attribute dictionaries for the current render context.
    ///
    /// Rebuilding these was the largest single main-thread cost in a Time
    /// Profiler trace: `[NSAttributedString.Key: Any]` has String-backed keys,
    /// so each rebuild hashes and compares NSStrings and bridges every value
    /// through ObjC.
    private(set) var attributeCache: [AttributeCacheKey: SnapshotTextAttributes] = [:]
    private var packedAttributeCache: [PackedAttributeCacheKey: SnapshotTextAttributes] = [:]
    private(set) var attributeCacheContextID: UInt64 = .max

    private func resolvedFont(for character: Character, base: TTFont) -> TTFont {
        let key = FallbackFontKey(baseFont: ObjectIdentifier(base), character: character)
        if let cached = fallbackFonts[key] {
            return cached
        }
        if fallbackFonts.count >= 1024 {
            fallbackFonts.removeAll(keepingCapacity: true)
        }
        let text = String(character) as CFString
        let resolved = CTFontCreateForString(
            base as CTFont,
            text,
            CFRange(location: 0, length: CFStringGetLength(text)))
        let font = resolved as TTFont
        fallbackFonts[key] = font
        return font
    }

    /// Identifies one attribute dictionary within a single render context.
    ///
    /// The context supplies the fonts, palette and default colors, so within
    /// one context an `Attribute` plus the URL flag determines the dictionary
    /// completely.
    struct AttributeCacheKey: Hashable {
        let attribute: Attribute
        let withUrl: Bool
    }

    /// Compact key used only by the packed renderer path.
    private struct PackedAttributeCacheKey: Hashable {
        let attribute: PackedAttributeKey
        let withUrl: Bool
    }

    /// Whether one of the context's four style faces covers a scalar. Within
    /// one render context the faces are fixed, so a small index is a stable
    /// key. Bounded; cleared together with the attribute caches.
    private struct GlyphCoverageKey: Hashable {
        let styleIndex: UInt8
        let scalar: UInt32
    }
    private var glyphCoverageCache: [GlyphCoverageKey: Bool] = [:]
    /// The provider's fallback face at the current context's point size.
    /// `.none`: not asked yet; `.some(nil)`: asked and unavailable.
    private var cachedGlyphFallbackFont: TTFont?? = nil

    /// Cached attribute dictionaries for the current render context.
    ///
    /// Rebuilding these was the single largest main-thread cost in a Time
    /// Profiler trace of a bidi flood: `[NSAttributedString.Key: Any]` has
    /// String-backed keys, so each rebuild hashes and compares NSStrings and
    /// bridges every value through ObjC. `objc_msgSend`, `__CFStringHash`,
    /// `__CFStringEqual`, `Hasher.combine` and the CF retain/release pairs
    /// together accounted for roughly 440 ms of a 2 480 ms main thread.
    ///
    /// Returning the same dictionary instance also makes the caller's
    /// `var batchAttributes = attributes` free: Swift dictionaries are
    /// copy-on-write, so an unmodified copy shares storage.
    func getAttributes (_ attribute: Attribute, withUrl: Bool,
                        context: SnapshotRenderContext) -> SnapshotTextAttributes?
    {
        prepareAttributeCache(for: context)
        let key = AttributeCacheKey(attribute: attribute, withUrl: withUrl)
        if let cached = attributeCache[key] {
            return cached
        }
        let built = buildAttributes(attribute, withUrl: withUrl, context: context)
        if let built {
            attributeCache[key] = built
        }
        return built
    }

    /// Packed renderer lookup. The dictionary hashes a 32-bit style key and
    /// expands `Attribute` only when the caller's contiguous-style cache misses.
    private func getAttributes(_ key: PackedAttributeKey, attribute: Attribute,
                               withUrl: Bool,
                               context: SnapshotRenderContext)
        -> SnapshotTextAttributes?
    {
        prepareAttributeCache(for: context)
        let cacheKey = PackedAttributeCacheKey(attribute: key, withUrl: withUrl)
        if let cached = packedAttributeCache[cacheKey] {
            return cached
        }
        let built = buildAttributes(attribute, withUrl: withUrl, context: context)
        if let built {
            packedAttributeCache[cacheKey] = built
        }
        return built
    }

    private func prepareAttributeCache(for context: SnapshotRenderContext) {
        guard attributeCacheContextID != context.identity else { return }
        // The identity changes only when an input used by the attribute
        // dictionaries changes. A new frame with the same visual inputs keeps
        // the cache warm.
        attributeCache.removeAll(keepingCapacity: true)
        packedAttributeCache.removeAll(keepingCapacity: true)
        glyphCoverageCache.removeAll(keepingCapacity: true)
        cachedGlyphFallbackFont = nil
        attributeCacheContextID = context.identity
    }

    /// Cached wrapper around ``GlyphFallbackResolver`` for the hot row loop.
    private func resolveGlyphFallback (character: Character, styleFont: TTFont,
                                       context: SnapshotRenderContext)
        -> (font: TTFont, policy: TerminalGlyphPlacementPolicy)?
    {
        guard let provider = context.glyphFallbackProvider,
              let scalar = GlyphFallbackResolver.baseScalar(of: character),
              let policy = provider.placementPolicy(for: scalar) else {
            return nil
        }
        let styleIndex: UInt8 = styleFont === context.fonts.normal ? 0
            : styleFont === context.fonts.bold ? 1
            : styleFont === context.fonts.italic ? 2 : 3
        let key = GlyphCoverageKey(styleIndex: styleIndex, scalar: scalar.value)
        let covered: Bool
        if let cached = glyphCoverageCache[key] {
            covered = cached
        } else {
            covered = GlyphFallbackResolver.fontHasGlyph(styleFont, scalar: scalar)
            if glyphCoverageCache.count >= 1024 {
                glyphCoverageCache.removeAll(keepingCapacity: true)
            }
            glyphCoverageCache[key] = covered
        }
        if covered {
            return nil
        }
        let fallbackFont: TTFont?
        if let asked = cachedGlyphFallbackFont {
            fallbackFont = asked
        } else {
            fallbackFont = provider.fallbackFont(forPointSize: context.fonts.normal.pointSize)
                .map { $0 as TTFont }
            cachedGlyphFallbackFont = .some(fallbackFont)
        }
        guard let fallbackFont else { return nil }
        return (fallbackFont, policy)
    }

    private func buildAttributes (_ attribute: Attribute, withUrl: Bool,
                                  context: SnapshotRenderContext) -> SnapshotTextAttributes?
    {
        let flags = attribute.style
        var background = attribute.bg
        var foreground = attribute.fg
        if flags.contains(.inverse) {
            swap(&background, &foreground)
            if foreground == .defaultColor { foreground = .defaultInvertedColor }
            if background == .defaultColor { background = .defaultInvertedColor }
        }

        let brightNeedsBold: Bool
        if case .ansi256(let code) = foreground {
            brightNeedsBold = code > 7 && !context.useBrightColors
        } else {
            brightNeedsBold = false
        }
        let isBold = flags.contains(.bold)
        let font: TTFont
        if isBold || brightNeedsBold {
            font = flags.contains(.italic) ? context.fonts.boldItalic : context.fonts.bold
        } else {
            font = flags.contains(.italic) ? context.fonts.italic : context.fonts.normal
        }

        var foregroundColor = mapColor(color: foreground, isFg: true,
                                       isBold: isBold, context: context)
        let backgroundColor = mapColor(color: background, isFg: false,
                                       isBold: false, context: context)
        if flags.contains(.dim) {
            foregroundColor = foregroundColor.dimmedColor(towards: backgroundColor)
        }
        if withUrl, let linkColor = context.linkColor {
            // The host's link color replaces the cell's own for the text and
            // every line drawn with it: the link underline added below, and
            // any SGR underline or strikethrough. The contrast floor below
            // still applies to it, as it does to any other color.
            foregroundColor = linkColor
        }
        let shapeColor = foregroundColor
        foregroundColor = foregroundColor.withContrast(atLeast: context.minimumContrastRatio,
                                                       against: backgroundColor)
        // SwiftTerm owns cell placement. A BiDi layout is already in visual
        // order, and rows on the legacy and explicit-LTR paths must keep
        // logical cell order, so CoreText must not reorder anything. Every row
        // gets the override and a left-to-right paragraph: a row with no strong
        // character (only digits, spaces and punctuation) would otherwise be
        // laid out in the process's default direction, which is right to left
        // when the app runs in an RTL language. The Metal renderer sets the
        // same override on everything it shapes.
        var result: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foregroundColor,
            .backgroundColor: backgroundColor,
            SwiftTermShapeColorKey: shapeColor,
            ltrWritingDirectionKey: ltrWritingDirectionValue,
            .paragraphStyle: ltrParagraphStyle,
        ]
        if background != .defaultColor {
            result[SwiftTermExplicitBackgroundKey] = true
        }
        if flags.contains(.underline) {
            let color = attribute.underlineColor.map {
                mapColor(color: $0, isFg: true, isBold: isBold, context: context)
            } ?? foregroundColor
            let variant = attribute.underlineStyle == .none ? UnderlineStyle.single : attribute.underlineStyle
            result[.underlineColor] = color
            result[.underlineStyle] = nsUnderlineStyle(variant).rawValue
            result[SwiftTermUnderlineStyleKey] = Int(variant.rawValue)
        }
        if flags.contains(.crossedOut) {
            result[.strikethroughColor] = foregroundColor
            result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if withUrl {
            result[.underlineStyle] = NSUnderlineStyle.single.rawValue
            result[.underlineColor] = foregroundColor
            result[SwiftTermUnderlineStyleKey] = Int(UnderlineStyle.dashed.rawValue)
        }
        return SnapshotTextAttributes(result)
    }

    /// The color for Powerline separators, box drawing, and block elements:
    /// the program's color before `minimumContrastRatio` adjusts it, since
    /// these characters draw shapes, such as pixel art, meant to blend in.
    private func shapeColor(of attributes: SnapshotTextAttributes,
                            context: SnapshotRenderContext) -> TTColor
    {
        (attributes[SwiftTermShapeColorKey] as? TTColor)
            ?? (attributes[.foregroundColor] as? TTColor)
            ?? context.effectiveForegroundColor
    }

    /// Maps one terminal color to a platform color. Truecolor values are
    /// interned so repeated cells share the same object in renderer caches.
    func mapColor(color: Attribute.Color, isFg: Bool, isBold: Bool,
                  context: SnapshotRenderContext) -> TTColor
    {
        guard case .trueColor(let red, let green, let blue) = color else {
            return SwiftTerm.mapColor(color: color, isFg: isFg,
                                      isBold: isBold, context: context)
        }

        let key = UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
        if let cached = trueColorCache[key] {
            return cached
        }
        if trueColorCache.count >= trueColorCacheCapacity {
            trueColorCache.removeAll(keepingCapacity: true)
        }
        let value = TTColor.make(red: CGFloat(red) / 255,
                                 green: CGFloat(green) / 255,
                                 blue: CGFloat(blue) / 255,
                                 alpha: 1)
        trueColorCache[key] = value
        return value
    }





    func buildAttributedString (row snapshotRow: TerminalSnapshot.Row, absoluteRow: Int,
                                context: SnapshotRenderContext) -> ViewLineInfo
    {
        var segments: [ViewLineSegment] = []
        let line = snapshotRow.line
        let cols = context.cols
        let selectionColumns = context.selection.columns(forRow: absoluteRow)
        var col = 0
        var builder: TerminalView.ViewLineSegmentBuilder?

        let bidiLayout = snapshotRow.bidiLayout
        var visualCol = 0
        var visualIndex = 0
        var kittyPlaceholders: [KittyPlaceholderCell] = []
        var previousPlaceholder: KittyPlaceholderCell?
        var previousPlaceholderAttribute: Attribute?
        var blockElements: [BlockElementRenderItem] = []
        var boxDrawings: [BoxDrawingRenderItem] = []
        var powerlineGlyphs: [PowerlineRenderItem] = []
        
        // Batching state: accumulate consecutive characters with the same attributes
        var pendingText = ""
        var pendingCellLengths: [Int] = []
        var pendingAttrs: SnapshotTextAttributes? = nil
        var lastStyleKey: PackedAttributeKey?
        var lastHasUrl = false
        var lastIsSelected = false
        var lastBlinkHidden = false
        var lastUsesShapeColor = false
        var lastGlyphFallbackFont: TTFont?
        var lastGlyphFallbackPolicy: TerminalGlyphPlacementPolicy?
        var decodedStyleKey: PackedAttributeKey?
        var decodedAttribute = CharData.defaultAttr
        var baseAttributesStyleKey: PackedAttributeKey?
        var baseAttributesHasUrl = false
        var baseAttributes: SnapshotTextAttributes?

        func flushPending() {
            if !pendingText.isEmpty, let attrs = pendingAttrs {
                builder?.append(text: pendingText, attributes: attrs,
                                cellUTF16Lengths: pendingCellLengths)
                pendingText = ""
                pendingCellLengths = []
            }
        }

        while true {
            var displayOverride: Character? = nil
            if let bidiLayout {
                guard visualIndex < bidiLayout.visualCells.count else { break }
                let visualCell = bidiLayout.visualCells[visualIndex]
                visualIndex += 1
                col = visualCell.logicalCol
                displayOverride = visualCell.display
            } else if col >= cols {
                break
            }
            let ch = line.packedView(at: col)
            let width = max(1, Int(ch.width))
            let styleKey = ch.attributeKey
            let attr: Attribute
            if decodedStyleKey == styleKey {
                attr = decodedAttribute
            } else {
                attr = ch.attribute
                decodedStyleKey = styleKey
                decodedAttribute = attr
            }
            let hasUrl = shouldUnderlineLink(row: absoluteRow, column: col, width: width,
                                             cell: ch, context: context)
            let attributes: SnapshotTextAttributes?
            if baseAttributesStyleKey == styleKey && baseAttributesHasUrl == hasUrl {
                attributes = baseAttributes
            } else {
                attributes = getAttributes(styleKey, attribute: attr, withUrl: hasUrl,
                                           context: context)
                baseAttributesStyleKey = styleKey
                baseAttributesHasUrl = hasUrl
                baseAttributes = attributes
            }
            guard let attributes else {
                flushPending()
                if let finished = builder?.buildIfNeeded() {
                    segments.append(finished)
                }
                builder = nil
                previousPlaceholder = nil
                previousPlaceholderAttribute = nil
                if bidiLayout == nil {
                    col += width
                }
                visualCol += width
                continue
            }

            if builder == nil || builder!.columnWidth != width {
                flushPending()
                if let finished = builder?.buildIfNeeded() {
                    segments.append(finished)
                }
                builder = TerminalView.ViewLineSegmentBuilder(column: visualCol, columnWidth: width)
            }

            let isSelected = isColumnSelected(selectionColumns, column: col, width: width)
            let blinkHidden = !context.textBlinkVisible && attr.style.contains(.blink)

            let text: String
            let character: Character
            if let displayOverride {
                character = displayOverride
                text = String(displayOverride)
            } else {
                text = snapshotRow.text(at: col, cell: ch)
                character = text.first ?? " "
            }
            let renderCodePoint = character.unicodeScalars.first?.value ?? 0
            // Font-rendered shapes must keep the same color as custom shapes.
            let usesShapeColor = !context.customBlockGlyphs && context.minimumContrastRatio > 1
                && ((renderCodePoint >= UInt32(BoxDrawingRenderer.lowerBoundary)
                     && renderCodePoint <= UInt32(BlockElementMapping.upperBoundary))
                    || PowerlineRenderer.glyph(for: renderCodePoint) != nil)

            // Host glyph fallback: cells the custom Powerline/box/block
            // renderers will consume below keep those dedicated paths.
            var glyphFallback: (font: TTFont, policy: TerminalGlyphPlacementPolicy)? = nil
            if context.glyphFallbackProvider != nil, !blinkHidden,
               !PowerlineRenderer.shouldRender(codePoint: renderCodePoint,
                                              customGlyphsEnabled: context.customBlockGlyphs),
               !(context.customBlockGlyphs
                 && renderCodePoint >= UInt32(BoxDrawingRenderer.lowerBoundary)
                 && renderCodePoint <= UInt32(BlockElementMapping.upperBoundary)) {
                let styleFont = (attributes[.font] as? TTFont) ?? context.fonts.normal
                glyphFallback = resolveGlyphFallback(character: character, styleFont: styleFont,
                                                     context: context)
            }

            // Flush batch when attributes change; the batch dictionary is only
            // rebuilt at these boundaries, so unchanged cells append without
            // copying it.
            if styleKey != lastStyleKey || hasUrl != lastHasUrl || isSelected != lastIsSelected
                || blinkHidden != lastBlinkHidden
                || usesShapeColor != lastUsesShapeColor
                || glyphFallback?.font !== lastGlyphFallbackFont
                || glyphFallback?.policy != lastGlyphFallbackPolicy
                || pendingAttrs == nil {
                flushPending()
                lastStyleKey = styleKey
                lastHasUrl = hasUrl
                lastIsSelected = isSelected
                lastBlinkHidden = blinkHidden
                lastUsesShapeColor = usesShapeColor
                lastGlyphFallbackFont = glyphFallback?.font
                lastGlyphFallbackPolicy = glyphFallback?.policy
                if isSelected || blinkHidden || usesShapeColor || glyphFallback != nil {
                    var batchAttributes = attributes.values
                    if usesShapeColor {
                        batchAttributes[.foregroundColor] = shapeColor(of: attributes, context: context)
                    }
                    if isSelected {
                        batchAttributes[.selectionBackgroundColor] = context.selectedTextBackgroundColor
                        batchAttributes[.foregroundColor] = context.selectedTextForegroundColor
                        batchAttributes[SwiftTermShapeColorKey] = context.selectedTextForegroundColor
                        if batchAttributes[.underlineColor] != nil {
                            batchAttributes[.underlineColor] = context.selectedTextForegroundColor
                        }
                        if batchAttributes[.strikethroughColor] != nil {
                            batchAttributes[.strikethroughColor] = context.selectedTextForegroundColor
                        }
                    }
                    if blinkHidden {
                        batchAttributes[.foregroundColor] = TTColor.clear
                        batchAttributes.removeValue(forKey: .underlineColor)
                        batchAttributes.removeValue(forKey: .underlineStyle)
                        batchAttributes.removeValue(forKey: .strikethroughColor)
                        batchAttributes.removeValue(forKey: .strikethroughStyle)
                        batchAttributes.removeValue(forKey: SwiftTermUnderlineStyleKey)
                    }
                    if let glyphFallback {
                        batchAttributes[.font] = glyphFallback.font
                        batchAttributes[SwiftTermGlyphPolicyKey] = glyphFallback.policy
                    }
                    pendingAttrs = SnapshotTextAttributes(batchAttributes)
                } else {
                    pendingAttrs = attributes
                }
            }
            let currentAttributes = pendingAttrs!

            // Render Powerline separators independently of the font so their
            // joining edge shares the background's exact pixel boundary.
            if !blinkHidden && PowerlineRenderer.shouldRender(codePoint: renderCodePoint,
                                              customGlyphsEnabled: context.customBlockGlyphs) {
                flushPending()
                let fgColor = shapeColor(of: currentAttributes, context: context)
                powerlineGlyphs.append(PowerlineRenderItem(column: visualCol,
                                                           columnWidth: width,
                                                           codePoint: renderCodePoint,
                                                           foregroundColor: fgColor))
                builder?.append(text: " ", attributes: currentAttributes,
                                cellUTF16Lengths: [1])
                previousPlaceholder = nil
                previousPlaceholderAttribute = nil
            // Renders box drawing characters independently of the font
            // U+2500...U+257F
            } else if !blinkHidden, context.customBlockGlyphs,
               renderCodePoint >= UInt32(BoxDrawingRenderer.lowerBoundary),
               renderCodePoint <= UInt32(BoxDrawingRenderer.upperBoundary) {
                flushPending()
                let fgColor = shapeColor(of: currentAttributes, context: context)
                boxDrawings.append(BoxDrawingRenderItem(column: visualCol,
                                                        columnWidth: width,
                                                        codePoint: renderCodePoint,
                                                        foregroundColor: fgColor))
                builder?.append(text: " ", attributes: currentAttributes, cellUTF16Lengths: [1])
                previousPlaceholder = nil
                previousPlaceholderAttribute = nil
            // Renders block elements independently of the font
            // U+2580...U+259F
            } else if !blinkHidden, context.customBlockGlyphs,
                      (renderCodePoint >= UInt32(BlockElementMapping.lowerBoundary)
                       && renderCodePoint <= UInt32(BlockElementMapping.upperBoundary)),
                      let rects = BlockElementMapping.rects(for: renderCodePoint) {
                flushPending()
                let fgColor = shapeColor(of: currentAttributes, context: context)
                blockElements.append(BlockElementRenderItem(column: visualCol,
                                                            columnWidth: width,
                                                            codePoint: renderCodePoint,
                                                            rects: rects,
                                                            foregroundColor: fgColor))
                builder?.append(text: " ", attributes: currentAttributes, cellUTF16Lengths: [1])
                previousPlaceholder = nil
                previousPlaceholderAttribute = nil
            } else if let placeholder = KittyPlaceholderDecoder.decode(character: character,
                                                                       attribute: attr,
                                                                       row: absoluteRow,
                                                                       col: visualCol,
                                                                       previous: previousPlaceholder,
                                                                       previousAttribute: previousPlaceholderAttribute) {
                flushPending()
                kittyPlaceholders.append(placeholder)
                builder?.append(text: " ", attributes: currentAttributes, cellUTF16Lengths: [1])
                previousPlaceholder = placeholder
                previousPlaceholderAttribute = attr
            } else if !blinkHidden && bidiLayout != nil &&
                      TerminalBidi.needsCellIsolation(
                        character, scalarCount: text.unicodeScalars.count) {
                // In BiDi rows, Arabic-script cells and cells holding combining
                // sequences or emoji are isolated into their own column-anchored
                // segment so that font-side ligation or extra mark glyphs cannot
                // shift the columns of the cells that follow them.
                flushPending()
                if let finished = builder?.buildIfNeeded() {
                    segments.append(finished)
                }
                builder = TerminalView.ViewLineSegmentBuilder(column: visualCol, columnWidth: width)
                // Resolve the fallback font here, once per (font, character):
                // otherwise every one of these single-cell CTLines re-runs the
                // font cascade to discover the same Arabic-capable font.
                var isolatedValues = currentAttributes.values
                if glyphFallback == nil {
                    let baseFont = (currentAttributes[.font] as? TTFont) ?? context.fonts.normal
                    isolatedValues[.font] = resolvedFont(for: character, base: baseFont)
                }
                let isolatedAttributes = SnapshotTextAttributes(isolatedValues)
                builder?.append(text: text, attributes: isolatedAttributes,
                                cellUTF16Lengths: [text.utf16.count])
                if let finished = builder?.buildIfNeeded() {
                    segments.append(finished)
                }
                builder = nil
                previousPlaceholder = nil
                previousPlaceholderAttribute = nil
            } else {
                // Common path: just accumulate into the batch
                let renderedText = blinkHidden ? " " : text
                pendingText.append(contentsOf: renderedText)
                var cellUTF16Length = renderedText.utf16.count
                if !blinkHidden && glyphFallback == nil
                    && UnicodeUtil.prefersTextPresentation(character) {
                    // Steer font fallback away from Apple Color Emoji for
                    // default-text-presentation symbols (see prefersTextPresentation).
                    // A host glyph fallback sets an explicit font, so there is
                    // no cascade to steer.
                    pendingText.append("\u{FE0E}")
                    cellUTF16Length += 1
                }
                pendingCellLengths.append(cellUTF16Length)
                previousPlaceholder = nil
                previousPlaceholderAttribute = nil
            }

            if bidiLayout == nil {
                col += width
            }
            visualCol += width
        }
        flushPending()
        
        if let finished = builder?.buildIfNeeded() {
            segments.append(finished)
        }
        
        return ViewLineInfo(segments: segments,
                            images: snapshotRow.images,
                            kittyPlaceholders: kittyPlaceholders,
                            blockElements: blockElements,
                            boxDrawings: boxDrawings,
                            powerlineGlyphs: powerlineGlyphs)
    }

    // MARK: Plain rows

    /// The row as runs of plain cells, or nil when any cell is not plain.
    ///
    /// A plain cell is one column wide and holds printable ASCII or nothing.
    /// For a row of them `buildAttributedString` makes a single segment whose
    /// runs are the longest spans of cells with equal attribute dictionaries;
    /// this returns the same runs, each with its dictionary's content as
    /// values, without building the dictionaries or the attributed string.
    /// The renderer shapes such runs itself when their fonts allow it
    /// (`PlainTextFont`).
    func plainRow (row snapshotRow: TerminalSnapshot.Row, absoluteRow: Int,
                   context: SnapshotRenderContext) -> PlainRow?
    {
        guard snapshotRow.bidiLayout == nil else { return nil }
        let line = snapshotRow.line
        let cols = context.cols
        let selectionColumns = context.selection.columns(forRow: absoluteRow)
        var codes: [UInt8] = []
        codes.reserveCapacity(cols)
        var runs: [PlainRun] = []
        var decodedStyleKey: PackedAttributeKey?
        var decodedAttribute = CharData.defaultAttr
        var lastStyleKey: PackedAttributeKey?
        var lastHasUrl = false
        var lastIsSelected = false
        var lastBlinkHidden = false
        for col in 0..<cols {
            let cell = line.packedView(at: col)
            guard cell.width == 1, cell.isSimpleRune else { return nil }
            let code = UInt32(bitPattern: cell.code)
            guard code == 0 || PlainTextFont.isPlain(code) else { return nil }
            let styleKey = cell.attributeKey
            let attribute: Attribute
            if decodedStyleKey == styleKey {
                attribute = decodedAttribute
            } else {
                attribute = cell.attribute
                decodedStyleKey = styleKey
                decodedAttribute = attribute
            }
            let hasUrl = shouldUnderlineLink(row: absoluteRow, column: col, width: 1,
                                             cell: cell, context: context)
            let isSelected = isColumnSelected(selectionColumns, column: col, width: 1)
            let blinkHidden = !context.textBlinkVisible && attribute.style.contains(.blink)
            codes.append(blinkHidden || code == 0 ? 0x20 : UInt8(code))
            if let last = runs.indices.last, styleKey == lastStyleKey, hasUrl == lastHasUrl,
               isSelected == lastIsSelected, blinkHidden == lastBlinkHidden {
                runs[last].end = col + 1
                continue
            }
            lastStyleKey = styleKey
            lastHasUrl = hasUrl
            lastIsSelected = isSelected
            lastBlinkHidden = blinkHidden
            var style = plainStyle(attribute, withUrl: hasUrl, context: context)
            // The same adjustments `buildAttributedString` makes to a batch.
            if isSelected {
                style.selectionBackground = context.selectedTextBackgroundColor
                style.foreground = .color(context.selectedTextForegroundColor)
                style.shapeColor = .color(context.selectedTextForegroundColor)
                style.underline?.color = .color(context.selectedTextForegroundColor)
                if style.strikethrough != nil {
                    style.strikethrough = .color(context.selectedTextForegroundColor)
                }
            }
            if blinkHidden {
                style.foreground = .color(TTColor.clear)
                style.underline = nil
                style.strikethrough = nil
            }
            if let last = runs.indices.last, sameAttributes(runs[last].style, style, context: context) {
                runs[last].end = col + 1
            } else {
                runs.append(PlainRun(start: col, end: col + 1, style: style))
            }
        }
        return PlainRow(codes: codes, runs: runs)
    }

    /// `buildAttributes` as values.
    private func plainStyle (_ attribute: Attribute, withUrl: Bool,
                             context: SnapshotRenderContext) -> PlainRunStyle
    {
        let flags = attribute.style
        var background = attribute.bg
        var foreground = attribute.fg
        if flags.contains(.inverse) {
            swap(&background, &foreground)
            if foreground == .defaultColor { foreground = .defaultInvertedColor }
            if background == .defaultColor { background = .defaultInvertedColor }
        }
        let brightNeedsBold: Bool
        if case .ansi256(let code) = foreground {
            brightNeedsBold = code > 7 && !context.useBrightColors
        } else {
            brightNeedsBold = false
        }
        let isBold = flags.contains(.bold)
        let fontIndex: Int
        if isBold || brightNeedsBold {
            fontIndex = flags.contains(.italic) ? 3 : 1
        } else {
            fontIndex = flags.contains(.italic) ? 2 : 0
        }
        var foregroundColor = plainColor(foreground, isFg: true, isBold: isBold, context: context)
        let backgroundColor = plainColor(background, isFg: false, isBold: false, context: context)
        if flags.contains(.dim) {
            foregroundColor = .color(dimmedColor(foregroundColor, towards: backgroundColor,
                                                 context: context))
        }
        let shapeColor = foregroundColor
        foregroundColor = contrastedColor(foregroundColor, against: backgroundColor, context: context)
        var style = PlainRunStyle(fontIndex: fontIndex,
                                  foreground: foregroundColor,
                                  shapeColor: shapeColor,
                                  background: backgroundColor,
                                  explicitBackground: background != .defaultColor)
        if flags.contains(.underline) {
            let color = attribute.underlineColor.map {
                plainColor($0, isFg: true, isBold: isBold, context: context)
            } ?? foregroundColor
            let variant = attribute.underlineStyle == .none ? UnderlineStyle.single : attribute.underlineStyle
            style.underline = PlainUnderline(color: color,
                                             nsStyle: nsUnderlineStyle(variant).rawValue,
                                             style: variant)
        }
        if flags.contains(.crossedOut) {
            style.strikethrough = foregroundColor
        }
        if withUrl {
            style.underline = PlainUnderline(color: foregroundColor,
                                             nsStyle: NSUnderlineStyle.single.rawValue,
                                             style: .dashed)
        }
        return style
    }

    /// `mapColor` without making a platform color for a truecolor value.
    private func plainColor (_ color: Attribute.Color, isFg: Bool, isBold: Bool,
                             context: SnapshotRenderContext) -> PlainColor
    {
        switch color {
        case .trueColor(let red, let green, let blue):
            return .rgb(UInt32(red) | UInt32(green) << 8 | UInt32(blue) << 16)
        case .defaultInvertedColor:
            // `mapColor` makes a new color each call; the attribute cache
            // makes it once per attribute. One per context is as good.
            if plainInvertedColorsContextID != context.identity {
                plainInvertedForeground = mapColor(color: .defaultInvertedColor, isFg: true,
                                                   isBold: false, context: context)
                plainInvertedBackground = mapColor(color: .defaultInvertedColor, isFg: false,
                                                   isBold: false, context: context)
                plainInvertedColorsContextID = context.identity
            }
            return .color(isFg ? plainInvertedForeground! : plainInvertedBackground!)
        case .defaultColor, .ansi256:
            return .color(SwiftTerm.mapColor(color: color, isFg: isFg, isBold: isBold, context: context))
        }
    }

    /// The platform color the shaped path holds for `color`.
    func platformColor (_ color: PlainColor, context: SnapshotRenderContext) -> TTColor {
        switch color {
        case .rgb(let value):
            return mapColor(color: .trueColor(red: UInt8(value & 0xff),
                                              green: UInt8((value >> 8) & 0xff),
                                              blue: UInt8((value >> 16) & 0xff)),
                            isFg: true, isBold: false, context: context)
        case .color(let color):
            return color
        }
    }

    private func dimmedColor (_ foreground: PlainColor, towards background: PlainColor,
                              context: SnapshotRenderContext) -> TTColor
    {
        let key = DimmedColorKey(foreground: foreground.key, background: background.key)
        if let cached = dimmedColors[key] {
            return cached.dimmed
        }
        let foregroundColor = platformColor(foreground, context: context)
        let backgroundColor = platformColor(background, context: context)
        let dimmed = foregroundColor.dimmedColor(towards: backgroundColor)
        if dimmedColors.count >= 1_024 {
            dimmedColors.removeAll(keepingCapacity: true)
        }
        // The entry keeps both inputs alive, so their identities in the key
        // cannot be reused by other colors while it exists.
        dimmedColors[key] = (dimmed, foregroundColor, backgroundColor)
        return dimmed
    }

    /// `withContrast(atLeast:against:)` on the colors the shaped path holds.
    /// The adjustment returns its input unchanged when the ratio is off or
    /// already met, and then the value is kept as it is.
    private func contrastedColor (_ foreground: PlainColor, against background: PlainColor,
                                  context: SnapshotRenderContext) -> PlainColor
    {
        let ratio = context.minimumContrastRatio
        guard ratio > 1 else { return foreground }
        if contrastRatio != ratio {
            contrastedColors.removeAll(keepingCapacity: true)
            contrastRatio = ratio
        }
        let key = ContrastedColorKey(foreground: foreground.key, background: background.key)
        if let cached = contrastedColors[key] {
            return cached.adjusted
        }
        let foregroundColor = platformColor(foreground, context: context)
        let backgroundColor = platformColor(background, context: context)
        let adjusted = foregroundColor.withContrast(atLeast: ratio, against: backgroundColor)
        let result: PlainColor = adjusted === foregroundColor ? foreground : .color(adjusted)
        if contrastedColors.count >= 1_024 {
            contrastedColors.removeAll(keepingCapacity: true)
        }
        // The entry keeps both inputs alive, so their identities in the key
        // cannot be reused by other colors while it exists.
        contrastedColors[key] = (result, foregroundColor, backgroundColor)
        return result
    }

    /// Whether the attribute dictionaries `buildAttributedString` would give
    /// two cells are equal, which is when the attributed string merges them
    /// into one run.
    private func sameAttributes (_ a: PlainRunStyle, _ b: PlainRunStyle,
                                 context: SnapshotRenderContext) -> Bool
    {
        guard a.explicitBackground == b.explicitBackground,
              (a.selectionBackground == nil) == (b.selectionBackground == nil),
              (a.underline == nil) == (b.underline == nil),
              (a.strikethrough == nil) == (b.strikethrough == nil) else {
            return false
        }
        if a.fontIndex != b.fontIndex,
           !Self.font(a.fontIndex, context).isEqual(Self.font(b.fontIndex, context)) {
            return false
        }
        guard sameColor(a.foreground, b.foreground, context: context),
              sameColor(a.shapeColor, b.shapeColor, context: context),
              sameColor(a.background, b.background, context: context) else {
            return false
        }
        if let selectionA = a.selectionBackground, let selectionB = b.selectionBackground,
           !(selectionA === selectionB || selectionA.isEqual(selectionB)) {
            return false
        }
        if let underlineA = a.underline, let underlineB = b.underline {
            guard underlineA.nsStyle == underlineB.nsStyle, underlineA.style == underlineB.style,
                  sameColor(underlineA.color, underlineB.color, context: context) else {
                return false
            }
        }
        if let strikeA = a.strikethrough, let strikeB = b.strikethrough,
           !sameColor(strikeA, strikeB, context: context) {
            return false
        }
        return true
    }

    /// Platform color equality. Two truecolor values make equal colors
    /// exactly when they are the same value.
    private func sameColor (_ a: PlainColor, _ b: PlainColor, context: SnapshotRenderContext) -> Bool {
        switch (a, b) {
        case (.rgb(let x), .rgb(let y)):
            return x == y
        case (.color(let x), .color(let y)):
            return x === y || x.isEqual(y)
        default:
            return platformColor(a, context: context).isEqual(platformColor(b, context: context))
        }
    }

    static func font (_ index: Int, _ context: SnapshotRenderContext) -> TTFont {
        switch index {
        case 1: return context.fonts.bold
        case 2: return context.fonts.italic
        case 3: return context.fonts.boldItalic
        default: return context.fonts.normal
        }
    }

    func shouldUnderlineLink(row: Int, column: Int, width: Int, cell: PackedCellView,
                             context: SnapshotRenderContext) -> Bool
    {
        switch context.linkHighlightMode {
        case .always:
            return cell.hasPayload
        case .alwaysWithModifier:
            return context.commandActive && cell.hasPayload
        case .hover:
            guard let highlight = context.linkHighlightRange?.first(where: { $0.row == row }) else {
                return false
            }
            return highlight.range.overlaps(column..<(column + width))
        case .hoverWithModifier:
            guard context.commandActive,
                  let highlight = context.linkHighlightRange?.first(where: { $0.row == row }) else {
                return false
            }
            return highlight.range.overlaps(column..<(column + width))
        }
    }

    func isColumnSelected(_ selectionRange: Range<Int>?, column: Int, width: Int) -> Bool {
        guard let selectionRange else {
            return false
        }
        let endColumn = column + width
        return selectionRange.lowerBound < endColumn && column < selectionRange.upperBound
    }
}

// Shared by the view (Core Graphics path) and SnapshotTextBuilder: pure
// functions of their arguments, so they belong at file scope rather than on
// either type.
func nsUnderlineStyle(_ style: UnderlineStyle) -> NSUnderlineStyle {
    switch style {
    case .none:
        return []
    case .single:
        return .single
    case .double:
        return .double
    case .curly:
        return .single
    case .dotted:
        return [.single, .patternDot]
    case .dashed:
        return [.single, .patternDash]
    }
}

func mapColor (color: Attribute.Color, isFg: Bool, isBold: Bool,
               context: SnapshotRenderContext) -> TTColor
{
    switch color {
    case .defaultColor:
        return isFg ? context.effectiveForegroundColor : context.effectiveBackgroundColor
    case .defaultInvertedColor:
        return (isFg ? context.effectiveBackgroundColor : context.effectiveForegroundColor)
            .withAlphaComponent(1)
    case .ansi256(let ansi):
        let index: Int
        if context.useBrightColors {
            index = ansi < 7 ? Int(ansi) + (isBold ? 8 : 0) : Int(ansi)
        } else {
            index = ansi > 7 ? Int(ansi) - 8 : Int(ansi)
        }
        guard index >= 0, index < context.ansiColors.count else {
            return isFg ? context.effectiveForegroundColor : context.effectiveBackgroundColor
        }
        return context.ansiColors[index]
    case .trueColor(let red, let green, let blue):
        return TTColor.make(red: CGFloat(red) / 255,
                            green: CGFloat(green) / 255,
                            blue: CGFloat(blue) / 255,
                            alpha: 1)
    }
}

/// Text attributes for one cell drawn in explicit colors — the caret, which
/// paints the cell under it in the cursor's colors rather than the cell's own.
///
/// File scope and context-parameterised so `TerminalSnapshot.refresh` can call
/// it without a view (io-gaps.md G1): the refresh runs under the terminal lock
/// and, from WO-F4 on, on a render thread.
func attributedValue (for attribute: Attribute, usingFg: TTColor, andBg: TTColor,
                      context: SnapshotRenderContext) -> [NSAttributedString.Key: Any]
{
    let flags = attribute.style
    var background = andBg
    var foreground = usingFg
    if flags.contains(.inverse) {
        swap(&background, &foreground)
    }

    let font: TTFont
    if flags.contains(.bold) {
        font = flags.contains(.italic) ? context.fonts.boldItalic : context.fonts.bold
    } else {
        font = flags.contains(.italic) ? context.fonts.italic : context.fonts.normal
    }
    var result: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: foreground,
        .backgroundColor: background,
    ]
    if flags.contains(.underline) {
        let color = attribute.underlineColor.map {
            mapColor(color: $0, isFg: true, isBold: flags.contains(.bold), context: context)
        } ?? foreground
        let variant = attribute.underlineStyle == .none ? UnderlineStyle.single : attribute.underlineStyle
        result[.underlineColor] = color
        result[.underlineStyle] = nsUnderlineStyle(variant).rawValue
        result[SwiftTermUnderlineStyleKey] = Int(variant.rawValue)
    }
    if flags.contains(.crossedOut) {
        result[.strikethroughColor] = foreground
        result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
    }
    return result
}
#endif

#endif // !SWIFTTERM_EMBEDDED
