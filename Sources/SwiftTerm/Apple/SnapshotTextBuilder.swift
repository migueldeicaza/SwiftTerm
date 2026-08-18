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

/// Builds styled line segments from a snapshot row. Not thread safe on its
/// own: one instance belongs to one renderer.
final class SnapshotTextBuilder {
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
        var result: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foregroundColor,
            .backgroundColor: backgroundColor,
        ]
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
        // Rows without RTL content skip the writing-direction override:
        // CoreText does not reorder pure-LTR text, and omitting the attribute
        // keeps its bidi resolution machinery out of the common path.
        let needsDirectionOverride = snapshotRow.needsDirectionOverride
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

            let character = displayOverride ?? snapshotRow.character(at: col, cell: ch)
            let renderCodePoint = character.unicodeScalars.first?.value ?? 0

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
                || glyphFallback?.font !== lastGlyphFallbackFont
                || glyphFallback?.policy != lastGlyphFallbackPolicy
                || pendingAttrs == nil {
                flushPending()
                lastStyleKey = styleKey
                lastHasUrl = hasUrl
                lastIsSelected = isSelected
                lastBlinkHidden = blinkHidden
                lastGlyphFallbackFont = glyphFallback?.font
                lastGlyphFallbackPolicy = glyphFallback?.policy
                if isSelected || blinkHidden || needsDirectionOverride || glyphFallback != nil {
                    var batchAttributes = attributes.values
                    if isSelected {
                        batchAttributes[.selectionBackgroundColor] = context.selectedTextBackgroundColor
                        batchAttributes[.foregroundColor] = context.selectedTextForegroundColor
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
                    if needsDirectionOverride {
                        // SwiftTerm owns cell placement. A BiDi layout is already in
                        // visual order, and rows with RTL content on the legacy and
                        // explicit-LTR paths must keep logical cell order. The LTR
                        // override stops CoreText from applying a second,
                        // renderer-specific ordering pass.
                        batchAttributes[ltrWritingDirectionKey] = ltrWritingDirectionValue
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
                let fgColor = (currentAttributes[.foregroundColor] as? TTColor) ?? context.effectiveForegroundColor
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
                let fgColor = (currentAttributes[.foregroundColor] as? TTColor) ?? context.effectiveForegroundColor
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
                let fgColor = (currentAttributes[.foregroundColor] as? TTColor) ?? context.effectiveForegroundColor
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
            } else if !blinkHidden && bidiLayout != nil && TerminalBidi.needsCellIsolation(character) {
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
                builder?.append(text: String(character), attributes: isolatedAttributes,
                                cellUTF16Lengths: [character.utf16.count])
                if let finished = builder?.buildIfNeeded() {
                    segments.append(finished)
                }
                builder = nil
                previousPlaceholder = nil
                previousPlaceholderAttribute = nil
            } else {
                // Common path: just accumulate into the batch
                let renderedCharacter: Character = blinkHidden ? " " : character
                pendingText.append(renderedCharacter)
                var cellUTF16Length = renderedCharacter.utf16.count
                if !blinkHidden && glyphFallback == nil
                    && UnicodeUtil.prefersTextPresentation(renderedCharacter) {
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
