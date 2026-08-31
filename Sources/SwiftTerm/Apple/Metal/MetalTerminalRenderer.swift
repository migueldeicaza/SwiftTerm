#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
#if canImport(os)
import os
#endif
import CoreText
import Metal
import MetalKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct GlyphKey: Hashable {
    let rasterFontToken: UInt32
    let glyph: CGGlyph
}

private struct CoreTextFontIdentity: Hashable {
    let font: CTFont
    private let coreTextHash: CFHashCode

    init(_ font: CTFont) {
        self.font = font
        coreTextHash = CFHash(font)
    }

    static func == (lhs: CoreTextFontIdentity, rhs: CoreTextFontIdentity) -> Bool {
        CFEqual(lhs.font, rhs.font)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(coreTextHash)
    }
}

private struct ProfileFullFontIdentity: Hashable {
    let rasterFont: CoreTextFontIdentity
    let fittingFont: CoreTextFontIdentity
    let renderingScale: CGFloat
}

private struct ProfileFullGlyphKey: Hashable {
    let fullFontToken: UInt32
    let glyph: CGGlyph
}

/// Bounded, renderer-owned cache for platform color-space conversions.
///
/// Each entry retains its color. This prevents an object address from being
/// reused for a different color while its identity remains in the cache.
/// Dynamic platform colors are resolved into frame values on the main actor
/// before they reach this render-owned cache.
final class MetalColorSIMDCache {
    let maxEntries: Int
    private var entries: [ObjectIdentifier: SIMD4<Float>] = [:]
    private var retainedColors: [TTColor] = []

    init(maxEntries: Int = 4_096) {
        precondition(maxEntries > 0)
        self.maxEntries = maxEntries
        entries.reserveCapacity(min(maxEntries, 1_024))
        retainedColors.reserveCapacity(min(maxEntries, 1_024))
    }

    var count: Int { entries.count }

    @inline(__always)
    func value(for color: TTColor) -> SIMD4<Float> {
        let identity = ObjectIdentifier(color)
        if let cached = entries[identity] {
            return cached
        }

        let value = convert(color)
        if entries.count >= maxEntries {
            entries.removeAll(keepingCapacity: true)
            retainedColors.removeAll(keepingCapacity: true)
        }
        // Keep the object alive while its identity is a key. Cache hits then
        // read only the SIMD value and do not copy a strong reference.
        retainedColors.append(color)
        entries[identity] = value
        return value
    }

    private func convert(_ color: TTColor) -> SIMD4<Float> {
        #if os(macOS)
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
        #else
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
        }
        let cgColor = color.cgColor
        let components = cgColor.components ?? [0, 0, 0, 1]
        if components.count >= 4 {
            return SIMD4<Float>(Float(components[0]),
                                Float(components[1]),
                                Float(components[2]),
                                Float(components[3]))
        }
        if components.count == 2 {
            return SIMD4<Float>(Float(components[0]),
                                Float(components[0]),
                                Float(components[0]),
                                Float(components[1]))
        }
        return SIMD4<Float>(0, 0, 0, 1)
        #endif
    }
}

/// Gives equivalent Core Text fonts one renderer-owned atlas token.
///
/// Core Text equality includes size, matrix, and variation attributes. The
/// registry therefore avoids a font-name string on each glyph lookup without
/// merging font configurations that can produce different bitmaps.
final class RasterFontRegistry {
    let maxFonts: Int
    private var tokensByFont: [CoreTextFontIdentity: UInt32] = [:]
    private var nextToken: UInt32 = 1

    init(maxFonts: Int = 4_096) {
        precondition(maxFonts > 0)
        self.maxFonts = maxFonts
        tokensByFont.reserveCapacity(min(maxFonts, 64))
    }

    var count: Int { tokensByFont.count }

    func intern(_ rasterFont: CTFont) -> UInt32? {
        let identity = CoreTextFontIdentity(rasterFont)
        if let token = tokensByFont[identity] {
            return token
        }
        guard tokensByFont.count < maxFonts else {
            return nil
        }
        let token = nextToken
        nextToken &+= 1
        precondition(nextToken != 0, "atlas font token exhausted")
        tokensByFont[identity] = token
        return token
    }

    func removeAll() {
        tokensByFont.removeAll(keepingCapacity: true)
    }
}

/// Bounded negative cache for glyphs that have stable zero ink bounds.
final class PermanentEmptyGlyphCache {
    let maxEntries: Int
    private var values: Set<GlyphKey> = []
    private(set) var evictionCount = 0
    private(set) var highWaterCount = 0

    init(maxEntries: Int = 4_096) {
        precondition(maxEntries > 0)
        self.maxEntries = maxEntries
        values.reserveCapacity(min(maxEntries, 1_024))
    }

    var count: Int { values.count }

    func contains(_ key: GlyphKey) -> Bool {
        values.contains(key)
    }

    func insert(_ key: GlyphKey) {
        if values.contains(key) {
            return
        }
        if values.count >= maxEntries {
            values.removeAll(keepingCapacity: true)
            evictionCount += 1
        }
        values.insert(key)
        highWaterCount = max(highWaterCount, values.count)
    }

    func removeAll() {
        guard !values.isEmpty else { return }
        values.removeAll(keepingCapacity: true)
        evictionCount += 1
    }
}

private struct RetainedFontIdentity: Hashable {
    let font: CTFont
    private let identifier: ObjectIdentifier

    init(_ font: CTFont) {
        self.font = font
        identifier = ObjectIdentifier(font)
    }

    static func == (lhs: RetainedFontIdentity, rhs: RetainedFontIdentity) -> Bool {
        lhs.identifier == rhs.identifier
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

private struct ScaledFontKey: Hashable {
    let sourceFont: RetainedFontIdentity
    let scale: CGFloat
}

struct GlyphEntry {
    let region: AtlasRegion
    let size: CGSize
    let bearing: CGPoint
    let isColor: Bool
    let atlasKind: GlyphAtlasKind
}

struct ResolvedGlyph {
    let entry: GlyphEntry
    /// Present only when the drawable miss already required metrics.
    let metricsFromMiss: GlyphMetrics?

    func fitMetrics(columnWidth: Int, required: Bool = false,
                    lookup: () -> GlyphMetrics) -> GlyphFitMetricsResolution {
        // Placement policies (host glyph fallback) need metrics for
        // single-column glyphs too; `required` bypasses the width early-out.
        guard columnWidth >= 2 || required else {
            return GlyphFitMetricsResolution(metrics: nil, origin: .notNeeded)
        }
        if let metricsFromMiss {
            return GlyphFitMetricsResolution(metrics: metricsFromMiss,
                                             origin: .drawableMiss)
        }
        return GlyphFitMetricsResolution(metrics: lookup(), origin: .metricsCache)
    }
}

enum GlyphFitMetricsOrigin: Equatable {
    case notNeeded
    case drawableMiss
    case metricsCache
}

struct GlyphFitMetricsResolution {
    let metrics: GlyphMetrics?
    let origin: GlyphFitMetricsOrigin
}

enum GlyphBitmapCacheLookup {
    case drawable(GlyphEntry)
    case permanentEmpty
    case miss
}

/// Keeps bitmap and permanent-empty results behind the same raster key.
final class GlyphBitmapResultCache {
    private var drawables: [GlyphKey: GlyphEntry] = [:]
    private let permanentEmpty: PermanentEmptyGlyphCache

    init(maximumEmptyEntries: Int = 4_096) {
        permanentEmpty = PermanentEmptyGlyphCache(maxEntries: maximumEmptyEntries)
    }

    var emptyEvictionCount: Int { permanentEmpty.evictionCount }
    var emptyHighWaterCount: Int { permanentEmpty.highWaterCount }

    func lookup(_ key: GlyphKey) -> GlyphBitmapCacheLookup {
        if let entry = drawables[key] {
            return .drawable(entry)
        }
        if permanentEmpty.contains(key) {
            return .permanentEmpty
        }
        return .miss
    }

    func storeDrawable(_ entry: GlyphEntry, for key: GlyphKey) {
        drawables[key] = entry
    }

    func storePermanentEmpty(_ key: GlyphKey) {
        permanentEmpty.insert(key)
    }

    func removeDrawables() {
        drawables.removeAll(keepingCapacity: true)
    }

    func removeAll() {
        removeDrawables()
        permanentEmpty.removeAll()
    }
}

enum GlyphAtlasKind {
    case grayscale
    case color
}

struct GlyphVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
    var color: SIMD4<Float>
}

struct ColorVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

struct TextCell {
    var position: SIMD2<Float>
    var size: SIMD2<Float>
    var texOrigin: SIMD2<Float>
    var texSize: SIMD2<Float>
    var color: SIMD4<Float>
}

struct ColorCell {
    var position: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
}

struct ImageDraw {
    let texture: MTLTexture
    let vertices: [GlyphVertex]
}

struct ImageDrawBuffer {
    let texture: MTLTexture
    let buffer: MTLBuffer
    let vertexCount: Int
}

struct RowDrawData {
    var backgroundCells: [ColorCell]
    var powerlineJoinCells: [ColorCell]
    var glyphCellsGray: [TextCell]
    var glyphCellsColor: [TextCell]
    var decorationCells: [ColorCell]
    var belowBackgroundImageDraws: [ImageDraw]
    var underImageDraws: [ImageDraw]
    var placeholderImageDraws: [ImageDraw]
    var overImageDraws: [ImageDraw]
    var otherImageDraws: [ImageDraw]
}

struct RowDrawBuffers {
    var backgroundBuffer: MTLBuffer?
    var backgroundCount: Int
    var powerlineJoinBuffer: MTLBuffer?
    var powerlineJoinCount: Int
    var glyphGrayBuffer: MTLBuffer?
    var glyphGrayCount: Int
    var glyphColorBuffer: MTLBuffer?
    var glyphColorCount: Int
    var decorationBuffer: MTLBuffer?
    var decorationCount: Int
    var belowBackgroundImageBuffers: [ImageDrawBuffer]
    var underImageBuffers: [ImageDrawBuffer]
    var placeholderImageBuffers: [ImageDrawBuffer]
    var overImageBuffers: [ImageDrawBuffer]
    var otherImageBuffers: [ImageDrawBuffer]
}

struct RowCacheEntry {
    var sourceIdentity: ObjectIdentifier
    // Both are needed: snapshot Row.revision counters are per-Row-object, and
    // the snapshot's row pool can put a different Row (with an independently
    // colliding revision) at this screen index across refreshes. The source
    // generation pins the content; the revision pins style/bidi/image state.
    var sourceGeneration: UInt64
    var revision: UInt64
    var data: RowDrawData?
    var buffers: RowDrawBuffers?
}

struct FrameDrawData {
    var backgroundCells: [ColorCell]
    var powerlineJoinCells: [ColorCell]
    var glyphCellsGray: [TextCell]
    var glyphCellsColor: [TextCell]
    var decorationCells: [ColorCell]
    var belowBackgroundImageDraws: [ImageDraw]
    var underImageDraws: [ImageDraw]
    var placeholderImageDraws: [ImageDraw]
    var overImageDraws: [ImageDraw]
    var otherImageDraws: [ImageDraw]
}

struct DrawData {
    var rows: [RowDrawBuffers]
    var frame: FrameDrawData?
    var cursorColorVertices: [ColorVertex]
    var cursorGlyphVerticesGray: [GlyphVertex]
    var cursorGlyphVerticesColor: [GlyphVertex]
}

struct KittyImageSignature: Hashable {
    let kind: UInt8
    let width: Int
    let height: Int
    let byteCount: Int
    let headHash: UInt32
}

struct ClipRect {
    let minX: Float
    let minY: Float
    let maxX: Float
    let maxY: Float
}

struct CustomGlyphKey: Hashable {
    let codePoint: UInt32
    let cellWidthPx: Int
    let cellHeightPx: Int
    let baseThicknessPx: Int
    let scale: Int
    let antiAlias: Bool
}

struct CustomGlyphEntry {
    let region: AtlasRegion
    let size: CGSize
}

struct CustomGlyphBitmap {
    let width: Int
    let height: Int
    let pixels: [UInt8]
}

struct KittyCacheStamp: Hashable {
    let imagesCount: Int
    let placementsCount: Int
    let generation: UInt64
}

struct CacheSignature: Hashable {
    let scale: Double
    let cellWidth: Double
    let cellHeight: Double
    let viewWidth: Double
    let viewHeight: Double
    let yDisp: Int
    let rows: Int
    let cols: Int
    let fontName: String
    let fontSize: Double
    let isAltBuffer: Bool
    let kittyStamp: KittyCacheStamp
    let bidiHostPolicy: BidiHostPolicy
    let attributeContextIdentity: UInt64
    let glyphFallbackIdentity: UInt64
}

struct MetalProfileCounters {
    var metricsCacheLookups = 0
    var metricsCacheHits = 0
    var metricsCacheMisses = 0
    var glyphAtlasLookups = 0
    var glyphAtlasHits = 0
    var glyphAtlasMisses = 0
    var permanentEmptyHits = 0
    var fullGlyphCacheMisses = 0
    var rasterizations = 0
    var bitmapRasterizationResults = 0
    var emptyRasterizationResults = 0
    var transientRasterizationFailures = 0
    var glyphBoundsQueries = 0
    var glyphDrawCalls = 0
    var negativeCacheEvictions = 0
    var negativeCacheHighWater = 0
    var rasterFontRegistryLookups = 0
    var rasterFontRegistryHits = 0
    var rasterFontRegistryMisses = 0
    var rasterFontRegistryHighWater = 0
    var rasterFontRegistryTeardowns = 0
    var drawableHitsAvoidedMetricsLookup = 0
    var drawableHitsRequiredMetricsLookup = 0
    var metricsReusedFromDrawableMiss = 0
    var metricsFontRegistryHighWater = 0
    var fullIdentityTokensAliasingRasterIdentity = 0
    var fullCacheKeysAliasingRasterGlyphKey = 0
    var grayscaleAtlasGrows = 0
    var colorAtlasGrows = 0
    var grayscaleAtlasResets = 0
    var colorAtlasResets = 0
    var metricsEntryLimitResets = 0
    var metricsFontLimitResets = 0
    var rowsRebuilt = 0
    var atlasInvalidationBuildAttempts = 0

    mutating func add(_ other: MetalProfileCounters) {
        metricsCacheLookups += other.metricsCacheLookups
        metricsCacheHits += other.metricsCacheHits
        metricsCacheMisses += other.metricsCacheMisses
        glyphAtlasLookups += other.glyphAtlasLookups
        glyphAtlasHits += other.glyphAtlasHits
        glyphAtlasMisses += other.glyphAtlasMisses
        permanentEmptyHits += other.permanentEmptyHits
        fullGlyphCacheMisses += other.fullGlyphCacheMisses
        rasterizations += other.rasterizations
        bitmapRasterizationResults += other.bitmapRasterizationResults
        emptyRasterizationResults += other.emptyRasterizationResults
        transientRasterizationFailures += other.transientRasterizationFailures
        glyphBoundsQueries += other.glyphBoundsQueries
        glyphDrawCalls += other.glyphDrawCalls
        negativeCacheEvictions += other.negativeCacheEvictions
        negativeCacheHighWater = max(negativeCacheHighWater, other.negativeCacheHighWater)
        rasterFontRegistryLookups += other.rasterFontRegistryLookups
        rasterFontRegistryHits += other.rasterFontRegistryHits
        rasterFontRegistryMisses += other.rasterFontRegistryMisses
        rasterFontRegistryHighWater = max(rasterFontRegistryHighWater,
                                          other.rasterFontRegistryHighWater)
        rasterFontRegistryTeardowns += other.rasterFontRegistryTeardowns
        drawableHitsAvoidedMetricsLookup += other.drawableHitsAvoidedMetricsLookup
        drawableHitsRequiredMetricsLookup += other.drawableHitsRequiredMetricsLookup
        metricsReusedFromDrawableMiss += other.metricsReusedFromDrawableMiss
        metricsFontRegistryHighWater = max(metricsFontRegistryHighWater,
                                           other.metricsFontRegistryHighWater)
        fullIdentityTokensAliasingRasterIdentity +=
            other.fullIdentityTokensAliasingRasterIdentity
        fullCacheKeysAliasingRasterGlyphKey += other.fullCacheKeysAliasingRasterGlyphKey
        grayscaleAtlasGrows += other.grayscaleAtlasGrows
        colorAtlasGrows += other.colorAtlasGrows
        grayscaleAtlasResets += other.grayscaleAtlasResets
        colorAtlasResets += other.colorAtlasResets
        metricsEntryLimitResets += other.metricsEntryLimitResets
        metricsFontLimitResets += other.metricsFontLimitResets
        rowsRebuilt += other.rowsRebuilt
        atlasInvalidationBuildAttempts += other.atlasInvalidationBuildAttempts
    }
}

/// A font interned for raw glyph-metrics lookup.
///
/// The token is monotonic for the renderer lifetime. The cache can discard a
/// generation, but it never gives that generation's tokens to later fonts.
struct GlyphMetricsFont {
    fileprivate(set) var token: UInt32
    let font: CTFont
    let fittingFont: CTFont
    let renderingScale: CGFloat
    fileprivate(set) var generation: UInt64
}

private struct RegisteredMetricsFont {
    let font: CTFont
    let fittingFont: CTFont
    let renderingScale: CGFloat
}

private struct MetricsFontIdentity: Hashable {
    let rasterFont: CoreTextFontIdentity
    let fittingFont: CoreTextFontIdentity
    let renderingScale: CGFloat
}

private struct GlyphMetricsCacheKey: Hashable {
    let fontToken: UInt32
    let glyph: CGGlyph
}

fileprivate enum GlyphMetricsDiscardReason {
    case entryLimit
    case fontLimit
}

struct GlyphMetricsLookup {
    let metrics: GlyphMetrics
    let wasHit: Bool
}

/// Renderer-local cache shared by rasterization and slot fitting.
///
/// The render thread is the only caller. A clear-all eviction bounds both the
/// metrics and retained-font registries without adding LRU work to a lookup.
final class GlyphMetricsCache {
    let maxEntries: Int
    let maxFonts: Int

    private var values: [GlyphMetricsCacheKey: GlyphMetrics] = [:]
    private var tokensByFont: [MetricsFontIdentity: UInt32] = [:]
    private var fontsByToken: [UInt32: RegisteredMetricsFont] = [:]
    private var nextToken: UInt32 = 1
    private(set) var generation: UInt64 = 1
    private(set) var fontRegistryHighWater = 0
    fileprivate var lastDiscardReason: GlyphMetricsDiscardReason?

#if DEBUG
    private(set) var hitCount = 0
    private(set) var missCount = 0
#endif

    // The unicode/symbols benchmark shapes to about 46,000 distinct keys.
    // A 65,536-entry bound keeps one full pass warm.
    // At Swift Dictionary's target load, the 8-byte key and 56-byte value use
    // about 5.4 MiB at the entry limit. Control storage and the 1,024 retained
    // font references keep the incremental total below 8 MiB.
    init(maxEntries: Int = 65_536, maxFonts: Int = 1_024) {
        precondition(maxEntries > 0 && maxFonts > 0)
        self.maxEntries = maxEntries
        self.maxFonts = maxFonts
        // Do not pay the full bound when a terminal uses only a small glyph set.
        // The dictionary grows during cold misses and does not allocate on warm hits.
        values.reserveCapacity(min(maxEntries, 4_096))
        tokensByFont.reserveCapacity(min(maxFonts, 64))
        fontsByToken.reserveCapacity(min(maxFonts, 64))
    }

    var count: Int { values.count }
    var fontRegistryCount: Int { fontsByToken.count }

    /// Interns one complete metrics context. Core Text equality coalesces
    /// equivalent fonts and keeps different raster or fitting configurations
    /// distinct without a large key for each glyph.
    func intern(font: CTFont, fittingFont: CTFont? = nil,
                renderingScale: CGFloat = 1) -> GlyphMetricsFont {
        let fittingFont = fittingFont ?? font
        let identity = MetricsFontIdentity(rasterFont: CoreTextFontIdentity(font),
                                           fittingFont: CoreTextFontIdentity(fittingFont),
                                           renderingScale: renderingScale)
        if let token = tokensByFont[identity] {
            let registered = fontsByToken[token]!
            return GlyphMetricsFont(token: token, font: registered.font,
                                    fittingFont: registered.fittingFont,
                                    renderingScale: registered.renderingScale,
                                    generation: generation)
        }
        if fontsByToken.count >= maxFonts {
            discardGeneration(reason: .fontLimit)
        }
        let token = nextToken
        nextToken &+= 1
        precondition(nextToken != 0, "glyph metrics font token exhausted")
        tokensByFont[identity] = token
        fontsByToken[token] = RegisteredMetricsFont(font: font,
                                                    fittingFont: fittingFont,
                                                    renderingScale: renderingScale)
        fontRegistryHighWater = max(fontRegistryHighWater, fontsByToken.count)
        return GlyphMetricsFont(token: token, font: font,
                                fittingFont: fittingFont,
                                renderingScale: renderingScale,
                                generation: generation)
    }

    /// Returns raw metrics and updates a stale run token after cache eviction.
    func metrics(font: inout GlyphMetricsFont, glyph: CGGlyph) -> GlyphMetricsLookup {
        if font.generation != generation {
            font = intern(font: font.font, fittingFont: font.fittingFont,
                          renderingScale: font.renderingScale)
        }
        var key = GlyphMetricsCacheKey(fontToken: font.token, glyph: glyph)
        if let cached = values[key] {
#if DEBUG
            hitCount += 1
#endif
            return GlyphMetricsLookup(metrics: cached, wasHit: true)
        }

#if DEBUG
        missCount += 1
#endif
        let result = GlyphMetrics.measure(font: font.font, glyph: glyph,
                                          fittingFont: font.fittingFont,
                                          renderingScale: font.renderingScale)

        if values.count >= maxEntries {
            discardGeneration(reason: .entryLimit)
            font = intern(font: font.font, fittingFont: font.fittingFont,
                          renderingScale: font.renderingScale)
            key = GlyphMetricsCacheKey(fontToken: font.token, glyph: glyph)
        }
        values[key] = result
        return GlyphMetricsLookup(metrics: result, wasHit: false)
    }

    private func discardGeneration(reason: GlyphMetricsDiscardReason) {
        values.removeAll(keepingCapacity: true)
        tokensByFont.removeAll(keepingCapacity: true)
        fontsByToken.removeAll(keepingCapacity: true)
        generation &+= 1
        precondition(generation != 0, "glyph metrics generation exhausted")
        lastDiscardReason = reason
    }
}

/// Cross-thread redraw and cursor-blink state for one renderer.
///
/// Completion handlers and the main-actor blink timer capture this checked
/// owner instead of capturing the non-Sendable renderer.
final class MetalRedrawState: Sendable {
    typealias RedrawCallback = @Sendable () -> Void

    private struct State: Sendable {
        var active = true
        var pendingRedraw = false
        var cursorBlinkOn = true
        var cursorBlinkWanted = false
        var callbackConfigured = false
        var callback: RedrawCallback?
    }

    private let state = Locked(State())

    func configure(callback: @escaping RedrawCallback) {
        state.withLock { state in
            precondition(!state.callbackConfigured,
                         "Metal redraw callback configured twice")
            state.callbackConfigured = true
            state.callback = callback
        }
    }

    /// Coalesces render-thread requests before the host's generation check.
    /// A blocked main thread can retain only one pending delivery, not one
    /// Task for every transient row failure or refused frame permit.
    func configureOnMain(callback: @escaping @MainActor @Sendable () -> Void) {
        let queued = Locked(false)
        configure { [weak self] in
            let enqueue = queued.withLock {
                guard !$0 else { return false }
                $0 = true
                return true
            }
            guard enqueue else { return }
            Task { @MainActor [weak self] in
                queued.withLock { $0 = false }
                guard self?.state.withLock({ $0.active }) == true else { return }
                callback()
            }
        }
    }

    var callback: RedrawCallback? {
        state.withLock { $0.callback }
    }

    func requestRedraw() {
        let callback = state.withLock { $0.callback }
        callback?()
    }

    func invalidate() {
        state.withLock {
            $0.active = false
            $0.callback = nil
            $0.pendingRedraw = false
            $0.cursorBlinkWanted = false
        }
    }

    func markPendingRedraw() {
        state.withLock { if $0.active { $0.pendingRedraw = true } }
    }

    func consumePendingRedraw() -> Bool {
        state.withLock { state in
            let pending = state.pendingRedraw
            state.pendingRedraw = false
            return pending
        }
    }

    var cursorBlinkOn: Bool {
        state.withLock { $0.cursorBlinkOn }
    }

    var cursorBlinkWanted: Bool {
        state.withLock { $0.cursorBlinkWanted }
    }

    /// Returns true when the main-actor timer must change.
    func setCursorBlinkWanted(_ wanted: Bool) -> Bool {
        state.withLock { state in
            guard state.active else { return false }
            let changed = state.cursorBlinkWanted != wanted
            state.cursorBlinkWanted = wanted
            if changed && !wanted {
                state.cursorBlinkOn = true
            }
            return changed
        }
    }

    func resetCursorBlink() {
        state.withLock { $0.cursorBlinkOn = true }
    }

    func toggleCursorBlink() {
        state.withLock { $0.cursorBlinkOn.toggle() }
    }
}

private final class MetalCursorBlinkLifetime: Sendable {
    private let active = Locked(true)

    func stop() {
        active.withLock { $0 = false }
    }

    var isActive: Bool {
        active.withLock { $0 }
    }
}

/// Owns the run-loop timer. All Timer access stays on the main actor.
@MainActor
final class MetalCursorBlinkController {
    private let redrawState: MetalRedrawState
    private let interval: TimeInterval
    private let lifetime = MetalCursorBlinkLifetime()
    private var timer: Timer?

    init(redrawState: MetalRedrawState, interval: TimeInterval = 0.7) {
        precondition(interval > 0)
        self.redrawState = redrawState
        self.interval = interval
    }

    deinit {
        // Timer's run loop can retain it until the next firing. The callback
        // sees this flag, invalidates itself, and performs no redraw work.
        lifetime.stop()
    }

    var isRunning: Bool { timer != nil }

    func apply(shouldBlink: Bool) {
        // Several changes can queue before main drains them. Apply only the
        // latest value published by the render thread.
        guard redrawState.cursorBlinkWanted == shouldBlink else { return }

        if shouldBlink {
            guard timer == nil else { return }
            redrawState.resetCursorBlink()
            let redrawState = redrawState
            let lifetime = lifetime
            timer = Timer.scheduledTimer(withTimeInterval: interval,
                                         repeats: true) { timer in
                guard lifetime.isActive else {
                    timer.invalidate()
                    return
                }
                redrawState.toggleCursorBlink()
                redrawState.requestRedraw()
            }
        } else {
            shutdown()
        }
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        redrawState.resetCursorBlink()
    }
}

final class MetalTerminalRenderer {
#if canImport(os)
    private static let profileLog = OSLog(subsystem: "org.tirania.SwiftTerm", category: "MetalProfile")
    private static let profileEnabled = ProcessInfo.processInfo.environment["SWIFTTERM_PROFILE"] == "1"
#endif
    private let renderSurface: (any MetalRenderSurface)?
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textPipeline: MTLRenderPipelineState
    private let textGrayPipeline: MTLRenderPipelineState
    private let colorPipeline: MTLRenderPipelineState
    private let cellTextPipeline: MTLRenderPipelineState
    private let cellTextGrayPipeline: MTLRenderPipelineState
    private let cellColorPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let textureLoader: MTKTextureLoader
    private let bufferPool: BufferPool
    private let shaperCache = ShaperCache(maxEntries: 2048)
    private let grayscaleAtlas: GlyphAtlas
    private let colorAtlas: GlyphAtlas
    private let rasterizer = CoreTextGlyphRasterizer()
    private let glyphBitmapResultCache = GlyphBitmapResultCache()
    private let rasterFontRegistry = RasterFontRegistry()
    private let glyphMetricsCache = GlyphMetricsCache()
    private let colorSIMDCache = MetalColorSIMDCache()
    // Profiling-only identity comparison. These maps stay empty when
    // SWIFTTERM_PROFILE_STATS is off and stop accepting new values at their
    // fixed bounds.
    private var profileFullFontTokens: [ProfileFullFontIdentity: UInt32] = [:]
    private var profileFirstFullFontByRaster: [UInt32: UInt32] = [:]
    private var profileFullGlyphKeys: Set<ProfileFullGlyphKey> = []
    private var profileFirstFullGlyphByRaster: [GlyphKey: ProfileFullGlyphKey] = [:]
    private var nextProfileFullFontToken: UInt32 = 1
    private var metricsCacheGeneration: UInt64 = 1
    private var scaledFontCache: [ScaledFontKey: CTFont] = [:]
    private var customGlyphCache: [CustomGlyphKey: CustomGlyphEntry] = [:]
    private let imageTextureCache = NSMapTable<AnyObject, MTLTexture>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var kittyTextureCache: [UInt32: (signature: KittyImageSignature, texture: MTLTexture)] = [:]
    private var rowCache: [Int: RowCacheEntry] = [:]
    private var cacheBufferingMode: MetalBufferingMode?
    private var cacheSignature: CacheSignature?
    private var atlasInvalidatedDuringBuild = false
    private let redrawState: MetalRedrawState
    private let cursorBlinkController: MetalCursorBlinkController
    private let frameSemaphore = DispatchSemaphore(value: 1)
    private let frameBudget: MetalFrameBudget
    let health: MetalRendererHealth
#if DEBUG
    var completionGate: MetalCompletionGate?
    var creationFailure: MetalError?
#endif
    private let redrawLock = NSLock()
    private var activeProfileCounters = MetalProfileCounters()
    private var totalProfileCounters = MetalProfileCounters()
    private var profileResetGeneration: UInt64 = 0
    private var preparedSnapshot: (snapshot: TerminalSnapshot,
                                   context: SnapshotRenderContext)?

    /// Testing hook: block until the GPU finishes, so the drawable texture can
    /// be read back. Never set in production; a synchronous wait on the render
    /// path is exactly what this work is trying to remove.
    var waitForCompletionAfterCommit = false

    /// Frames actually submitted to the GPU.
    ///
    /// Distinct from the frame driver's tick count on purpose: a driver that
    /// ticks without drawing looks identical in the tick counter, which is how
    /// a spin loop once reported *better* numbers than the working path while
    /// the window sat frozen.
    /// Guarded by `redrawLock`: written on the render loop, read from main.
    private var completedRenderCount = 0

    var completedRenders: Int {
        get {
            redrawLock.lock()
            defer { redrawLock.unlock() }
            return completedRenderCount
        }
    }

    var profileCounters: MetalProfileCounters {
        redrawLock.lock()
        defer { redrawLock.unlock() }
        return totalProfileCounters
    }

    func resetRenderCounter() {
        redrawLock.lock()
        completedRenderCount = 0
        totalProfileCounters = MetalProfileCounters()
        profileResetGeneration &+= 1
        redrawLock.unlock()
    }

    private func beginProfileBuild() -> UInt64? {
        guard ProfilingStats.enabled else { return nil }
        activeProfileCounters = MetalProfileCounters()
        redrawLock.lock()
        let generation = profileResetGeneration
        redrawLock.unlock()
        return generation
    }

    private func commitProfileBuild(generation: UInt64?) {
        guard let generation else { return }
        redrawLock.lock()
        if generation == profileResetGeneration {
            totalProfileCounters.add(activeProfileCounters)
        }
        redrawLock.unlock()
    }

    /// Testing hook: retains the texture this renderer actually drew into.
    ///
    /// Necessary because asking the surface for a drawable a second time
    /// returns a *different* one from the pool, not the frame just rendered —
    /// comparing that instead silently compares uninitialised memory.
    var capturesRenderedTexture = false
    private(set) var lastRenderedTexture: MTLTexture?

    /// Asks the host to schedule a frame. A callback rather than a reference to
    /// the view's frame driver, so the renderer needs no view access
    /// (io-gaps.md G1, WO-F1c).
    var requestRedraw: MetalRedrawState.RedrawCallback? {
        get { redrawState.callback }
        set {
            guard let newValue else { return }
            redrawState.configure(callback: newValue)
        }
    }

    func configureRedrawOnMain(_ callback: @escaping @MainActor @Sendable () -> Void) {
        redrawState.configureOnMain(callback: callback)
    }

    /// The renderer's own text builder. Owning it, rather than calling into
    /// the view, is what frees this path from the main thread (io-gaps.md G1).
    /// It also means this cache is never shared with the Core Graphics path.
    private let textBuilder = SnapshotTextBuilder()
#if DEBUG
    private var debugFrameCount = 0
    private var debugLastLogTime = CFAbsoluteTimeGetCurrent()
    private var debugRowsRebuilt = 0
    private var debugRowsCached = 0

    var debugRowCacheCounts: (rebuilt: Int, cached: Int) {
        (debugRowsRebuilt, debugRowsCached)
    }
#endif
#if DEBUG
    private var imageTextureFailures: Set<ObjectIdentifier> = []
    private var kittyTextureFailures: Set<UInt32> = []
#endif

    @MainActor
    init(target: any MetalRenderTarget, frameBudget: MetalFrameBudget = MetalFrameBudget()) throws {
        guard let device = target.renderDevice ?? MTLCreateSystemDefaultDevice() else {
            throw MetalError.deviceUnavailable
        }
        let redrawState = MetalRedrawState()
        self.redrawState = redrawState
        self.frameBudget = frameBudget
        health = MetalRendererHealth(redrawState: redrawState)
        health.configure(failure: nil, presentation: { TerminalView.onFramePresented?() })
        cursorBlinkController = MetalCursorBlinkController(redrawState: redrawState)
        self.device = device
        target.renderDevice = device
        renderSurface = target.detachedRenderSurface
        self.textureLoader = MTKTextureLoader(device: device)
        self.bufferPool = BufferPool(device: device)
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalError.commandQueueUnavailable
        }
        self.commandQueue = commandQueue
        guard let grayscaleAtlas = GlyphAtlas(device: device,
                                              maxSize: GlyphAtlas.recommendedMaxSize(device: device, format: .grayscale),
                                              format: .grayscale),
              let colorAtlas = GlyphAtlas(device: device,
                                          maxSize: GlyphAtlas.recommendedMaxSize(device: device, format: .bgra),
                                          format: .bgra) else {
            throw MetalError.atlasUnavailable
        }
        self.grayscaleAtlas = grayscaleAtlas
        self.colorAtlas = colorAtlas
        let library = try MetalTerminalRenderer.makeLibrary(device: device)
        let pixelFormat = target.renderPixelFormat
        guard let textPipeline = MetalTerminalRenderer.makeTextPipeline(device: device,
                                                                        library: library,
                                                                        pixelFormat: pixelFormat,
                                                                        vertexName: "terminal_text_vertex",
                                                                        fragmentName: "terminal_text_fragment"),
              let textGrayPipeline = MetalTerminalRenderer.makeTextPipeline(device: device,
                                                                            library: library,
                                                                            pixelFormat: pixelFormat,
                                                                            vertexName: "terminal_text_vertex",
                                                                            fragmentName: "terminal_text_fragment_gray"),
              let cellTextPipeline = MetalTerminalRenderer.makeTextPipeline(device: device,
                                                                            library: library,
                                                                            pixelFormat: pixelFormat,
                                                                            vertexName: "terminal_cell_text_vertex",
                                                                            fragmentName: "terminal_text_fragment"),
              let cellTextGrayPipeline = MetalTerminalRenderer.makeTextPipeline(device: device,
                                                                                library: library,
                                                                                pixelFormat: pixelFormat,
                                                                                vertexName: "terminal_cell_text_vertex",
                                                                                fragmentName: "terminal_text_fragment_gray"),
              let colorPipeline = MetalTerminalRenderer.makeColorPipeline(device: device,
                                                                          library: library,
                                                                          pixelFormat: pixelFormat,
                                                                          vertexName: "terminal_color_vertex",
                                                                          fragmentName: "terminal_color_fragment"),
              let cellColorPipeline = MetalTerminalRenderer.makeColorPipeline(device: device,
                                                                              library: library,
                                                                              pixelFormat: pixelFormat,
                                                                              vertexName: "terminal_cell_color_vertex",
                                                                              fragmentName: "terminal_color_fragment") else {
            throw MetalError.pipelineCreationFailed("text/color/cell")
        }
        self.textPipeline = textPipeline
        self.textGrayPipeline = textGrayPipeline
        self.colorPipeline = colorPipeline
        self.cellTextPipeline = cellTextPipeline
        self.cellTextGrayPipeline = cellTextGrayPipeline
        self.cellColorPipeline = cellColorPipeline
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
            throw MetalError.samplerUnavailable
        }
        self.sampler = sampler
#if DEBUG
        // This fault models a command buffer that does not release the frame
        // permit. Every draw then uses the real semaphore refusal path.
        if ProcessInfo.processInfo.environment["SWIFTTERM_TEST_METAL_FRAME_PERMIT_HELD"] == "1" {
            _ = frameSemaphore.wait(timeout: .now())
            // A real command buffer retains this semaphore in its completion
            // handler. Keep the same lifetime when this fault is active.
            _ = Unmanaged.passRetained(frameSemaphore)
        }
#endif
    }

    func prepareSnapshotForImmediateDraw(snapshot: TerminalSnapshot,
                                         context: SnapshotRenderContext) {
        preparedSnapshot = (snapshot, context)
    }

    var hasPreparedSnapshot: Bool {
        preparedSnapshot != nil
    }

    func discardPreparedSnapshot() {
        preparedSnapshot = nil
    }

    /// Renders one frame into the current target.
    ///
    /// A main-actor MTKView adapter supplies `frame`. The detached layer path
    /// acquires one from `renderSurface`. In both cases snapshot preparation,
    /// including terminal-lock work, finishes before drawable acquisition.
    func render(frame suppliedFrame: MetalDrawableFrame? = nil) {
        guard health.canRender else { return }
        // Same event as the Core Graphics draw: only one renderer is active at
        // a time, and the report names which. Needed to compare the two paths
        // and to grade io-gaps.md G1.
        let drawInterval = Profiling.begin(.frameDraw)
        defer { drawInterval.end() }

#if canImport(os)
        let drawID = OSSignpostID(log: MetalTerminalRenderer.profileLog)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.begin, log: MetalTerminalRenderer.profileLog, name: "Metal.Draw", signpostID: drawID)
        }
        defer {
            if MetalTerminalRenderer.profileEnabled {
                os_signpost(.end, log: MetalTerminalRenderer.profileLog, name: "Metal.Draw", signpostID: drawID)
            }
        }
#endif
        if frameSemaphore.wait(timeout: .now()) != .success {
            markPendingRedraw()
            return
        }
        guard let refreshed = preparedSnapshot else {
            frameSemaphore.signal()
            return
        }
        preparedSnapshot = nil
        let snapshot = refreshed.snapshot
        let renderContext = refreshed.context
#if os(macOS)
        rasterizer.fontSmoothing = renderContext.fontSmoothing
        let scale = renderContext.renderingScale
#else
        let scale = renderContext.renderingScale
#endif
#if canImport(os)
        let drawableID = OSSignpostID(log: MetalTerminalRenderer.profileLog)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.begin, log: MetalTerminalRenderer.profileLog, name: "Metal.CurrentDrawable", signpostID: drawableID)
        }
#endif
        let drawableInterval = Profiling.begin(.metalDrawable)
        let drawableFrame = suppliedFrame ?? renderSurface?.acquireDrawableFrame()
        drawableInterval.end()
#if canImport(os)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.end, log: MetalTerminalRenderer.profileLog, name: "Metal.CurrentDrawable", signpostID: drawableID)
        }
#endif

#if canImport(os)
        let passID = OSSignpostID(log: MetalTerminalRenderer.profileLog)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.begin, log: MetalTerminalRenderer.profileLog, name: "Metal.RenderPass", signpostID: passID)
        }
#endif
        let passDescriptor = drawableFrame?.renderPassDescriptor
#if canImport(os)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.end, log: MetalTerminalRenderer.profileLog, name: "Metal.RenderPass", signpostID: passID)
        }
#endif
        guard let drawableFrame, let passDescriptor else {
            markPendingRedraw()
            frameSemaphore.signal()
            return
        }
        let drawable = drawableFrame.drawable
        let drawableSize = drawableFrame.geometry.drawableSize
#if canImport(os)
        let buildID = OSSignpostID(log: MetalTerminalRenderer.profileLog)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.begin, log: MetalTerminalRenderer.profileLog, name: "Metal.BuildDrawData", signpostID: buildID)
        }
#endif
        let shouldBlink = isBlinkStyle(snapshot.cursorStyle)
            && snapshot.cursor?.hidden == false
            && renderContext.cursorHasFocus
        updateCursorBlinkTimer(shouldBlink: shouldBlink)
        let buildInterval = Profiling.begin(.metalBuildDrawData)
        let drawData = buildDrawData(snapshot: snapshot, context: renderContext)
        buildInterval.end()
#if canImport(os)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.end, log: MetalTerminalRenderer.profileLog, name: "Metal.BuildDrawData", signpostID: buildID)
        }
#endif
#if DEBUG
        debugFrameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - debugLastLogTime
        if elapsed >= 1.0 {
            let totalRows = debugRowsRebuilt + debugRowsCached
            let fps = Double(debugFrameCount) / elapsed
            print(String(format: "Metal FPS: %.1f (rows rebuilt: %d/%d)", fps, debugRowsRebuilt, totalRows))
            debugFrameCount = 0
            debugLastLogTime = now
        }
#endif
        let encodeInterval = Profiling.begin(.metalEncode)
        defer { encodeInterval.end() }
        let bgColor = colorToSIMD(renderContext.effectiveBackgroundColor)
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(Double(bgColor.x),
                                                                         Double(bgColor.y),
                                                                         Double(bgColor.z),
                                                                         Double(bgColor.w))
        passDescriptor.colorAttachments[0].loadAction = .clear

#if canImport(os)
        let encodeID = OSSignpostID(log: MetalTerminalRenderer.profileLog)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.begin, log: MetalTerminalRenderer.profileLog, name: "Metal.Encode", signpostID: encodeID)
        }
#endif
        // Retained references are essential to asynchronous retirement. The
        // default makeCommandBuffer() retains every encoded resource until
        // GPU completion; never use makeCommandBufferWithUnretainedReferences.
        // The small completion capsule additionally owns the presented drawable.
        var submitted = false
        defer {
            if !submitted {
                frameSemaphore.signal()
#if canImport(os)
                if MetalTerminalRenderer.profileEnabled {
                    os_signpost(.end, log: MetalTerminalRenderer.profileLog, name: "Metal.Encode", signpostID: encodeID)
                }
#endif
            }
        }
#if DEBUG
        if let creationFailure {
            health.fail(creationFailure)
            return
        }
#endif
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            health.fail(.commandBufferUnavailable)
            return
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            health.fail(.renderEncoderUnavailable)
            return
        }
        guard frameBudget.acquire() else {
            encoder.endEncoding()
            health.fail(.inFlightLimitReached)
            return
        }
        let lifetime = MetalSubmittedFrame(drawable: drawable, permit: frameSemaphore,
                                           budget: frameBudget)
        let health = health
#if DEBUG
        let completionGate = completionGate
#endif
        commandBuffer.addCompletedHandler { command in
            let error: MetalError? = command.status == .error
                ? .commandFailed(command.error?.localizedDescription ?? "Unknown GPU error") : nil
#if DEBUG
            if let completionGate {
                completionGate.hold { injectedError in
                    health.completed(error: injectedError ?? error, frame: lifetime)
                }
                return
            }
#endif
            health.completed(error: error, frame: lifetime)
        }
        bufferPool.beginFrame()
        let viewport = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))

        if let frame = drawData.frame {
            drawFrameData(frame, encoder: encoder, viewport: viewport)
        } else {
            let rows = drawData.rows
            drawImageRows(rows: rows,
                          imageKey: \.belowBackgroundImageBuffers,
                          encoder: encoder,
                          viewport: viewport)

            drawVertexBuffers(rows: rows,
                              bufferKey: \.backgroundBuffer,
                              countKey: \.backgroundCount,
                              pipeline: cellColorPipeline,
                              texture: nil,
                              encoder: encoder,
                              viewport: viewport)

            drawImageRows(rows: rows,
                          imageKey: \.underImageBuffers,
                          encoder: encoder,
                          viewport: viewport)

            drawVertexBuffers(rows: rows,
                              bufferKey: \.powerlineJoinBuffer,
                              countKey: \.powerlineJoinCount,
                              pipeline: cellColorPipeline,
                              texture: nil,
                              encoder: encoder,
                              viewport: viewport)

            drawVertexBuffers(rows: rows,
                              bufferKey: \.glyphGrayBuffer,
                              countKey: \.glyphGrayCount,
                              pipeline: cellTextGrayPipeline,
                              texture: grayscaleAtlas.texture,
                              encoder: encoder,
                              viewport: viewport)

            drawVertexBuffers(rows: rows,
                              bufferKey: \.glyphColorBuffer,
                              countKey: \.glyphColorCount,
                              pipeline: cellTextPipeline,
                              texture: colorAtlas.texture,
                              encoder: encoder,
                              viewport: viewport)

            drawVertexBuffers(rows: rows,
                              bufferKey: \.decorationBuffer,
                              countKey: \.decorationCount,
                              pipeline: cellColorPipeline,
                              texture: nil,
                              encoder: encoder,
                              viewport: viewport)

            drawImageRows(rows: rows,
                          imageKey: \.placeholderImageBuffers,
                          encoder: encoder,
                          viewport: viewport)
            drawImageRows(rows: rows,
                          imageKey: \.overImageBuffers,
                          encoder: encoder,
                          viewport: viewport)
            drawImageRows(rows: rows,
                          imageKey: \.otherImageBuffers,
                          encoder: encoder,
                          viewport: viewport)
        }

        if !drawData.cursorColorVertices.isEmpty {
            if let buffer = makeBuffer(drawData.cursorColorVertices) {
                encoder.setRenderPipelineState(colorPipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                var viewportVar = viewport
                encoder.setVertexBytes(&viewportVar, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: drawData.cursorColorVertices.count)
            }
        }

        if !drawData.cursorGlyphVerticesGray.isEmpty {
            if let buffer = makeBuffer(drawData.cursorGlyphVerticesGray) {
                encoder.setRenderPipelineState(textGrayPipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                var viewportVar = viewport
                encoder.setVertexBytes(&viewportVar, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                encoder.setFragmentTexture(grayscaleAtlas.texture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: drawData.cursorGlyphVerticesGray.count)
            }
        }

        if !drawData.cursorGlyphVerticesColor.isEmpty {
            if let buffer = makeBuffer(drawData.cursorGlyphVerticesColor) {
                encoder.setRenderPipelineState(textPipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                var viewportVar = viewport
                encoder.setVertexBytes(&viewportVar, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                encoder.setFragmentTexture(colorAtlas.texture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: drawData.cursorGlyphVerticesColor.count)
            }
        }

        encoder.endEncoding()
#if canImport(os)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.end, log: MetalTerminalRenderer.profileLog, name: "Metal.Encode", signpostID: encodeID)
        }
        let commitID = OSSignpostID(log: MetalTerminalRenderer.profileLog)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.begin, log: MetalTerminalRenderer.profileLog, name: "Metal.Commit", signpostID: commitID)
        }
#endif
        redrawLock.lock()
        completedRenderCount += 1
        redrawLock.unlock()
        if capturesRenderedTexture {
            lastRenderedTexture = drawable.texture
        }
        commandBuffer.present(drawable)
        bufferPool.commit(commandBuffer: commandBuffer)
        health.submitted(commandBuffer)
        submitted = true
        commandBuffer.commit()
        if waitForCompletionAfterCommit {
            // Testing only: makes the drawable texture readable right after
            // render() returns, so a test can compare what two surfaces
            // actually produced.
            commandBuffer.waitUntilCompleted()
        }
#if canImport(os)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.end, log: MetalTerminalRenderer.profileLog, name: "Metal.Commit", signpostID: commitID)
        }
#endif
    }


    private func markPendingRedraw() {
        redrawState.markPendingRedraw()
    }

    /// Quiesce the CPU render executor before calling. Committed commands
    /// retain their resources and release only their own permit on completion;
    /// neither the renderer nor its surface needs to wait for the GPU.
    @MainActor
    func retire() {
        health.retire()
        cursorBlinkController.shutdown()
        preparedSnapshot = nil
    }

    /// Diagnostics/test synchronization only, never surface teardown.
    /// A successful wait returns the permit so future frames can continue.
    func waitForIdle(timeout: TimeInterval = 5) -> Bool {
        precondition(timeout >= 0)
        let result = frameSemaphore.wait(timeout: .now() + timeout)
        guard result == .success else { return false }
        frameSemaphore.signal()
        return true
    }

    /// Worst case before the working set is stable: a few grows
    /// (1024 -> ... -> maxSize) can invalidate passes, then one reset, and
    /// finally one frozen pass that is guaranteed not to invalidate.
    private static let maxAtlasRebuildPasses = 5

    private func buildDrawData(snapshot: TerminalSnapshot,
                               context: SnapshotRenderContext) -> DrawData {
        let profileGeneration = beginProfileBuild()
        defer {
            commitProfileBuild(generation: profileGeneration)
            grayscaleAtlas.frozen = false
            colorAtlas.frozen = false
        }
        var attempt = 0
        while true {
            if attempt == Self.maxAtlasRebuildPasses {
                // Final pass: no grow/reset allowed. Glyphs that do not fit
                // are skipped (rendered blank) instead of invalidating the
                // regions this pass has already referenced.
                GlyphAtlas.log.fault("glyph working set exceeds max atlas capacity; some glyphs will be skipped this frame")
                grayscaleAtlas.frozen = true
                colorAtlas.frozen = true
            }
            atlasInvalidatedDuringBuild = false
            let result = buildDrawDataPass(snapshot: snapshot, context: context)
            if !atlasInvalidatedDuringBuild || attempt >= Self.maxAtlasRebuildPasses {
                return result
            }
            // The invalidation site flushed the caches, but the row being
            // built when it struck mixes pre- and post-invalidation UVs and
            // was cached after the flush along with the rows that followed.
            // Drop them all so the retry pass rebuilds every row.
            rowCache.removeAll()
            attempt += 1
            if ProfilingStats.enabled {
                activeProfileCounters.atlasInvalidationBuildAttempts += 1
            }
            GlyphAtlas.log.info("glyph atlas changed during frame build; rebuild pass \(attempt)/\(Self.maxAtlasRebuildPasses)")
        }
    }

    private func buildDrawDataPass(snapshot: TerminalSnapshot,
                                   context: SnapshotRenderContext) -> DrawData {
        pruneKittyTextureCache(kitty: snapshot.kitty)
        let scale = context.renderingScale
        let cellWidth = context.cellDimension.width
        let cellHeight = context.cellDimension.height
        let yOffset = context.baselineOffset
        let viewWidthPx = context.viewBounds.width * scale

        let rowInfo = visibleRowRange(snapshot: snapshot)
        guard let (firstRow, lastRow, visibleDisp) = rowInfo else {
#if DEBUG
            debugRowsRebuilt = 0
            debugRowsCached = 0
#endif
            return DrawData(rows: [],
                            frame: nil,
                            cursorColorVertices: [],
                            cursorGlyphVerticesGray: [],
                            cursorGlyphVerticesColor: [])
        }
        let bufferingMode = context.metalBufferingMode
        if cacheBufferingMode != bufferingMode {
            if bufferingMode == .perFrameAggregated {
                for (key, var entry) in rowCache {
                    entry.buffers = nil
                    rowCache[key] = entry
                }
            }
            cacheBufferingMode = bufferingMode
        }
        let kittyStamp = KittyCacheStamp(
            imagesCount: snapshot.kitty.renderSnapshot.imagesById.count,
            placementsCount: snapshot.kitty.renderSnapshot.placements.count,
            generation: snapshot.kitty.renderSnapshot.storageGeneration)
        let signature = CacheSignature(scale: Double(scale),
                                       cellWidth: Double(cellWidth),
                                       cellHeight: Double(cellHeight),
                                       viewWidth: Double(context.viewBounds.width),
                                       viewHeight: Double(context.viewBounds.height),
                                       yDisp: visibleDisp,
                                       rows: snapshot.rowCount,
                                       cols: snapshot.cols,
                                       fontName: context.fonts.normal.fontName,
                                       fontSize: Double(context.fonts.normal.pointSize),
                                       isAltBuffer: snapshot.isAltBuffer,
                                       kittyStamp: kittyStamp,
                                       bidiHostPolicy: context.bidiHostPolicy,
                                       attributeContextIdentity: context.identity,
                                       glyphFallbackIdentity: context.glyphFallbackProvider?.cacheIdentity ?? 0)
        let signatureChanged = signature != cacheSignature
        if signatureChanged {
            if signature.glyphFallbackIdentity != cacheSignature?.glyphFallbackIdentity {
                // A replaced host fallback font can be CFEqual to its
                // predecessor (same PostScript name and size), which would
                // rebind the predecessor's raster token and serve its atlas
                // bitmaps. Tear the registry down, as rasterFontToken does,
                // so tokens are never rebound to another font.
                glyphBitmapResultCache.removeAll()
                rasterFontRegistry.removeAll()
                scaledFontCache.removeAll()
            }
            rowCache.removeAll()
            cacheSignature = signature
        }

        let visibleRange = firstRow...lastRow
        if !rowCache.isEmpty {
            rowCache = rowCache.filter { visibleRange.contains($0.key) }
        }

        let needsFullRebuild = signatureChanged || rowCache.isEmpty

        var rows: [RowDrawBuffers] = []
        var frameData: FrameDrawData?
        if bufferingMode == .perFrameAggregated {
            frameData = FrameDrawData(backgroundCells: [],
                                      powerlineJoinCells: [],
                                      glyphCellsGray: [],
                                      glyphCellsColor: [],
                                      decorationCells: [],
                                      belowBackgroundImageDraws: [],
                                      underImageDraws: [],
                                      placeholderImageDraws: [],
                                      overImageDraws: [],
                                      otherImageDraws: [])
        }

        var rebuiltRows = 0
        var cachedRows = 0
        for absoluteRow in visibleRange {
            guard let snapshotRow = snapshot.row(atAbsolute: absoluteRow) else {
                continue
            }
            let sourceIdentity = snapshotRow.sourceIdentity!
            var entry = rowCache[absoluteRow]
            let cacheValid = entry?.sourceIdentity == sourceIdentity &&
                entry?.sourceGeneration == snapshotRow.sourceGeneration &&
                entry?.revision == snapshotRow.revision
            let needsRebuild = needsFullRebuild ||
                !cacheValid ||
                (bufferingMode == .perFrameAggregated && entry?.data == nil)
            let rowBuffers: RowDrawBuffers?
            let rowData: RowDrawData
            if needsRebuild {
                let rowInterval = Profiling.begin(.metalRowBuild)
                defer { rowInterval.end() }
                rowData = buildRowDrawData(row: snapshotRow,
                                           absoluteRow: absoluteRow,
                                           snapshot: snapshot,
                                           context: context,
                                           yDisp: visibleDisp,
                                           cellWidth: cellWidth,
                                           cellHeight: cellHeight,
                                           yOffset: yOffset,
                                           viewWidthPx: viewWidthPx,
                                           scale: scale)
                let buffers = bufferingMode == .perRowPersistent ? makeRowBuffers(from: rowData) : nil
                entry = RowCacheEntry(sourceIdentity: sourceIdentity,
                                      sourceGeneration: snapshotRow.sourceGeneration,
                                      revision: snapshotRow.revision,
                                      data: rowData, buffers: buffers)
                rowCache[absoluteRow] = entry
                rowBuffers = buffers
                rebuiltRows += 1
            } else if let cached = entry {
                rowData = cached.data ?? buildRowDrawData(row: snapshotRow,
                                                          absoluteRow: absoluteRow,
                                                          snapshot: snapshot,
                                                          context: context,
                                                          yDisp: visibleDisp,
                                                          cellWidth: cellWidth,
                                                          cellHeight: cellHeight,
                                                          yOffset: yOffset,
                                                          viewWidthPx: viewWidthPx,
                                                          scale: scale)
                if cached.data == nil {
                    entry = RowCacheEntry(sourceIdentity: sourceIdentity,
                                          sourceGeneration: snapshotRow.sourceGeneration,
                                          revision: snapshotRow.revision,
                                          data: rowData, buffers: cached.buffers)
                    rowCache[absoluteRow] = entry
                }
                if bufferingMode == .perRowPersistent {
                    if let buffers = cached.buffers {
                        rowBuffers = buffers
                    } else {
                        let buffers = makeRowBuffers(from: rowData)
                        entry?.buffers = buffers
                        rowCache[absoluteRow] = entry
                        rowBuffers = buffers
                    }
                } else {
                    rowBuffers = nil
                }
                cachedRows += 1
            } else {
                continue
            }
            if let rowBuffers {
                rows.append(rowBuffers)
            }
            if bufferingMode == .perFrameAggregated {
                if var currentFrame = frameData {
                    currentFrame.backgroundCells.append(contentsOf: rowData.backgroundCells)
                    currentFrame.powerlineJoinCells.append(contentsOf: rowData.powerlineJoinCells)
                    currentFrame.glyphCellsGray.append(contentsOf: rowData.glyphCellsGray)
                    currentFrame.glyphCellsColor.append(contentsOf: rowData.glyphCellsColor)
                    currentFrame.decorationCells.append(contentsOf: rowData.decorationCells)
                    currentFrame.belowBackgroundImageDraws.append(
                        contentsOf: rowData.belowBackgroundImageDraws)
                    currentFrame.underImageDraws.append(contentsOf: rowData.underImageDraws)
                    currentFrame.placeholderImageDraws.append(contentsOf: rowData.placeholderImageDraws)
                    currentFrame.overImageDraws.append(contentsOf: rowData.overImageDraws)
                    currentFrame.otherImageDraws.append(contentsOf: rowData.otherImageDraws)
                    frameData = currentFrame
                }
            }
        }
#if DEBUG
        debugRowsRebuilt = rebuiltRows
        debugRowsCached = cachedRows
#endif
        if ProfilingStats.enabled {
            activeProfileCounters.rowsRebuilt += rebuiltRows
        }

        let cursorData = buildCursorDrawData(snapshot: snapshot,
                                             context: context,
                                             scale: scale,
                                             cellWidth: cellWidth,
                                             cellHeight: cellHeight,
                                             yDisp: visibleDisp,
                                             firstRow: firstRow,
                                             lastRow: lastRow)

        return DrawData(rows: rows,
                        frame: frameData,
                        cursorColorVertices: cursorData.colorVertices,
                        cursorGlyphVerticesGray: cursorData.glyphVerticesGray,
                        cursorGlyphVerticesColor: cursorData.glyphVerticesColor)
    }

    private func visibleRowRange(snapshot: TerminalSnapshot) -> (Int, Int, Int)? {
        guard snapshot.linesCount > 0, snapshot.rowCount > 0,
              !snapshot.rows.isEmpty else {
            return nil
        }
        let firstRow = snapshot.firstRow
        let lastRow = min(snapshot.linesCount - 1,
                          firstRow + min(snapshot.rowCount, snapshot.rows.count) - 1)
        guard firstRow <= lastRow else { return nil }
        return (firstRow, lastRow, snapshot.yDisp)
    }

    private func buildRowDrawData(row: TerminalSnapshot.Row,
                                  absoluteRow: Int,
                                  snapshot: TerminalSnapshot,
                                  context: SnapshotRenderContext,
                                  yDisp: Int,
                                  cellWidth: CGFloat,
                                  cellHeight: CGFloat,
                                  yOffset: CGFloat,
                                  viewWidthPx: CGFloat,
                                  scale: CGFloat) -> RowDrawData {
        var backgroundCells: [ColorCell] = []
        var powerlineJoinCells: [ColorCell] = []
        var glyphCellsGray: [TextCell] = []
        var glyphCellsColor: [TextCell] = []
        var decorationCells: [ColorCell] = []
        var belowBackgroundImageDraws: [ImageDraw] = []
        var underImageDraws: [ImageDraw] = []
        var placeholderImageDraws: [ImageDraw] = []
        var overImageDraws: [ImageDraw] = []
        var otherImageDraws: [ImageDraw] = []

        let line = row.line
        let renderMode = line.renderMode
        let lineOffset = cellHeight * CGFloat(absoluteRow - yDisp + 1)
        let lineOrigin = CGPoint(x: 0, y: context.viewBounds.height - lineOffset)
        let rowBase = lineOrigin.y + cellHeight
        let attrInterval = Profiling.begin(.rowAttributedString)
        let lineInfo = textBuilder.buildAttributedString(row: row,
                                                         absoluteRow: absoluteRow,
                                                         context: context)
        attrInterval.end()
        let shapeInterval = Profiling.begin(.rowShape)
        let shapedSegments = buildShapedSegments(lineInfo.segments, context: context)
        shapeInterval.end()
        let lineOriginPx = CGPoint(x: lineOrigin.x * scale, y: lineOrigin.y * scale)
        let cellWidthPx = cellWidth * scale
        let cellHeightPx = cellHeight * scale
        let baseCellWidthPx = max(1, Int(round(cellWidthPx)))
        let baseCellHeightPx = max(1, Int(round(cellHeightPx)))
        let clipRect: ClipRect? = {
            switch renderMode {
            case .doubledDown, .doubledTop:
                return ClipRect(minX: 0,
                                minY: Float(lineOriginPx.y),
                                maxX: Float(viewWidthPx),
                                maxY: Float(lineOriginPx.y + cellHeightPx))
            case .single, .doubleWidth:
                return nil
            }
        }()
        let pivotY: CGFloat = {
            switch renderMode {
            case .doubledDown:
                return lineOrigin.y * scale
            case .doubledTop:
                return (lineOrigin.y + cellHeight) * scale
            case .single, .doubleWidth:
                return 0
            }
        }()
        let underlinePosition = context.fonts.underlinePosition()
        let underlineThickness = max(round(scale * context.fonts.underlineThickness()) / scale, 0.5)
        let decorationCellWidth = ceil(cellWidth)

        if !lineInfo.boxDrawings.isEmpty || !lineInfo.blockElements.isEmpty || !lineInfo.powerlineGlyphs.isEmpty {
            let boxThicknessScale: CGFloat = 1.35
            let minThicknessPx = max(1, Int(round(scale)))
            let baseThicknessPx = max(minThicknessPx,
                                      Int(round(scale * context.fonts.underlineThickness() * boxThicknessScale)))
            let antiAliasBlocks = context.antiAliasCustomBlockGlyphs

            for item in lineInfo.boxDrawings {
                let itemWidthPx = baseCellWidthPx * item.columnWidth
                guard let entry = customGlyphEntry(codePoint: item.codePoint,
                                                   cellWidthPx: itemWidthPx,
                                                   cellHeightPx: baseCellHeightPx,
                                                   scale: scale,
                                                   baseThicknessPx: baseThicknessPx,
                                                   antiAlias: false) else {
                    continue
                }
                let atlasSize = Float(grayscaleAtlas.size)
                let u0 = Float(entry.region.x) / atlasSize
                let v0 = Float(entry.region.y) / atlasSize
                let u1 = Float(entry.region.x + entry.region.width) / atlasSize
                let v1 = Float(entry.region.y + entry.region.height) / atlasSize
                let alignedOriginX = round(lineOriginPx.x)
                let alignedOriginY = round(lineOriginPx.y)
                let x0 = alignedOriginX + CGFloat(item.column * baseCellWidthPx)
                let y0 = alignedOriginY
                let x1 = x0 + CGFloat(itemWidthPx)
                let placementHeightPx = antiAliasBlocks ? cellHeightPx : CGFloat(baseCellHeightPx)
                let y1 = y0 + placementHeightPx
                let (tx0, ty0, tx1, ty1) = transformRect(x0: x0, y0: y0, x1: x1, y1: y1)
                if let clipped = self.clipRect(tx0, ty0, tx1, ty1, u0, v0, u1, v1, clipRect) {
                    let color = colorToSIMD(item.foregroundColor)
                    glyphCellsGray.append(makeTextCell(x0: clipped.x0,
                                                       y0: clipped.y0,
                                                       x1: clipped.x1,
                                                       y1: clipped.y1,
                                                       u0: clipped.u0,
                                                       v0: clipped.v0,
                                                       u1: clipped.u1,
                                                       v1: clipped.v1,
                                                       color: color))
                }
            }

            for element in lineInfo.blockElements {
                let itemWidthPx: Int
                if antiAliasBlocks {
                    itemWidthPx = max(1, Int(round(cellWidthPx * CGFloat(element.columnWidth))))
                } else {
                    itemWidthPx = baseCellWidthPx * element.columnWidth
                }
                guard let entry = customGlyphEntry(codePoint: element.codePoint,
                                                   cellWidthPx: itemWidthPx,
                                                   cellHeightPx: baseCellHeightPx,
                                                   scale: scale,
                                                   baseThicknessPx: 0,
                                                   antiAlias: antiAliasBlocks) else {
                    continue
                }
                let atlasSize = Float(grayscaleAtlas.size)
                let u0 = Float(entry.region.x) / atlasSize
                let v0 = Float(entry.region.y) / atlasSize
                let u1 = Float(entry.region.x + entry.region.width) / atlasSize
                let v1 = Float(entry.region.y + entry.region.height) / atlasSize
                let originX: CGFloat
                let originY: CGFloat
                if antiAliasBlocks {
                    originX = lineOriginPx.x + CGFloat(element.column) * cellWidthPx
                    originY = lineOriginPx.y
                } else {
                    let alignedOriginX = round(lineOriginPx.x)
                    let alignedOriginY = round(lineOriginPx.y)
                    originX = alignedOriginX + CGFloat(element.column * baseCellWidthPx)
                    originY = alignedOriginY
                }
                let x0 = originX
                let y0 = originY
                let placementWidthPx = antiAliasBlocks ? (cellWidthPx * CGFloat(element.columnWidth)) : CGFloat(itemWidthPx)
                let x1 = x0 + placementWidthPx
                let y1 = y0 + CGFloat(baseCellHeightPx)
                let (tx0, ty0, tx1, ty1) = transformRect(x0: x0, y0: y0, x1: x1, y1: y1)
                if let clipped = self.clipRect(tx0, ty0, tx1, ty1, u0, v0, u1, v1, clipRect) {
                    let color = colorToSIMD(element.foregroundColor)
                    glyphCellsGray.append(makeTextCell(x0: clipped.x0,
                                                       y0: clipped.y0,
                                                       x1: clipped.x1,
                                                       y1: clipped.y1,
                                                       u0: clipped.u0,
                                                       v0: clipped.v0,
                                                       u1: clipped.u1,
                                                       v1: clipped.v1,
                                                       color: color))
                }
            }

            for item in lineInfo.powerlineGlyphs {
                let itemWidthPx = baseCellWidthPx * item.columnWidth
                guard let entry = customGlyphEntry(codePoint: item.codePoint,
                                                   cellWidthPx: itemWidthPx,
                                                   cellHeightPx: baseCellHeightPx,
                                                   scale: scale,
                                                   baseThicknessPx: 0,
                                                   antiAlias: true) else {
                    continue
                }
                let atlasSize = Float(grayscaleAtlas.size)
                let u0 = Float(entry.region.x) / atlasSize
                let v0 = Float(entry.region.y) / atlasSize
                let u1 = Float(entry.region.x + entry.region.width) / atlasSize
                let v1 = Float(entry.region.y + entry.region.height) / atlasSize
                let alignedOriginX = round(lineOriginPx.x) + CGFloat(item.column * baseCellWidthPx)
                let alignedOriginY = round(lineOriginPx.y)
                let x0 = alignedOriginX
                let y0 = alignedOriginY
                let x1 = x0 + entry.size.width
                let y1 = y0 + entry.size.height
                let (tx0, ty0, tx1, ty1) = transformRect(x0: x0, y0: y0, x1: x1, y1: y1)
                if let clipped = self.clipRect(tx0, ty0, tx1, ty1, u0, v0, u1, v1, clipRect) {
                    let color = colorToSIMD(item.foregroundColor)
                    glyphCellsGray.append(makeTextCell(x0: clipped.x0,
                                                       y0: clipped.y0,
                                                       x1: clipped.x1,
                                                       y1: clipped.y1,
                                                       u0: clipped.u0,
                                                       v0: clipped.v0,
                                                       u1: clipped.u1,
                                                       v1: clipped.v1,
                                                       color: color))
                }
                // Add the joining edge after the DEC line transform so it is
                // exactly one final device pixel even for 2x line modes.
                let transformedCellRect = CGRect(x: CGFloat(min(tx0, tx1)),
                                                 y: CGFloat(min(ty0, ty1)),
                                                 width: CGFloat(abs(tx1 - tx0)),
                                                 height: CGFloat(abs(ty1 - ty0)))
                if let joinRect = PowerlineRenderer.devicePixelJoinRect(codePoint: item.codePoint,
                                                                        transformedCellRect: transformedCellRect),
                   let clippedJoin = self.clipRect(Float(joinRect.minX),
                                                   Float(joinRect.minY),
                                                   Float(joinRect.maxX),
                                                   Float(joinRect.maxY),
                                                   clipRect) {
                    powerlineJoinCells.append(makeColorCell(x0: clippedJoin.0,
                                                            y0: clippedJoin.1,
                                                            x1: clippedJoin.2,
                                                            y1: clippedJoin.3,
                                                            color: colorToSIMD(item.foregroundColor)))
                }
            }
        }

        func transformPoint(_ point: CGPoint) -> CGPoint {
            switch renderMode {
            case .single:
                return point
            case .doubleWidth:
                return CGPoint(x: point.x * 2, y: point.y)
            case .doubledDown, .doubledTop:
                return CGPoint(x: point.x * 2, y: pivotY + (point.y - pivotY) * 2)
            }
        }

        func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Float, Float) {
            let p0 = transformPoint(CGPoint(x: x0, y: y0))
            let p1 = transformPoint(CGPoint(x: x1, y: y1))
            let minX = min(p0.x, p1.x)
            let minY = min(p0.y, p1.y)
            let maxX = max(p0.x, p1.x)
            let maxY = max(p0.y, p1.y)
            return (Float(minX), Float(minY), Float(maxX), Float(maxY))
        }

        for shaped in shapedSegments {
            for run in shaped.runs {
                let runGlyphsCount = run.shaperRun.glyphCount
                if runGlyphsCount == 0 {
                    continue
                }
                let runAttributes = run.attributes
                var minOrdinal = Int.max
                var maxOrdinal = Int.min
                for index in run.shaperRun.stringIndices {
                    let ordinal = shaped.segment.cellOrdinal(forUTF16: run.utf16Offset + index)
                    minOrdinal = min(minOrdinal, ordinal)
                    maxOrdinal = max(maxOrdinal, ordinal)
                }
                let startColumn = shaped.segment.column + (minOrdinal * shaped.segment.columnWidth)
                let endColumn = shaped.segment.column + ((maxOrdinal + 1) * shaped.segment.columnWidth)
                var backgroundColor: TTColor?
                if runAttributes.keys.contains(.selectionBackgroundColor) {
                    backgroundColor = runAttributes[.selectionBackgroundColor] as? TTColor
                } else if runAttributes.keys.contains(.backgroundColor) {
                    backgroundColor = runAttributes[.backgroundColor] as? TTColor
                }
                // Default-background cells emit no quad. The pass clear
                // paints them, so Kitty images below explicit cell
                // backgrounds remain visible through these cells.
                let hasExplicitBackground =
                    runAttributes.keys.contains(.selectionBackgroundColor)
                    || runAttributes.keys.contains(SwiftTermExplicitBackgroundKey)
                if hasExplicitBackground, let backgroundColor {
                    let columnSpan = max(0, endColumn - startColumn)
                    if columnSpan > 0 {
                        let x0 = lineOriginPx.x + (CGFloat(startColumn) * cellWidthPx)
                        let y0 = lineOriginPx.y
                        let x1 = lineOriginPx.x + (CGFloat(startColumn + columnSpan) * cellWidthPx)
                        let y1 = lineOriginPx.y + cellHeightPx
                        let (tx0, ty0, tx1, ty1) = transformRect(x0: x0, y0: y0, x1: x1, y1: y1)
                        if let clipped = self.clipRect(tx0, ty0, tx1, ty1, clipRect) {
                            let color = colorToSIMD(backgroundColor)
                            backgroundCells.append(makeColorCell(x0: clipped.0,
                                                                  y0: clipped.1,
                                                                  x1: clipped.2,
                                                                  y1: clipped.3,
                                                                  color: color))
                        }
                    }
                }
            }
        }

        if let images = lineInfo.images {
            for basicImage in images {
                guard let image = basicImage as? SnapshotImage else {
                    continue
                }
                guard let texture = texture(for: image) else {
                    continue
                }
                let rect = CGRect(x: CGFloat(image.col) * cellWidth,
                                  y: rowBase - CGFloat(image.pixelHeight),
                                  width: CGFloat(image.pixelWidth),
                                  height: CGFloat(image.pixelHeight))
                if let draw = imageDraw(texture: texture,
                                        rect: rect,
                                        uvRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                        renderMode: renderMode,
                                        clipRect: clipRect,
                                        pivotY: pivotY,
                                        scale: scale) {
                    otherImageDraws.append(draw)
                }
            }
        }

        // Skipped whole on a frame with no image, which is the common case:
        // the clip rectangle and the loop below produce nothing then.
        if !snapshot.kitty.renderSnapshot.placements.isEmpty {
            let screenRow = absoluteRow - yDisp
            let kittyLineClip = ClipRect(
                minX: 0,
                minY: Float(lineOriginPx.y),
                maxX: Float(viewWidthPx),
                maxY: Float(lineOriginPx.y + cellHeightPx))
            for placement in snapshot.kitty.renderSnapshot.placements where !placement.isVirtual {
                let geometry = placement.geometry
                guard screenRow >= geometry.row,
                      screenRow < geometry.row + geometry.rows,
                      let image = snapshot.kitty.renderSnapshot.imagesById[placement.imageId],
                      let texture = kittyTexture(
                        imageId: placement.imageId,
                        renderSnapshot: snapshot.kitty.renderSnapshot) else { continue }
                let offsetX = CGFloat(placement.pixelOffsetX) / context.imageScale
                let offsetY = CGFloat(placement.pixelOffsetY) / context.imageScale
                let rowsBelow = geometry.row + geometry.rows - 1 - screenRow
                let rect = CGRect(
                    x: CGFloat(geometry.column) * cellWidth + offsetX,
                    y: lineOrigin.y - CGFloat(rowsBelow) * cellHeight + offsetY,
                    width: max(0, CGFloat(geometry.columns) * cellWidth - offsetX),
                    height: max(0, CGFloat(geometry.rows) * cellHeight - offsetY))
                let source = placement.visibleSource
                let sourceBottom = image.height - source.y - source.height
                let uvRect = CGRect(
                    x: CGFloat(source.x) / CGFloat(image.width),
                    y: CGFloat(sourceBottom) / CGFloat(image.height),
                    width: CGFloat(source.width) / CGFloat(image.width),
                    height: CGFloat(source.height) / CGFloat(image.height))
                guard let draw = imageDraw(
                    texture: texture,
                    rect: rect,
                    uvRect: uvRect,
                    renderMode: renderMode,
                    clipRect: kittyLineClip,
                    pivotY: pivotY,
                    scale: scale) else { continue }
                switch KittyGraphicsRenderLayer(zIndex: placement.zIndex) {
                case .belowBackground:
                    belowBackgroundImageDraws.append(draw)
                case .belowText:
                    underImageDraws.append(draw)
                case .aboveText:
                    overImageDraws.append(draw)
                }
            }
        }

        for shaped in shapedSegments {
            for run in shaped.runs {
                let runGlyphsCount = run.shaperRun.glyphCount
                if runGlyphsCount == 0 {
                    continue
                }
                let runAttributes = run.attributes
                let runFont = runAttributes[.font] as? TTFont ?? context.fonts.normal
                let ctFont = runFont as CTFont

                let textColor = runAttributes[.foregroundColor] as? TTColor ?? context.effectiveForegroundColor
                let textColorSIMD = colorToSIMD(textColor)

                let glyphPolicy = runAttributes[SwiftTermGlyphPolicyKey] as? TerminalGlyphPlacementPolicy
                let policyIconHeight = glyphPolicy != nil
                    ? CTFontGetAscent(context.fonts.normal as CTFont) * scale : 0

                // Same-cell glyphs (base + combining marks) are adjacent in
                // glyph order, so a pair of locals replaces a per-run anchor
                // dictionary.
                var anchorOrdinal = -1
                var anchorX: CGFloat = 0
                for glyphRun in run.shaperRun.glyphRuns {
                    let scaledFont = scaledFontFor(font: glyphRun.font, scale: scale)
                    let rasterFontToken = rasterFontToken(for: scaledFont)
                    let fullFontToken = profileFullFontToken(
                        rasterFont: scaledFont,
                        fittingFont: glyphRun.font,
                        renderingScale: scale,
                        rasterFontToken: rasterFontToken)
                    var metricsFont: GlyphMetricsFont?
                    for i in 0..<glyphRun.glyphs.count {
                        let glyph = glyphRun.glyphs[i]
                        recordProfileGlyphIdentityAlias(
                            fullFontToken: fullFontToken,
                            rasterFontToken: rasterFontToken,
                            glyph: glyph)
                        guard let resolvedGlyph = glyphEntry(
                            rasterFontToken: rasterFontToken,
                            font: scaledFont,
                            fittingFont: glyphRun.font,
                            renderingScale: scale,
                            metricsFont: &metricsFont,
                            glyph: glyph) else {
                            continue
                        }
                        let entry = resolvedGlyph.entry
                        if entry.size.width <= 0 || entry.size.height <= 0 {
                            continue
                        }
                        let ctPos = glyphRun.positions[i]
                        let stringIndex = run.utf16Offset + glyphRun.stringIndices[i]
                        let ordinal = shaped.segment.cellOrdinal(forUTF16: stringIndex)
                        let intraCluster: CGFloat
                        if ordinal == anchorOrdinal {
                            intraCluster = ctPos.x - anchorX
                        } else {
                            anchorOrdinal = ordinal
                            anchorX = ctPos.x
                            intraCluster = 0
                        }
                        let glyphColumn = shaped.segment.column + (ordinal * shaped.segment.columnWidth)
                        // Center full-width (CJK) and substituted glyphs within
                        // their multi-cell slot instead of pinning them to the
                        // cell's left edge, mirroring the CoreGraphics path. The
                        // decoration loops below keep using the grid column, so
                        // underlines/strikethroughs stay cell-aligned.
                        let fit = glyphSlotFit(resolvedGlyph: resolvedGlyph,
                                               glyph: glyph,
                                               columnWidth: shaped.segment.columnWidth,
                                               cellDimension: context.cellDimension,
                                               baselineFromBottom: yOffset,
                                               font: scaledFont,
                                               fittingFont: glyphRun.font,
                                               renderingScale: scale,
                                               metricsFont: &metricsFont,
                                               policy: glyphPolicy,
                                               iconHeight: policyIconHeight)
                        let basePos = CGPoint(x: lineOrigin.x + (cellWidth * CGFloat(glyphColumn)) + intraCluster + fit.dx,
                                              y: lineOrigin.y + yOffset + ctPos.y + fit.dy)
                        let pxX = basePos.x * scale + entry.bearing.x * fit.scaleX
                        let pxY = basePos.y * scale + entry.bearing.y * fit.scaleY

                        let x0 = pxX
                        let y0 = pxY
                        let x1 = pxX + entry.size.width * fit.scaleX
                        let y1 = pxY + entry.size.height * fit.scaleY
                        let (tx0, ty0, tx1, ty1) = transformRect(x0: x0, y0: y0, x1: x1, y1: y1)

                        let atlasSize = entry.atlasKind == .color ? colorAtlas.size : grayscaleAtlas.size
                        let u0 = Float(entry.region.x) / Float(atlasSize)
                        let v0 = Float(entry.region.y) / Float(atlasSize)
                        let u1 = Float(entry.region.x + entry.region.width) / Float(atlasSize)
                        let v1 = Float(entry.region.y + entry.region.height) / Float(atlasSize)

                        let color = entry.isColor ? SIMD4<Float>(1, 1, 1, 1) : textColorSIMD
                        if let clipped = self.clipRect(tx0, ty0, tx1, ty1, u0, v0, u1, v1, clipRect) {
                            let cell = makeTextCell(x0: clipped.x0,
                                                    y0: clipped.y0,
                                                    x1: clipped.x1,
                                                    y1: clipped.y1,
                                                    u0: clipped.u0,
                                                    v0: clipped.v0,
                                                    u1: clipped.u1,
                                                    v1: clipped.v1,
                                                    color: color)
                            switch entry.atlasKind {
                            case .grayscale:
                                glyphCellsGray.append(cell)
                            case .color:
                                glyphCellsColor.append(cell)
                            }
                        }
                    }
                }

                if let rawStyle = runAttributes[.underlineStyle] as? Int,
                   rawStyle != 0 {
                    let underlineStyle = resolveUnderlineStyle(runAttributes)
                    let underlineColor = (runAttributes[.underlineColor] as? TTColor) ??
                        context.effectiveForegroundColor
                    let underlineColorSIMD = colorToSIMD(underlineColor)
                    let thickness = underlineThickness * scale
                    let segmentStyle: UnderlineStyle = underlineStyle == .double ? .single : underlineStyle

                    for (glyphIndex, ctPos) in run.shaperRun.positions.enumerated() {
                        let stringIndex = run.utf16Offset + run.shaperRun.stringIndices[glyphIndex]
                        let ordinal = shaped.segment.cellOrdinal(forUTF16: stringIndex)
                        let glyphColumn = shaped.segment.column + (ordinal * shaped.segment.columnWidth)
                        let basePos = CGPoint(x: lineOrigin.x + (cellWidth * CGFloat(glyphColumn)),
                                              y: lineOrigin.y + yOffset + ctPos.y)
                        let x0 = basePos.x * scale
                        let x1 = (basePos.x + decorationCellWidth) * scale
                        let yCenter = (basePos.y + underlinePosition) * scale
                        appendUnderlineSegments(x0: x0,
                                                x1: x1,
                                                yCenter: yCenter,
                                                thickness: thickness,
                                                color: underlineColorSIMD,
                                                style: segmentStyle,
                                                patternScale: scale,
                                                renderMode: renderMode,
                                                clipRect: clipRect,
                                                pivotY: pivotY,
                                                output: &decorationCells)
                        if underlineStyle == .double {
                            let yDouble = (basePos.y + underlinePosition - underlineThickness - 1) * scale
                            appendUnderlineSegments(x0: x0,
                                                    x1: x1,
                                                    yCenter: yDouble,
                                                    thickness: thickness,
                                                    color: underlineColorSIMD,
                                                    style: segmentStyle,
                                                    patternScale: scale,
                                                    renderMode: renderMode,
                                                    clipRect: clipRect,
                                                    pivotY: pivotY,
                                                    output: &decorationCells)
                        }
                    }
                }

                if let rawStyle = runAttributes[.strikethroughStyle] as? Int,
                   rawStyle != 0 {
                    let style = NSUnderlineStyle(rawValue: rawStyle)
                    let strikeColor = (runAttributes[.strikethroughColor] as? TTColor) ??
                        context.effectiveForegroundColor
                    let strikeColorSIMD = colorToSIMD(strikeColor)
                    let strikeStyle: UnderlineStyle
                    if style.contains(.patternDot) {
                        strikeStyle = .dotted
                    } else if style.contains(.patternDash) || style.contains(.patternDashDot) || style.contains(.patternDashDotDot) {
                        strikeStyle = .dashed
                    } else {
                        strikeStyle = .single
                    }
                    let isDouble = style.contains(.double)
                    let strikeThickness = max(round(scale * CTFontGetUnderlineThickness(ctFont)) / scale, 0.5)
                    let strikePosition = (CTFontGetXHeight(ctFont) + strikeThickness) * 0.5

                    for (glyphIndex, ctPos) in run.shaperRun.positions.enumerated() {
                        let stringIndex = run.utf16Offset + run.shaperRun.stringIndices[glyphIndex]
                        let ordinal = shaped.segment.cellOrdinal(forUTF16: stringIndex)
                        let glyphColumn = shaped.segment.column + (ordinal * shaped.segment.columnWidth)
                        let basePos = CGPoint(x: lineOrigin.x + (cellWidth * CGFloat(glyphColumn)),
                                              y: lineOrigin.y + yOffset + ctPos.y)
                        let x0 = basePos.x * scale
                        let x1 = (basePos.x + decorationCellWidth) * scale
                        let yCenter = (basePos.y + strikePosition) * scale
                        let thickness = strikeThickness * scale
                        appendUnderlineSegments(x0: x0,
                                                x1: x1,
                                                yCenter: yCenter,
                                                thickness: thickness,
                                                color: strikeColorSIMD,
                                                style: strikeStyle,
                                                patternScale: scale,
                                                renderMode: renderMode,
                                                clipRect: clipRect,
                                                pivotY: pivotY,
                                                output: &decorationCells)
                        if isDouble {
                            let yDouble = (basePos.y + strikePosition - strikeThickness - 1) * scale
                            appendUnderlineSegments(x0: x0,
                                                    x1: x1,
                                                    yCenter: yDouble,
                                                    thickness: thickness,
                                                    color: strikeColorSIMD,
                                                    style: strikeStyle,
                                                    patternScale: scale,
                                                    renderMode: renderMode,
                                                    clipRect: clipRect,
                                                    pivotY: pivotY,
                                                    output: &decorationCells)
                        }
                    }
                }

            }
        }

        if !lineInfo.kittyPlaceholders.isEmpty {
            for placeholder in lineInfo.kittyPlaceholders {
                guard let record = snapshot.kitty.renderSnapshot.placements.first(where: { record in
                    guard record.isVirtual, record.imageId == placeholder.imageId else { return false }
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
                guard let texture = kittyTexture(imageId: placeholder.imageId,
                                                 renderSnapshot: snapshot.kitty.renderSnapshot) else {
                    continue
                }

                let offsetScale = context.imageScale
                let offsetX = CGFloat(record.pixelOffsetX) / offsetScale
                let offsetY = CGFloat(record.pixelOffsetY) / offsetScale
                let placementOriginX = lineOrigin.x + CGFloat(placeholder.col - placeholder.placeholderCol) * cellWidth + offsetX
                let placementTopY = lineOrigin.y + CGFloat(placeholder.placeholderRow) * cellHeight
                let placementOriginY = placementTopY - CGFloat(record.geometry.rows - 1) * cellHeight + offsetY
                let placementRect = CGRect(x: placementOriginX,
                                           y: placementOriginY,
                                           width: CGFloat(record.geometry.columns) * cellWidth,
                                           height: CGFloat(record.geometry.rows) * cellHeight)
                if placementRect.width <= 0 || placementRect.height <= 0 {
                    continue
                }
                let cellRect = CGRect(x: lineOrigin.x + CGFloat(placeholder.col) * cellWidth,
                                      y: lineOrigin.y,
                                      width: cellWidth,
                                      height: cellHeight)
                guard let geometry = Self.kittyVirtualImageGeometry(
                    source: record.visibleSource,
                    textureWidth: texture.width,
                    textureHeight: texture.height,
                    placementRect: placementRect,
                    cellRect: cellRect,
                    scale: scale) else {
                    continue
                }
                if let draw = imageDraw(texture: texture,
                                        rect: geometry.visibleRect,
                                        uvRect: geometry.uvRect,
                                        renderMode: renderMode,
                                        clipRect: clipRect,
                                        pivotY: pivotY,
                                        scale: scale) {
                    placeholderImageDraws.append(draw)
                }
            }
        }

        return RowDrawData(backgroundCells: backgroundCells,
                           powerlineJoinCells: powerlineJoinCells,
                           glyphCellsGray: glyphCellsGray,
                           glyphCellsColor: glyphCellsColor,
                           decorationCells: decorationCells,
                           belowBackgroundImageDraws: belowBackgroundImageDraws,
                           underImageDraws: underImageDraws,
                           placeholderImageDraws: placeholderImageDraws,
                           overImageDraws: overImageDraws,
                           otherImageDraws: otherImageDraws)
    }

    private func buildShapedSegments(_ segments: [ViewLineSegment],
                                     context: SnapshotRenderContext) -> [ShapedSegment] {
        var shapedSegments: [ShapedSegment] = []
        for segment in segments {
            guard segment.attributedString.length > 0 else {
                continue
            }
            let fullString = segment.attributedString.string as NSString
            var shapedRuns: [ShapedRun] = []
            segment.attributedString.enumerateAttributes(in: NSRange(location: 0, length: segment.attributedString.length),
                                                         options: []) { attributes, range, _ in
                let text = fullString.substring(with: range)
                guard !text.isEmpty else {
                    return
                }
                let runFont = attributes[.font] as? TTFont ?? context.fonts.normal
                // A host fallback font can be replaced by another with the
                // same PostScript name and size; the cached run retains its
                // font, so the object identity is a stable discriminator.
                let fallbackTag: UInt64 = attributes[SwiftTermGlyphPolicyKey] != nil
                    ? UInt64(bitPattern: Int64(ObjectIdentifier(runFont).hashValue)) : 0
                guard let shaped = shaperCache.shape(text: text, font: runFont as CTFont,
                                                     fallbackTag: fallbackTag) else {
                    return
                }
                shapedRuns.append(ShapedRun(attributes: attributes,
                                            utf16Offset: range.location,
                                            shaperRun: shaped))
            }
            if !shapedRuns.isEmpty {
                shapedSegments.append(ShapedSegment(segment: segment, runs: shapedRuns))
            }
        }
        return shapedSegments
    }

    /// Reacts to a grow or reset that `ensureRegion` performed on `atlas`.
    /// A reset invalidates every previously issued region, so all glyph
    /// caches must go. A grow preserves pixel coordinates, so glyph entries
    /// stay valid; only UVs already normalized against the old atlas size
    /// (the row caches, and rows emitted earlier in this build pass) are
    /// stale. Either way the current build pass must be redone.
    private func handleAtlasChange(_ atlas: GlyphAtlas, previousSize: Int) {
        if atlas.didReset {
            glyphBitmapResultCache.removeDrawables()
            customGlyphCache.removeAll()
            rowCache.removeAll()
            atlasInvalidatedDuringBuild = true
            if ProfilingStats.enabled {
                if atlas === colorAtlas {
                    activeProfileCounters.colorAtlasResets += 1
                } else {
                    activeProfileCounters.grayscaleAtlasResets += 1
                }
            }
        } else if atlas.size != previousSize {
            rowCache.removeAll()
            atlasInvalidatedDuringBuild = true
            if ProfilingStats.enabled {
                if atlas === colorAtlas {
                    activeProfileCounters.colorAtlasGrows += 1
                } else {
                    activeProfileCounters.grayscaleAtlasGrows += 1
                }
            }
        }
    }

    private func internMetricsFont(_ font: CTFont, fittingFont: CTFont,
                                   renderingScale: CGFloat) -> GlyphMetricsFont {
        let interned = glyphMetricsCache.intern(font: font,
                                                fittingFont: fittingFont,
                                                renderingScale: renderingScale)
        handleMetricsGenerationChange()
        if ProfilingStats.enabled {
            activeProfileCounters.metricsFontRegistryHighWater = max(
                activeProfileCounters.metricsFontRegistryHighWater,
                glyphMetricsCache.fontRegistryHighWater)
        }
        return interned
    }

    private func rasterFontToken(for font: CTFont) -> UInt32 {
        let previousCount = ProfilingStats.enabled ? rasterFontRegistry.count : 0
        if let token = rasterFontRegistry.intern(font) {
            if ProfilingStats.enabled {
                activeProfileCounters.rasterFontRegistryLookups += 1
                if rasterFontRegistry.count == previousCount {
                    activeProfileCounters.rasterFontRegistryHits += 1
                } else {
                    activeProfileCounters.rasterFontRegistryMisses += 1
                }
                activeProfileCounters.rasterFontRegistryHighWater = max(
                    activeProfileCounters.rasterFontRegistryHighWater,
                    rasterFontRegistry.count)
            }
            return token
        }

        // This is a renderer-owned font-registry teardown. Atlas resets do not
        // clear these tokens. A teardown is allowed to clear both glyph-key
        // caches because their tokens must never be rebound to another font.
        let previousEvictions = glyphBitmapResultCache.emptyEvictionCount
        glyphBitmapResultCache.removeAll()
        if ProfilingStats.enabled {
            activeProfileCounters.rasterFontRegistryLookups += 1
            activeProfileCounters.rasterFontRegistryMisses += 1
            activeProfileCounters.rasterFontRegistryHighWater = max(
                activeProfileCounters.rasterFontRegistryHighWater,
                rasterFontRegistry.count)
            activeProfileCounters.rasterFontRegistryTeardowns += 1
        }
        rasterFontRegistry.removeAll()
        if ProfilingStats.enabled {
            activeProfileCounters.negativeCacheEvictions +=
                glyphBitmapResultCache.emptyEvictionCount - previousEvictions
        }
        guard let token = rasterFontRegistry.intern(font) else {
            preconditionFailure("raster font registry did not accept a font after teardown")
        }
        return token
    }

    private func profileFullFontToken(rasterFont: CTFont,
                                      fittingFont: CTFont,
                                      renderingScale: CGFloat,
                                      rasterFontToken: UInt32) -> UInt32 {
        guard ProfilingStats.enabled else { return 0 }
        let identity = ProfileFullFontIdentity(
            rasterFont: CoreTextFontIdentity(rasterFont),
            fittingFont: CoreTextFontIdentity(fittingFont),
            renderingScale: renderingScale)
        if let token = profileFullFontTokens[identity] {
            return token
        }
        let maximumFullFonts = 4_096
        guard profileFullFontTokens.count < maximumFullFonts else { return 0 }
        let token = nextProfileFullFontToken
        nextProfileFullFontToken &+= 1
        precondition(nextProfileFullFontToken != 0,
                     "profile full font token exhausted")
        profileFullFontTokens[identity] = token
        if profileFirstFullFontByRaster[rasterFontToken] == nil {
            profileFirstFullFontByRaster[rasterFontToken] = token
        } else {
            activeProfileCounters.fullIdentityTokensAliasingRasterIdentity += 1
        }
        return token
    }

    private func recordProfileGlyphIdentityAlias(fullFontToken: UInt32,
                                                 rasterFontToken: UInt32,
                                                 glyph: CGGlyph) {
        guard ProfilingStats.enabled, fullFontToken != 0 else { return }
        let fullKey = ProfileFullGlyphKey(fullFontToken: fullFontToken,
                                          glyph: glyph)
        if profileFullGlyphKeys.contains(fullKey) {
            return
        }
        let maximumFullGlyphKeys = 65_536
        guard profileFullGlyphKeys.count < maximumFullGlyphKeys else { return }
        profileFullGlyphKeys.insert(fullKey)
        let rasterKey = GlyphKey(rasterFontToken: rasterFontToken, glyph: glyph)
        if profileFirstFullGlyphByRaster[rasterKey] == nil {
            profileFirstFullGlyphByRaster[rasterKey] = fullKey
        } else {
            activeProfileCounters.fullCacheKeysAliasingRasterGlyphKey += 1
        }
    }

    private func handleMetricsGenerationChange() {
        guard metricsCacheGeneration != glyphMetricsCache.generation else { return }
        metricsCacheGeneration = glyphMetricsCache.generation
        guard ProfilingStats.enabled else { return }
        switch glyphMetricsCache.lastDiscardReason {
        case .entryLimit:
            activeProfileCounters.metricsEntryLimitResets += 1
        case .fontLimit:
            activeProfileCounters.metricsFontLimitResets += 1
        case nil:
            break
        }
    }

    @inline(__always)
    private func glyphMetrics(font: inout GlyphMetricsFont, glyph: CGGlyph) -> GlyphMetrics {
        let lookup = glyphMetricsCache.metrics(font: &font, glyph: glyph)
        handleMetricsGenerationChange()
        if ProfilingStats.enabled {
            activeProfileCounters.metricsCacheLookups += 1
            if lookup.wasHit {
                activeProfileCounters.metricsCacheHits += 1
            } else {
                activeProfileCounters.metricsCacheMisses += 1
                activeProfileCounters.glyphBoundsQueries += 1
            }
        }
        return lookup.metrics
    }

    private func resolvedGlyphMetrics(font: CTFont,
                                      fittingFont: CTFont,
                                      renderingScale: CGFloat,
                                      metricsFont: inout GlyphMetricsFont?,
                                      glyph: CGGlyph) -> GlyphMetrics {
        var resolvedMetricsFont = metricsFont ?? internMetricsFont(
            font, fittingFont: fittingFont, renderingScale: renderingScale)
        let metrics = glyphMetrics(font: &resolvedMetricsFont, glyph: glyph)
        metricsFont = resolvedMetricsFont
        return metrics
    }

    private func glyphEntry(rasterFontToken: UInt32,
                            font: CTFont,
                            fittingFont: CTFont,
                            renderingScale: CGFloat,
                            metricsFont: inout GlyphMetricsFont?,
                            glyph: CGGlyph) -> ResolvedGlyph? {
        let key = GlyphKey(rasterFontToken: rasterFontToken, glyph: glyph)
        if ProfilingStats.enabled {
            activeProfileCounters.glyphAtlasLookups += 1
        }
        switch glyphBitmapResultCache.lookup(key) {
        case .drawable(let cached):
            if ProfilingStats.enabled {
                activeProfileCounters.glyphAtlasHits += 1
            }
            return ResolvedGlyph(entry: cached, metricsFromMiss: nil)
        case .permanentEmpty:
            if ProfilingStats.enabled {
                activeProfileCounters.glyphAtlasMisses += 1
                activeProfileCounters.permanentEmptyHits += 1
                activeProfileCounters.negativeCacheHighWater = max(
                    activeProfileCounters.negativeCacheHighWater,
                    glyphBitmapResultCache.emptyHighWaterCount)
            }
            return nil
        case .miss:
            if ProfilingStats.enabled {
                activeProfileCounters.glyphAtlasMisses += 1
                activeProfileCounters.fullGlyphCacheMisses += 1
            }
        }

        let metrics = resolvedGlyphMetrics(font: font,
                                           fittingFont: fittingFont,
                                           renderingScale: renderingScale,
                                           metricsFont: &metricsFont,
                                           glyph: glyph)
        if metrics.inkBounds.width <= 0 || metrics.inkBounds.height <= 0 {
            cachePermanentEmpty(key)
            return nil
        }

        if ProfilingStats.enabled {
            activeProfileCounters.rasterizations += 1
        }
        let bitmap: GlyphBitmap
        switch rasterizer.rasterize(font: font, glyph: glyph, metrics: metrics) {
        case .bitmap(let result):
            bitmap = result
            if ProfilingStats.enabled {
                activeProfileCounters.bitmapRasterizationResults += 1
                activeProfileCounters.glyphDrawCalls += 1
            }
        case .empty:
            cachePermanentEmpty(key)
            return nil
        case .transientFailure:
            if ProfilingStats.enabled {
                activeProfileCounters.transientRasterizationFailures += 1
            }
            return nil
        }
        let atlasKind: GlyphAtlasKind = bitmap.isColor ? .color : .grayscale
        let atlas = atlasKind == .color ? colorAtlas : grayscaleAtlas
        let previousSize = atlas.size
        let maybeRegion = atlas.ensureRegion(width: bitmap.width, height: bitmap.height)
        handleAtlasChange(atlas, previousSize: previousSize)
        guard let region = maybeRegion else {
            return nil
        }
        atlas.write(region: region, pixels: bitmap.pixels, width: bitmap.width, height: bitmap.height)
        let entry = GlyphEntry(region: region,
                               size: CGSize(width: bitmap.width, height: bitmap.height),
                               bearing: bitmap.bearing,
                               isColor: bitmap.isColor,
                               atlasKind: atlasKind)
        glyphBitmapResultCache.storeDrawable(entry, for: key)
        return ResolvedGlyph(entry: entry, metricsFromMiss: metrics)
    }

    private func glyphSlotFit(resolvedGlyph: ResolvedGlyph,
                              glyph: CGGlyph,
                              columnWidth: Int,
                              cellDimension: CGSize,
                              baselineFromBottom: CGFloat,
                              font: CTFont,
                              fittingFont: CTFont,
                              renderingScale: CGFloat,
                              metricsFont: inout GlyphMetricsFont?,
                              policy: TerminalGlyphPlacementPolicy? = nil,
                              iconHeight: CGFloat = 0) -> GlyphSlotFit {
        let resolution = resolvedGlyph.fitMetrics(columnWidth: columnWidth,
                                                  required: policy != nil) {
            resolvedGlyphMetrics(font: font,
                                 fittingFont: fittingFont,
                                 renderingScale: renderingScale,
                                 metricsFont: &metricsFont,
                                 glyph: glyph)
        }
        if ProfilingStats.enabled {
            switch resolution.origin {
            case .notNeeded where resolvedGlyph.metricsFromMiss == nil:
                activeProfileCounters.drawableHitsAvoidedMetricsLookup += 1
            case .drawableMiss:
                activeProfileCounters.metricsReusedFromDrawableMiss += 1
            case .metricsCache:
                activeProfileCounters.drawableHitsRequiredMetricsLookup += 1
            case .notNeeded:
                break
            }
        }
        guard let metrics = resolution.metrics else { return .identity }
        if let policy {
            return GlyphSlotFit.calculate(metrics: metrics,
                                          policy: policy,
                                          columnWidth: columnWidth,
                                          cellDimension: cellDimension,
                                          baselineFromBottom: baselineFromBottom,
                                          iconHeight: iconHeight,
                                          renderingScale: renderingScale)
        }
        return GlyphSlotFit.calculate(metrics: metrics,
                                      columnWidth: columnWidth,
                                      cellDimension: cellDimension,
                                      baselineFromBottom: baselineFromBottom,
                                      renderingScale: renderingScale)
    }

    private func cachePermanentEmpty(_ key: GlyphKey) {
        let previousEvictions = glyphBitmapResultCache.emptyEvictionCount
        glyphBitmapResultCache.storePermanentEmpty(key)
        guard ProfilingStats.enabled else { return }
        activeProfileCounters.emptyRasterizationResults += 1
        activeProfileCounters.negativeCacheEvictions +=
            glyphBitmapResultCache.emptyEvictionCount - previousEvictions
        activeProfileCounters.negativeCacheHighWater = max(
            activeProfileCounters.negativeCacheHighWater,
            glyphBitmapResultCache.emptyHighWaterCount)
    }

    private func scaledFontFor(font: CTFont, scale: CGFloat) -> CTFont {
        let key = ScaledFontKey(sourceFont: RetainedFontIdentity(font), scale: scale)
        if let cached = scaledFontCache[key] {
            return cached
        }
        let scaled = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * scale, nil, nil)
        scaledFontCache[key] = scaled
        return scaled
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

    private func customGlyphEntry(codePoint: UInt32,
                                  cellWidthPx: Int,
                                  cellHeightPx: Int,
                                  scale: CGFloat,
                                  baseThicknessPx: Int,
                                  antiAlias: Bool) -> CustomGlyphEntry? {
        let scaleInt = max(1, Int(round(scale)))
        let key = CustomGlyphKey(codePoint: codePoint,
                                 cellWidthPx: cellWidthPx,
                                 cellHeightPx: cellHeightPx,
                                 baseThicknessPx: baseThicknessPx,
                                 scale: scaleInt,
                                 antiAlias: antiAlias)
        if let cached = customGlyphCache[key] {
            return cached
        }
        guard let bitmap = renderCustomGlyphBitmap(codePoint: codePoint,
                                                   cellWidthPx: cellWidthPx,
                                                   cellHeightPx: cellHeightPx,
                                                   scale: scale,
                                                   baseThicknessPx: baseThicknessPx,
                                                   antiAlias: antiAlias) else {
            return nil
        }
        let previousSize = grayscaleAtlas.size
        let maybeRegion = grayscaleAtlas.ensureRegion(width: bitmap.width, height: bitmap.height)
        handleAtlasChange(grayscaleAtlas, previousSize: previousSize)
        guard let region = maybeRegion else {
            return nil
        }
        grayscaleAtlas.write(region: region,
                             pixels: bitmap.pixels,
                             width: bitmap.width,
                             height: bitmap.height)
        let entry = CustomGlyphEntry(region: region,
                                     size: CGSize(width: bitmap.width, height: bitmap.height))
        customGlyphCache[key] = entry
        return entry
    }

    private func renderCustomGlyphBitmap(codePoint: UInt32,
                                         cellWidthPx: Int,
                                         cellHeightPx: Int,
                                         scale: CGFloat,
                                         baseThicknessPx: Int,
                                         antiAlias: Bool) -> CustomGlyphBitmap? {
        guard cellWidthPx > 0, cellHeightPx > 0 else {
            return nil
        }
        let bytesPerPixel = 4
        var pixels = Array(repeating: UInt8(0), count: cellWidthPx * cellHeightPx * bytesPerPixel)
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else {
                return false
            }
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                return false
            }
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            guard let context = CGContext(data: base,
                                          width: cellWidthPx,
                                          height: cellHeightPx,
                                          bitsPerComponent: 8,
                                          bytesPerRow: cellWidthPx * bytesPerPixel,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo) else {
                return false
            }

            let cellSize = CGSize(width: CGFloat(cellWidthPx) / scale,
                                  height: CGFloat(cellHeightPx) / scale)
            let cellOrigin = CGPoint.zero

            switch codePoint {
            case let value where PowerlineRenderer.glyph(for: value) != nil:
                context.setShouldAntialias(true)
                context.setAllowsAntialiasing(true)
                context.scaleBy(x: scale, y: scale)
                PowerlineRenderer.draw(codePoint: codePoint,
                                       in: context,
                                       cellRect: CGRect(x: 0,
                                                        y: 0,
                                                        width: cellSize.width,
                                                        height: cellSize.height),
                                       scaleX: scale,
                                       scaleY: scale,
                                       color: TTColor.white.cgColor,
                                       includeJoinOverdraw: false)
                return true
            case UInt32(BoxDrawingRenderer.lowerBoundary)...UInt32(BoxDrawingRenderer.upperBoundary):
                context.setShouldAntialias(false)
                context.setAllowsAntialiasing(false)
                context.scaleBy(x: scale, y: scale)
                BoxDrawingRenderer.draw(codePoint: codePoint,
                                        in: context,
                                        cellOrigin: cellOrigin,
                                        cellSize: cellSize,
                                        scale: scale,
                                        color: TTColor.white,
                                        baseThicknessPx: baseThicknessPx)
                return true
            case UInt32(BlockElementMapping.lowerBoundary)...UInt32(BlockElementMapping.upperBoundary):
                guard let rects = BlockElementMapping.rects(for: codePoint) else {
                    return false
                }
                context.setShouldAntialias(antiAlias)
                context.setAllowsAntialiasing(antiAlias)
                context.scaleBy(x: scale, y: scale)
                let xEighth = cellSize.width / 8.0
                let yEighth = cellSize.height / 8.0
                for rect in rects {
                    var drawRect = rect.rect(in: cellOrigin,
                                             xEighth: xEighth,
                                             yEighth: yEighth,
                                             cellHeight: cellSize.height)
                    if !antiAlias {
                        drawRect = pixelAlignedRect(drawRect, scale: scale)
                    }
                    if drawRect.width <= 0 || drawRect.height <= 0 {
                        continue
                    }
                    let alpha = max(0, min(1, rect.alpha.rawValue))
                    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
                    context.fill(drawRect)
                }
                return true
            default:
                return false
            }
        }
        guard drew else {
            return nil
        }
        return CustomGlyphBitmap(width: cellWidthPx,
                                 height: cellHeightPx,
                                 pixels: pixels)
    }

    private func quadVertices(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat, color: SIMD4<Float>) -> [ColorVertex] {
        let p0 = SIMD2<Float>(Float(x0), Float(y0))
        let p1 = SIMD2<Float>(Float(x1), Float(y0))
        let p2 = SIMD2<Float>(Float(x0), Float(y1))
        let p3 = SIMD2<Float>(Float(x1), Float(y1))
        return [
            ColorVertex(position: p0, color: color),
            ColorVertex(position: p1, color: color),
            ColorVertex(position: p2, color: color),
            ColorVertex(position: p1, color: color),
            ColorVertex(position: p3, color: color),
            ColorVertex(position: p2, color: color),
        ]
    }

    private func glyphQuadVertices(x0: Float, y0: Float, x1: Float, y1: Float,
                                   u0: Float, v0: Float, u1: Float, v1: Float,
                                   color: SIMD4<Float>) -> [GlyphVertex] {
        let p0 = SIMD2<Float>(x0, y0)
        let p1 = SIMD2<Float>(x1, y0)
        let p2 = SIMD2<Float>(x0, y1)
        let p3 = SIMD2<Float>(x1, y1)
        let t0 = SIMD2<Float>(u0, v0)
        let t1 = SIMD2<Float>(u1, v0)
        let t2 = SIMD2<Float>(u0, v1)
        let t3 = SIMD2<Float>(u1, v1)
        return [
            GlyphVertex(position: p0, texCoord: t0, color: color),
            GlyphVertex(position: p1, texCoord: t1, color: color),
            GlyphVertex(position: p2, texCoord: t2, color: color),
            GlyphVertex(position: p1, texCoord: t1, color: color),
            GlyphVertex(position: p3, texCoord: t3, color: color),
            GlyphVertex(position: p2, texCoord: t2, color: color),
        ]
    }

    private func makeColorCell(x0: Float, y0: Float, x1: Float, y1: Float, color: SIMD4<Float>) -> ColorCell {
        let position = SIMD2<Float>(x0, y0)
        let size = SIMD2<Float>(x1 - x0, y1 - y0)
        return ColorCell(position: position, size: size, color: color)
    }

    private func makeTextCell(x0: Float,
                              y0: Float,
                              x1: Float,
                              y1: Float,
                              u0: Float,
                              v0: Float,
                              u1: Float,
                              v1: Float,
                              color: SIMD4<Float>) -> TextCell {
        let position = SIMD2<Float>(x0, y0)
        let size = SIMD2<Float>(x1 - x0, y1 - y0)
        let texOrigin = SIMD2<Float>(u0, v0)
        let texSize = SIMD2<Float>(u1 - u0, v1 - v0)
        return TextCell(position: position,
                        size: size,
                        texOrigin: texOrigin,
                        texSize: texSize,
                        color: color)
    }

    /// Retains Metal buffers until the GPU completes their command buffer.
    ///
    /// The completion handler carries only this checked owner and a value ID.
    /// MTLBuffer references stay inside Locked storage and never enter the
    /// Sendable completion closure.
    final class MetalBufferRecycler: Sendable {
        private struct State {
            var available: [Int: [MTLBuffer]] = [:]
            var pending: [UInt64: [MTLBuffer]] = [:]
            var nextBatchID: UInt64 = 1
        }

        private let maxBuffersPerSize: Int
        private let state = Locked(State())

        init(maxBuffersPerSize: Int = 4) {
            precondition(maxBuffersPerSize > 0)
            self.maxBuffersPerSize = maxBuffersPerSize
        }

        func take(length: Int) -> MTLBuffer? {
            state.withLock { state in
                guard var bucket = state.available[length],
                      let buffer = bucket.popLast() else { return nil }
                state.available[length] = bucket
                return buffer
            }
        }

        func retainUntilCompletion(_ buffers: [MTLBuffer]) -> UInt64? {
            guard !buffers.isEmpty else { return nil }
            return state.withLock { state in
                let batchID = state.nextBatchID
                state.nextBatchID &+= 1
                precondition(state.nextBatchID != 0,
                             "Metal buffer batch identifier exhausted")
                state.pending[batchID] = buffers
                return batchID
            }
        }

        func complete(batchID: UInt64) {
            state.withLock { state in
                guard let buffers = state.pending.removeValue(forKey: batchID) else {
                    return
                }
                for buffer in buffers {
                    let length = buffer.length
                    var bucket = state.available[length, default: []]
                    if bucket.count < maxBuffersPerSize {
                        bucket.append(buffer)
                        state.available[length] = bucket
                    }
                }
            }
        }

        var pendingBatchCount: Int {
            state.withLock { $0.pending.count }
        }
    }

    private final class BufferPool {
        private let device: MTLDevice
        private let alignment = 256
        private let recycler = MetalBufferRecycler()
        private var frameBuffers: [MTLBuffer] = []

        init(device: MTLDevice) {
            self.device = device
        }

        func beginFrame() {
            frameBuffers.removeAll(keepingCapacity: true)
        }

        func makeBuffer<T>(_ vertices: [T]) -> MTLBuffer? {
            let byteCount = vertices.count * MemoryLayout<T>.stride
            guard byteCount > 0 else {
                return nil
            }
            let length = alignedLength(byteCount)
            guard let buffer = dequeue(length: length) else {
                return nil
            }
            _ = vertices.withUnsafeBytes { raw in
                memcpy(buffer.contents(), raw.baseAddress!, byteCount)
            }
            frameBuffers.append(buffer)
            return buffer
        }

        func commit(commandBuffer: MTLCommandBuffer) {
            let buffers = frameBuffers
            guard let batchID = recycler.retainUntilCompletion(buffers) else { return }
            let recycler = recycler
            commandBuffer.addCompletedHandler { _ in
                recycler.complete(batchID: batchID)
            }
        }

        private func alignedLength(_ length: Int) -> Int {
            // Round up to a coarse power-of-two size class. Exact-length
            // buckets never match again when the number of drawn cells
            // changes every frame (e.g. htop), so the pool would retain
            // up to maxBuffersPerSize buffers per distinct length and grow
            // without bound. Size classes keep the bucket count small and
            // make recycled buffers actually reusable.
            let aligned = ((length + alignment - 1) / alignment) * alignment
            let minimumClass = 4096
            if aligned <= minimumClass {
                return minimumClass
            }
            var size = minimumClass
            while size < aligned {
                size *= 2
            }
            return size
        }

        private func dequeue(length: Int) -> MTLBuffer? {
            if let buffer = recycler.take(length: length) {
                return buffer
            }
            return device.makeBuffer(length: length, options: .storageModeShared)
        }
    }

    private struct ShaperKey: Hashable {
        let fontName: String
        let fontSize: CGFloat
        let text: String
        /// Distinguishes host fallback fonts that share a PostScript name and
        /// size but are different fonts (for example after the host reloads
        /// its font and bumps the provider generation). 0 for ordinary runs.
        let fallbackTag: UInt64
    }

    private struct ShaperGlyphRun {
        let font: CTFont
        let glyphs: [CGGlyph]
        let positions: [CGPoint]
        let stringIndices: [CFIndex]
    }

    private struct ShaperRun {
        let glyphRuns: [ShaperGlyphRun]
        let positions: [CGPoint]
        let stringIndices: [CFIndex]
        let glyphCount: Int
    }

    private struct ShapedRun {
        let attributes: [NSAttributedString.Key: Any]
        let utf16Offset: Int
        let shaperRun: ShaperRun
    }

    private struct ShapedSegment {
        let segment: ViewLineSegment
        let runs: [ShapedRun]
    }

    private final class ShaperCache {
        private let maxEntries: Int
        private var cache: [ShaperKey: ShaperRun] = [:]
        private var order: [ShaperKey] = []

        init(maxEntries: Int) {
            self.maxEntries = maxEntries
        }

        func shape(text: String, font: CTFont, fallbackTag: UInt64 = 0) -> ShaperRun? {
            guard !text.isEmpty else {
                return nil
            }
            let key = ShaperKey(fontName: CTFontCopyPostScriptName(font) as String,
                                fontSize: CTFontGetSize(font),
                                text: text,
                                fallbackTag: fallbackTag)
            if let cached = cache[key] {
                return cached
            }

            // buildAttributedString supplies terminal cells in their final
            // screen order. Keep that order when CoreText shapes glyphs for
            // the Metal atlas; otherwise CoreText applies BiDi a second time.
            let writingDirectionKey = NSAttributedString.Key(kCTWritingDirectionAttributeName as String)
            let attributedString = NSAttributedString(string: text, attributes: [
                .font: font,
                writingDirectionKey: [NSNumber(value: 2)],
            ])
            let line = CTLineCreateWithAttributedString(attributedString)
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], !runs.isEmpty else {
                return nil
            }

            var glyphRuns: [ShaperGlyphRun] = []
            var positions: [CGPoint] = []
            var stringIndices: [CFIndex] = []
            for run in runs {
                let count = CTRunGetGlyphCount(run)
                if count == 0 {
                    continue
                }
                let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
                let runFont: CTFont = {
                    if let runFont = attributes[.font] as? TTFont {
                        return runFont as CTFont
                    }
                    return font
                }()
                let glyphs = [CGGlyph](unsafeUninitializedCapacity: count) { bufferPointer, countOut in
                    CTRunGetGlyphs(run, CFRange(), bufferPointer.baseAddress!)
                    countOut = count
                }
                var runPositions = [CGPoint](repeating: .zero, count: count)
                CTRunGetPositions(run, CFRange(), &runPositions)
                var runStringIndices = [CFIndex](repeating: 0, count: count)
                CTRunGetStringIndices(run, CFRange(), &runStringIndices)
                glyphRuns.append(ShaperGlyphRun(font: runFont,
                                                glyphs: glyphs,
                                                positions: runPositions,
                                                stringIndices: runStringIndices))
                positions.append(contentsOf: runPositions)
                stringIndices.append(contentsOf: runStringIndices)
            }

            let result = ShaperRun(glyphRuns: glyphRuns,
                                   positions: positions,
                                   stringIndices: stringIndices,
                                   glyphCount: positions.count)
            insert(key: key, run: result)
            return result
        }

        private func insert(key: ShaperKey, run: ShaperRun) {
            if cache[key] == nil {
                order.append(key)
            }
            cache[key] = run
            while order.count > maxEntries {
                let evicted = order.removeFirst()
                cache.removeValue(forKey: evicted)
            }
        }
    }

    @inline(__always)
    private func colorToSIMD(_ color: TTColor) -> SIMD4<Float> {
        colorSIMDCache.value(for: color)
    }

    private func makeBuffer<T>(_ vertices: [T]) -> MTLBuffer? {
        return bufferPool.makeBuffer(vertices)
    }

    private func makeStaticBuffer<T>(_ vertices: [T]) -> (MTLBuffer?, Int) {
        let count = vertices.count
        guard count > 0 else {
            return (nil, 0)
        }
        let byteCount = count * MemoryLayout<T>.stride
        guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
            return (nil, 0)
        }
        _ = vertices.withUnsafeBytes { raw in
            memcpy(buffer.contents(), raw.baseAddress!, byteCount)
        }
        return (buffer, count)
    }

    private func makeImageDrawBuffers(_ draws: [ImageDraw]) -> [ImageDrawBuffer] {
        guard !draws.isEmpty else {
            return []
        }
        var result: [ImageDrawBuffer] = []
        result.reserveCapacity(draws.count)
        for draw in draws {
            let (buffer, count) = makeStaticBuffer(draw.vertices)
            guard let buffer, count > 0 else {
                continue
            }
            result.append(ImageDrawBuffer(texture: draw.texture, buffer: buffer, vertexCount: count))
        }
        return result
    }

    private func makeRowBuffers(from data: RowDrawData) -> RowDrawBuffers {
        let (backgroundBuffer, backgroundCount) = makeStaticBuffer(data.backgroundCells)
        let (powerlineJoinBuffer, powerlineJoinCount) = makeStaticBuffer(data.powerlineJoinCells)
        let (glyphGrayBuffer, glyphGrayCount) = makeStaticBuffer(data.glyphCellsGray)
        let (glyphColorBuffer, glyphColorCount) = makeStaticBuffer(data.glyphCellsColor)
        let (decorationBuffer, decorationCount) = makeStaticBuffer(data.decorationCells)
        return RowDrawBuffers(backgroundBuffer: backgroundBuffer,
                              backgroundCount: backgroundCount,
                              powerlineJoinBuffer: powerlineJoinBuffer,
                              powerlineJoinCount: powerlineJoinCount,
                              glyphGrayBuffer: glyphGrayBuffer,
                              glyphGrayCount: glyphGrayCount,
                              glyphColorBuffer: glyphColorBuffer,
                              glyphColorCount: glyphColorCount,
                              decorationBuffer: decorationBuffer,
                              decorationCount: decorationCount,
                              belowBackgroundImageBuffers: makeImageDrawBuffers(
                                data.belowBackgroundImageDraws),
                              underImageBuffers: makeImageDrawBuffers(data.underImageDraws),
                              placeholderImageBuffers: makeImageDrawBuffers(data.placeholderImageDraws),
                              overImageBuffers: makeImageDrawBuffers(data.overImageDraws),
                              otherImageBuffers: makeImageDrawBuffers(data.otherImageDraws))
    }

    private func drawCellBuffer<T>(_ cells: [T],
                                   pipeline: MTLRenderPipelineState,
                                   texture: MTLTexture?,
                                   encoder: MTLRenderCommandEncoder,
                                   viewport: SIMD2<Float>) {
        guard !cells.isEmpty, let buffer = makeBuffer(cells) else {
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        var viewportVar = viewport
        encoder.setVertexBytes(&viewportVar, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        if let texture {
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cells.count * 6)
    }

    private func drawFrameData(_ frame: FrameDrawData, encoder: MTLRenderCommandEncoder, viewport: SIMD2<Float>) {
        drawImageBatches(frame.belowBackgroundImageDraws, encoder: encoder, viewport: viewport)

        drawCellBuffer(frame.backgroundCells,
                       pipeline: cellColorPipeline,
                       texture: nil,
                       encoder: encoder,
                       viewport: viewport)

        drawImageBatches(frame.underImageDraws, encoder: encoder, viewport: viewport)

        drawCellBuffer(frame.powerlineJoinCells,
                       pipeline: cellColorPipeline,
                       texture: nil,
                       encoder: encoder,
                       viewport: viewport)

        drawCellBuffer(frame.glyphCellsGray,
                       pipeline: cellTextGrayPipeline,
                       texture: grayscaleAtlas.texture,
                       encoder: encoder,
                       viewport: viewport)

        drawCellBuffer(frame.glyphCellsColor,
                       pipeline: cellTextPipeline,
                       texture: colorAtlas.texture,
                       encoder: encoder,
                       viewport: viewport)

        drawCellBuffer(frame.decorationCells,
                       pipeline: cellColorPipeline,
                       texture: nil,
                       encoder: encoder,
                       viewport: viewport)

        drawImageBatches(frame.placeholderImageDraws, encoder: encoder, viewport: viewport)
        drawImageBatches(frame.overImageDraws, encoder: encoder, viewport: viewport)
        drawImageBatches(frame.otherImageDraws, encoder: encoder, viewport: viewport)
    }

    private func drawImageBatches(_ draws: [ImageDraw], encoder: MTLRenderCommandEncoder, viewport: SIMD2<Float>) {
        guard !draws.isEmpty else {
            return
        }
        encoder.setRenderPipelineState(textPipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        var viewportVar = viewport
        encoder.setVertexBytes(&viewportVar, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        for draw in draws {
            guard let buffer = makeBuffer(draw.vertices) else {
                continue
            }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setFragmentTexture(draw.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: draw.vertices.count)
        }
    }

    private func drawVertexBuffers(rows: [RowDrawBuffers],
                                   bufferKey: KeyPath<RowDrawBuffers, MTLBuffer?>,
                                   countKey: KeyPath<RowDrawBuffers, Int>,
                                   pipeline: MTLRenderPipelineState,
                                   texture: MTLTexture?,
                                   encoder: MTLRenderCommandEncoder,
                                   viewport: SIMD2<Float>) {
        var hasAny = false
        for row in rows {
            if row[keyPath: bufferKey] != nil {
                hasAny = true
                break
            }
        }
        guard hasAny else {
            return
        }
        encoder.setRenderPipelineState(pipeline)
        var viewportVar = viewport
        encoder.setVertexBytes(&viewportVar, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        if let texture {
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
        }
        for row in rows {
            guard let buffer = row[keyPath: bufferKey] else {
                continue
            }
            let count = row[keyPath: countKey]
            if count == 0 {
                continue
            }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count * 6)
        }
    }

    private func drawImageRows(rows: [RowDrawBuffers],
                               imageKey: KeyPath<RowDrawBuffers, [ImageDrawBuffer]>,
                               encoder: MTLRenderCommandEncoder,
                               viewport: SIMD2<Float>) {
        var hasAny = false
        for row in rows {
            if !row[keyPath: imageKey].isEmpty {
                hasAny = true
                break
            }
        }
        guard hasAny else {
            return
        }
        encoder.setRenderPipelineState(textPipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        var viewportVar = viewport
        encoder.setVertexBytes(&viewportVar, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        for row in rows {
            for draw in row[keyPath: imageKey] {
                encoder.setVertexBuffer(draw.buffer, offset: 0, index: 0)
                encoder.setFragmentTexture(draw.texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: draw.vertexCount)
            }
        }
    }

    private func buildCursorDrawData(snapshot: TerminalSnapshot,
                                     context: SnapshotRenderContext,
                                     scale: CGFloat,
                                     cellWidth: CGFloat,
                                     cellHeight: CGFloat,
                                     yDisp: Int,
                                     firstRow: Int,
                                     lastRow: Int) -> (colorVertices: [ColorVertex],
                                                       glyphVerticesGray: [GlyphVertex],
                                                       glyphVerticesColor: [GlyphVertex]) {
        guard let cursor = snapshot.cursor, !cursor.hidden else {
            return ([], [], [])
        }
        let cursorRow = cursor.absoluteRow
        if cursorRow < firstRow || cursorRow > lastRow {
            return ([], [], [])
        }
        if cursor.visualCol < 0 || cursor.visualCol >= snapshot.cols {
            return ([], [], [])
        }
        let cursorStyle = snapshot.cursorStyle
        let hasFocus = context.cursorHasFocus
        let blinkOn = redrawState.cursorBlinkOn
        if hasFocus && isBlinkStyle(cursorStyle) && !blinkOn {
            return ([], [], [])
        }
        let lineOffset = cellHeight * CGFloat(cursorRow - yDisp + 1)
        let lineOrigin = CGPoint(x: 0, y: context.viewBounds.height - lineOffset)
        let lineOriginPx = CGPoint(x: lineOrigin.x * scale, y: lineOrigin.y * scale)
        let cellWidthPx = cellWidth * scale
        let cellHeightPx = cellHeight * scale
        let doublePosition: CGFloat = cursor.renderMode == .single ? 1.0 : 2.0
        // Span the cursor across the full character so a block/underline cursor
        // covers a full-width (CJK) glyph instead of only its left half, matching
        // the CoreGraphics caret.
        let cursorColumnWidth = CGFloat(cursor.columnWidth)

        let x0 = lineOriginPx.x + CGFloat(cursor.visualCol) * cellWidthPx * doublePosition
        let y0 = lineOriginPx.y
        let x1 = x0 + cellWidthPx * doublePosition * cursorColumnWidth
        let y1 = y0 + cellHeightPx

        let renderData = cursor.renderData
        let cursorColor = colorToSIMD(renderData.cursorColor)
        let cursorClip = ClipRect(minX: Float(x0), minY: Float(y0), maxX: Float(x1), maxY: Float(y1))
        var colorVertices: [ColorVertex] = []
        var glyphVerticesGray: [GlyphVertex] = []
        var glyphVerticesColor: [GlyphVertex] = []

        if !hasFocus {
            // Core Graphics centers its 3-point stroke on the cell boundary.
            // Clipping keeps only the inner half of that stroke.
            let stroke = max(1, 1.5 * scale)
            colorVertices.append(contentsOf: quadVertices(x0: CGFloat(x0),
                                                          y0: CGFloat(y0),
                                                          x1: CGFloat(x1),
                                                          y1: CGFloat(y0 + stroke),
                                                          color: cursorColor))
            colorVertices.append(contentsOf: quadVertices(x0: CGFloat(x0),
                                                          y0: CGFloat(y1 - stroke),
                                                          x1: CGFloat(x1),
                                                          y1: CGFloat(y1),
                                                          color: cursorColor))
            colorVertices.append(contentsOf: quadVertices(x0: CGFloat(x0),
                                                          y0: CGFloat(y0 + stroke),
                                                          x1: CGFloat(x0 + stroke),
                                                          y1: CGFloat(y1 - stroke),
                                                          color: cursorColor))
            colorVertices.append(contentsOf: quadVertices(x0: CGFloat(x1 - stroke),
                                                          y0: CGFloat(y0 + stroke),
                                                          x1: CGFloat(x1),
                                                          y1: CGFloat(y1 - stroke),
                                                          color: cursorColor))
            return (colorVertices, [], [])
        }

        switch cursorStyle {
        case .blinkBar, .steadyBar:
            let barWidth = max(1, 2 * scale)
            colorVertices.append(contentsOf: quadVertices(x0: CGFloat(x0),
                                                          y0: CGFloat(y0),
                                                          x1: CGFloat(x0 + barWidth),
                                                          y1: CGFloat(y1),
                                                          color: cursorColor))
            return (colorVertices, [], [])
        case .blinkUnderline, .steadyUnderline:
            let underlineHeight = max(1, 2 * scale)
            colorVertices.append(contentsOf: quadVertices(x0: CGFloat(x0),
                                                          y0: CGFloat(y0),
                                                          x1: CGFloat(x1),
                                                          y1: CGFloat(y0 + underlineHeight),
                                                          color: cursorColor))
            return (colorVertices, [], [])
        case .blinkBlock, .steadyBlock:
            colorVertices.append(contentsOf: quadVertices(x0: CGFloat(x0),
                                                          y0: CGFloat(y0),
                                                          x1: CGFloat(x1),
                                                          y1: CGFloat(y1),
                                                          color: cursorColor))
        }

        let caretTextColor = renderData.textColor
        if !snapshot.style.textBlinkVisible && renderData.cellAttribute.style.contains(.blink) {
            return (colorVertices, [], [])
        }
        if PowerlineRenderer.shouldRender(codePoint: UInt32(renderData.code),
                                          customGlyphsEnabled: renderData.customBlockGlyphs) {
            let cursorCellWidthPx = max(1, Int(round(cellWidthPx * doublePosition * cursorColumnWidth)))
            let cursorCellHeightPx = max(1, Int(round(cellHeightPx)))
            if let entry = customGlyphEntry(codePoint: UInt32(renderData.code),
                                            cellWidthPx: cursorCellWidthPx,
                                            cellHeightPx: cursorCellHeightPx,
                                            scale: scale,
                                            baseThicknessPx: 0,
                                            antiAlias: true) {
                let atlasSize = Float(grayscaleAtlas.size)
                let u0 = Float(entry.region.x) / atlasSize
                let v0 = Float(entry.region.y) / atlasSize
                let u1 = Float(entry.region.x + entry.region.width) / atlasSize
                let v1 = Float(entry.region.y + entry.region.height) / atlasSize
                let glyphX0 = Float(x0)
                let glyphY0 = Float(y0)
                let glyphX1 = glyphX0 + Float(entry.size.width)
                let glyphY1 = glyphY0 + Float(entry.size.height)
                if let clipped = self.clipRect(glyphX0, glyphY0, glyphX1, glyphY1,
                                               u0, v0, u1, v1, cursorClip) {
                    glyphVerticesGray.append(contentsOf: glyphQuadVertices(x0: clipped.x0,
                                                                           y0: clipped.y0,
                                                                           x1: clipped.x1,
                                                                           y1: clipped.y1,
                                                                           u0: clipped.u0,
                                                                           v0: clipped.v0,
                                                                           u1: clipped.u1,
                                                                           v1: clipped.v1,
                                                                           color: colorToSIMD(caretTextColor)))
                }
            }
            return (colorVertices, glyphVerticesGray, glyphVerticesColor)
        }
        let attributes = renderData.attributes.isEmpty
            ? [.font: renderData.normalFont] : renderData.attributes
        // A host glyph fallback carries an explicit font; appending a
        // variation selector would only fight it.
        let usesGlyphFallback = attributes[SwiftTermGlyphPolicyKey] != nil
        let attributedString = NSAttributedString(
            string: usesGlyphFallback ? String(renderData.character)
                                      : UnicodeUtil.textPresentationAdjusted(renderData.character),
            attributes: attributes)
        let ctline = CTLineCreateWithAttributedString(attributedString)
        guard let runs = CTLineGetGlyphRuns(ctline) as? [CTRun] else {
            return (colorVertices, [], [])
        }
        let yOffset = context.baselineOffset
        let textColorSIMD = colorToSIMD(caretTextColor)

        for run in runs {
            let runGlyphsCount = CTRunGetGlyphCount(run)
            if runGlyphsCount == 0 {
                continue
            }
            let runAttributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
            let runFont = runAttributes[.font] as? TTFont ?? renderData.normalFont
            let ctFont = runFont as CTFont
            let scaledFont = scaledFontFor(font: ctFont, scale: scale)
            let rasterFontToken = rasterFontToken(for: scaledFont)
            let fullFontToken = profileFullFontToken(rasterFont: scaledFont,
                                                     fittingFont: ctFont,
                                                     renderingScale: scale,
                                                     rasterFontToken: rasterFontToken)
            var metricsFont: GlyphMetricsFont?

            let runGlyphs = [CGGlyph](unsafeUninitializedCapacity: runGlyphsCount) { bufferPointer, count in
                CTRunGetGlyphs(run, CFRange(), bufferPointer.baseAddress!)
                count = runGlyphsCount
            }
            var coreTextPositions = [CGPoint](repeating: .zero, count: runGlyphsCount)
            CTRunGetPositions(run, CFRange(), &coreTextPositions)

            for i in 0..<runGlyphsCount {
                let glyph = runGlyphs[i]
                recordProfileGlyphIdentityAlias(fullFontToken: fullFontToken,
                                                rasterFontToken: rasterFontToken,
                                                glyph: glyph)
                guard let resolvedGlyph = glyphEntry(
                    rasterFontToken: rasterFontToken,
                    font: scaledFont,
                    fittingFont: ctFont,
                    renderingScale: scale,
                    metricsFont: &metricsFont,
                    glyph: glyph) else {
                    continue
                }
                let entry = resolvedGlyph.entry
                if entry.size.width <= 0 || entry.size.height <= 0 {
                    continue
                }
                let ctPos = coreTextPositions[i]
                // Center the glyph under the cursor the same way as normal text so
                // a full-width (CJK) character doesn't shift when the caret lands on it.
                let cursorGlyphPolicy = runAttributes[SwiftTermGlyphPolicyKey]
                    as? TerminalGlyphPlacementPolicy
                let fit = glyphSlotFit(resolvedGlyph: resolvedGlyph,
                                       glyph: glyph,
                                       columnWidth: cursor.columnWidth,
                                       cellDimension: context.cellDimension,
                                       baselineFromBottom: yOffset,
                                       font: scaledFont,
                                       fittingFont: ctFont,
                                       renderingScale: scale,
                                       metricsFont: &metricsFont,
                                       policy: cursorGlyphPolicy,
                                       iconHeight: cursorGlyphPolicy != nil
                                           ? CTFontGetAscent(context.fonts.normal as CTFont) * scale : 0)
                let basePos = CGPoint(x: lineOrigin.x + cellWidth * doublePosition * CGFloat(cursor.visualCol) + fit.dx * doublePosition,
                                      y: lineOrigin.y + yOffset + ctPos.y + fit.dy)
                let pxX = basePos.x * scale + entry.bearing.x * fit.scaleX
                let pxY = basePos.y * scale + entry.bearing.y * fit.scaleY
                let x0 = Float(pxX)
                let y0 = Float(pxY)
                let x1 = x0 + Float(entry.size.width * fit.scaleX)
                let y1 = y0 + Float(entry.size.height * fit.scaleY)

                let atlasSize = entry.atlasKind == .color ? colorAtlas.size : grayscaleAtlas.size
                let u0 = Float(entry.region.x) / Float(atlasSize)
                let v0 = Float(entry.region.y) / Float(atlasSize)
                let u1 = Float(entry.region.x + entry.region.width) / Float(atlasSize)
                let v1 = Float(entry.region.y + entry.region.height) / Float(atlasSize)

                let color = entry.isColor ? SIMD4<Float>(1, 1, 1, 1) : textColorSIMD
                if let clipped = self.clipRect(x0, y0, x1, y1, u0, v0, u1, v1, cursorClip) {
                    let vertices = glyphQuadVertices(x0: clipped.x0, y0: clipped.y0,
                                                     x1: clipped.x1, y1: clipped.y1,
                                                     u0: clipped.u0, v0: clipped.v0,
                                                     u1: clipped.u1, v1: clipped.v1,
                                                     color: color)
                    switch entry.atlasKind {
                    case .grayscale:
                        glyphVerticesGray.append(contentsOf: vertices)
                    case .color:
                        glyphVerticesColor.append(contentsOf: vertices)
                    }
                }
            }
        }

        return (colorVertices, glyphVerticesGray, glyphVerticesColor)
    }

    private func texture(for image: SnapshotImage) -> MTLTexture? {
        if let cached = imageTextureCache.object(forKey: image) {
            return cached
        }
        var texture: MTLTexture?
        if let cgImage = cgImage(from: image.image) {
            texture = try? textureLoader.newTexture(cgImage: cgImage, options: textureOptions())
        }
        #if os(macOS)
        if texture == nil, let data = image.image.tiffRepresentation {
            texture = try? textureLoader.newTexture(data: data, options: textureOptions())
        }
        #else
        if texture == nil, let data = image.image.pngData() {
            texture = try? textureLoader.newTexture(data: data, options: textureOptions())
        }
        #endif
        if let texture {
            imageTextureCache.setObject(texture, forKey: image)
        } else {
#if DEBUG
            let key = ObjectIdentifier(image)
            if !imageTextureFailures.contains(key) {
                imageTextureFailures.insert(key)
                print("Metal: failed to create texture for image size=\(image.image.size)")
            }
#endif
        }
        return texture
    }

    private func kittyTexture(
        imageId: UInt32,
        renderSnapshot: KittyGraphicsRenderSnapshot
    ) -> MTLTexture? {
        guard let image = renderSnapshot.imagesById[imageId] else { return nil }
        let signature = KittyImageSignature(
            kind: 2,
            width: image.width,
            height: image.height,
            byteCount: image.rgba.count,
            headHash: UInt32(truncatingIfNeeded: image.contentGeneration))
        if let cached = kittyTextureCache[imageId], cached.signature == signature {
            return cached.texture
        }
        guard let texture = textureFromRGBA(
            bytes: image.rgba, width: image.width, height: image.height) else {
#if DEBUG
            if kittyTextureFailures.insert(imageId).inserted {
                print("Metal: failed to create Kitty texture id=\(imageId) size=\(image.width)x\(image.height) bytes=\(image.rgba.count)")
            }
#endif
            return nil
        }
        kittyTextureCache[imageId] = (signature, texture)
#if DEBUG
        kittyTextureFailures.remove(imageId)
#endif
        return texture
    }

    private func hashBytes(_ data: Data, limit: Int) -> UInt32 {
        let count = min(limit, data.count)
        if count == 0 {
            return 0
        }
        var hash: UInt32 = 2166136261
        for byte in data.prefix(count) {
            hash ^= UInt32(byte)
            hash &*= 16777619
        }
        return hash
    }

    private func textureFromRGBA(bytes: [UInt8], width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        // Kitty RGBA rows start at the top of the image. The image textures
        // loaded through MTKTextureLoader use a bottom-left origin, which is
        // also what the terminal image quads expect. Reverse the Kitty rows so
        // both texture paths have the same origin.
        let premultiplied = Self.kittyPremultipliedRGBA(
            bytes, width: width, height: height, flipVertically: true)
        let region = MTLRegionMake2D(0, 0, width, height)
        texture.replace(
            region: region,
            mipmapLevel: 0,
            withBytes: premultiplied,
            bytesPerRow: width * 4)
        return texture
    }

    static func kittyPremultipliedRGBA(
        _ bytes: [UInt8],
        width: Int? = nil,
        height: Int? = nil,
        flipVertically: Bool = false
    ) -> [UInt8] {
        let flipWidth = width ?? 0
        let flipHeight = height ?? 0
        let canFlip = flipVertically && flipWidth > 0 && flipHeight > 1
            && flipWidth * flipHeight * 4 == bytes.count
        var result = canFlip
            ? [UInt8](repeating: 0, count: bytes.count)
            : bytes
        var index = 0
        let rowBytes = flipWidth * 4
        while index + 3 < bytes.count {
            let destination: Int
            if canFlip {
                let row = index / rowBytes
                let columnByte = index % rowBytes
                destination = (flipHeight - 1 - row) * rowBytes + columnByte
            } else {
                destination = index
            }
            let alpha = Int(bytes[index + 3])
            result[destination] = UInt8((Int(bytes[index]) * alpha + 127) / 255)
            result[destination + 1] = UInt8((Int(bytes[index + 1]) * alpha + 127) / 255)
            result[destination + 2] = UInt8((Int(bytes[index + 2]) * alpha + 127) / 255)
            result[destination + 3] = bytes[index + 3]
            index += 4
        }
        return result
    }

    private func cgImage(from image: TTImage) -> CGImage? {
        #if os(macOS)
        var rect = CGRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return cgImage
        }
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else {
            return nil
        }
        return bitmap.cgImage
        #else
        return image.cgImage
        #endif
    }

    private func textureOptions() -> [MTKTextureLoader.Option: Any] {
        return [
            .SRGB: false,
            .origin: MTKTextureLoader.Origin.bottomLeft
        ]
    }

    private func imageDraw(texture: MTLTexture,
                           rect: CGRect,
                           uvRect: CGRect,
                           renderMode: BufferLine.RenderLineMode,
                           clipRect: ClipRect?,
                           pivotY: CGFloat,
                           scale: CGFloat) -> ImageDraw? {
        let x0 = rect.minX * scale
        let y0 = rect.minY * scale
        let x1 = rect.maxX * scale
        let y1 = rect.maxY * scale
        let (tx0, ty0, tx1, ty1) = transformImageRect(x0: x0, y0: y0, x1: x1, y1: y1, renderMode: renderMode, pivotY: pivotY)
        let u0 = Float(uvRect.minX)
        let v0 = Float(uvRect.minY)
        let u1 = Float(uvRect.maxX)
        let v1 = Float(uvRect.maxY)
        guard let clipped = self.clipRect(tx0, ty0, tx1, ty1, u0, v0, u1, v1, clipRect) else {
            return nil
        }
        let vertices = glyphQuadVertices(x0: clipped.x0, y0: clipped.y0, x1: clipped.x1, y1: clipped.y1,
                                         u0: clipped.u0, v0: clipped.v0, u1: clipped.u1, v1: clipped.v1,
                                         color: SIMD4<Float>(1, 1, 1, 1))
        return ImageDraw(texture: texture, vertices: vertices)
    }

    private func clipRect(_ x0: Float,
                          _ y0: Float,
                          _ x1: Float,
                          _ y1: Float,
                          _ clip: ClipRect?) -> (Float, Float, Float, Float)? {
        guard let clip = clip else {
            return (x0, y0, x1, y1)
        }
        let minX = max(x0, clip.minX)
        let minY = max(y0, clip.minY)
        let maxX = min(x1, clip.maxX)
        let maxY = min(y1, clip.maxY)
        if minX >= maxX || minY >= maxY {
            return nil
        }
        return (minX, minY, maxX, maxY)
    }

    private func clipRect(_ x0: Float,
                          _ y0: Float,
                          _ x1: Float,
                          _ y1: Float,
                          _ u0: Float,
                          _ v0: Float,
                          _ u1: Float,
                          _ v1: Float,
                          _ clip: ClipRect?) -> (x0: Float, y0: Float, x1: Float, y1: Float,
                                                 u0: Float, v0: Float, u1: Float, v1: Float)? {
        guard let clip = clip else {
            return (x0: x0, y0: y0, x1: x1, y1: y1, u0: u0, v0: v0, u1: u1, v1: v1)
        }
        let width = x1 - x0
        let height = y1 - y0
        if width <= 0 || height <= 0 {
            return nil
        }
        let minX = max(x0, clip.minX)
        let minY = max(y0, clip.minY)
        let maxX = min(x1, clip.maxX)
        let maxY = min(y1, clip.maxY)
        if minX >= maxX || minY >= maxY {
            return nil
        }
        let du = u1 - u0
        let dv = v1 - v0
        let newU0 = u0 + (minX - x0) / width * du
        let newU1 = u0 + (maxX - x0) / width * du
        let newV0 = v0 + (minY - y0) / height * dv
        let newV1 = v0 + (maxY - y0) / height * dv
        return (x0: minX, y0: minY, x1: maxX, y1: maxY,
                u0: newU0, v0: newV0, u1: newU1, v1: newV1)
    }

    private func transformImageRect(x0: CGFloat,
                                    y0: CGFloat,
                                    x1: CGFloat,
                                    y1: CGFloat,
                                    renderMode: BufferLine.RenderLineMode,
                                    pivotY: CGFloat) -> (Float, Float, Float, Float) {
        func transformPoint(_ point: CGPoint) -> CGPoint {
            switch renderMode {
            case .single:
                return point
            case .doubleWidth:
                return CGPoint(x: point.x * 2, y: point.y)
            case .doubledDown, .doubledTop:
                return CGPoint(x: point.x * 2, y: pivotY + (point.y - pivotY) * 2)
            }
        }
        let p0 = transformPoint(CGPoint(x: x0, y: y0))
        let p1 = transformPoint(CGPoint(x: x1, y: y1))
        let minX = min(p0.x, p1.x)
        let minY = min(p0.y, p1.y)
        let maxX = max(p0.x, p1.x)
        let maxY = max(p0.y, p1.y)
        return (Float(minX), Float(minY), Float(maxX), Float(maxY))
    }

    static func kittyVirtualImageGeometry(
        source: KittyGraphicsPixelRect,
        textureWidth: Int,
        textureHeight: Int,
        placementRect: CGRect,
        cellRect: CGRect,
        scale: CGFloat
    ) -> (imageRect: CGRect, visibleRect: CGRect, uvRect: CGRect)? {
        guard source.width > 0, source.height > 0,
              textureWidth > 0, textureHeight > 0, scale > 0 else { return nil }
        let imageSize = CGSize(
            width: CGFloat(source.width) / scale,
            height: CGFloat(source.height) / scale)
        let imageRect = kittyAspectFitRect(imageSize: imageSize, in: placementRect)
        let visible = imageRect.intersection(cellRect)
        guard !visible.isEmpty, imageRect.width > 0, imageRect.height > 0 else { return nil }

        let localU0 = (visible.minX - imageRect.minX) / imageRect.width
        let localV0 = (visible.minY - imageRect.minY) / imageRect.height
        let localU1 = (visible.maxX - imageRect.minX) / imageRect.width
        let localV1 = (visible.maxY - imageRect.minY) / imageRect.height
        let sourceWidth = CGFloat(source.width)
        let sourceHeight = CGFloat(source.height)
        let textureWidth = CGFloat(textureWidth)
        let textureHeight = CGFloat(textureHeight)
        let u0 = (CGFloat(source.x) + localU0 * sourceWidth) / textureWidth
        // The upload reverses Kitty's top-first rows to the Metal texture's
        // bottom-left origin. The bottom of the source crop is therefore the
        // first V coordinate for the bottom of the placement rectangle.
        let sourceBottom = textureHeight - CGFloat(source.y + source.height)
        let v0 = (sourceBottom + localV0 * sourceHeight) / textureHeight
        let u1 = (CGFloat(source.x) + localU1 * sourceWidth) / textureWidth
        let v1 = (sourceBottom + localV1 * sourceHeight) / textureHeight
        return (
            imageRect,
            visible,
            CGRect(x: u0, y: v0, width: u1 - u0, height: v1 - v0))
    }

    private static func kittyAspectFitRect(imageSize: CGSize, in rect: CGRect) -> CGRect {
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

    private func appendUnderlineSegments(x0: CGFloat,
                                         x1: CGFloat,
                                         yCenter: CGFloat,
                                         thickness: CGFloat,
                                         color: SIMD4<Float>,
                                         style: UnderlineStyle,
                                         patternScale: CGFloat,
                                         renderMode: BufferLine.RenderLineMode,
                                         clipRect: ClipRect?,
                                         pivotY: CGFloat,
                                         output: inout [ColorCell]) {
        let half = thickness / 2
        let baseY = yCenter
        let dashLength = max(thickness * 2, patternScale * 2)
        let dotLength = max(thickness, patternScale)

        func emitSegment(start: CGFloat, end: CGFloat, centerY: CGFloat) {
            let y0 = centerY - half
            let y1 = centerY + half
            let rects = transformUnderlineRect(x0: start, x1: end, y0: y0, y1: y1, renderMode: renderMode, pivotY: pivotY)
            if let clipped = self.clipRect(rects.0, rects.1, rects.2, rects.3, clipRect) {
                output.append(makeColorCell(x0: clipped.0,
                                            y0: clipped.1,
                                            x1: clipped.2,
                                            y1: clipped.3,
                                            color: color))
            }
        }

        switch style {
        case .curly:
            let amplitude = max(thickness, patternScale)
            let wavelength = max(thickness * 4, patternScale * 4)
            let step = max(thickness, patternScale)
            var x = x0
            while x < x1 {
                let phase = Double((x - x0) / wavelength * (CGFloat.pi * 2))
                let y = baseY + amplitude * CGFloat(sin(phase))
                let end = min(x + step, x1)
                emitSegment(start: x, end: end, centerY: y)
                x = end
            }
        case .dotted, .dashed:
            let segmentLength = style == .dotted ? dotLength : dashLength
            let gapLength = style == .dotted ? (dotLength * 2) : dashLength
            var start = x0
            while start < x1 {
                let end = min(start + segmentLength, x1)
                emitSegment(start: start, end: end, centerY: baseY)
                start += segmentLength + gapLength
            }
        case .none:
            break
        case .double, .single:
            emitSegment(start: x0, end: x1, centerY: baseY)
        }
    }

    private func resolveUnderlineStyle(_ attributes: [NSAttributedString.Key: Any]) -> UnderlineStyle {
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

    private func transformUnderlineRect(x0: CGFloat,
                                        x1: CGFloat,
                                        y0: CGFloat,
                                        y1: CGFloat,
                                        renderMode: BufferLine.RenderLineMode,
                                        pivotY: CGFloat) -> (Float, Float, Float, Float) {
        func transformPoint(_ point: CGPoint) -> CGPoint {
            switch renderMode {
            case .single:
                return point
            case .doubleWidth:
                return CGPoint(x: point.x * 2, y: point.y)
            case .doubledDown, .doubledTop:
                return CGPoint(x: point.x * 2, y: pivotY + (point.y - pivotY) * 2)
            }
        }
        let p0 = transformPoint(CGPoint(x: x0, y: y0))
        let p1 = transformPoint(CGPoint(x: x1, y: y1))
        let minX = min(p0.x, p1.x)
        let minY = min(p0.y, p1.y)
        let maxX = max(p0.x, p1.x)
        let maxY = max(p0.y, p1.y)
        return (Float(minX), Float(minY), Float(maxX), Float(maxY))
    }

    private static func makeTextPipeline(device: MTLDevice,
                                         library: MTLLibrary,
                                         pixelFormat: MTLPixelFormat,
                                         vertexName: String,
                                         fragmentName: String) -> MTLRenderPipelineState? {
        guard let vertex = library.makeFunction(name: vertexName),
              let fragment = library.makeFunction(name: fragmentName) else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makeColorPipeline(device: MTLDevice,
                                          library: MTLLibrary,
                                          pixelFormat: MTLPixelFormat,
                                          vertexName: String,
                                          fragmentName: String) -> MTLRenderPipelineState? {
        guard let vertex = library.makeFunction(name: vertexName),
              let fragment = library.makeFunction(name: fragmentName) else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func isBlinkStyle(_ style: CursorStyle) -> Bool {
        switch style {
        case .blinkBlock, .blinkUnderline, .blinkBar:
            return true
        case .steadyBlock, .steadyUnderline, .steadyBar:
            return false
        }
    }

    /// Starts or stops the cursor blink.
    ///
    /// Called from `render()`, which runs on the render loop under WO-F4. A
    /// `Timer` scheduled there would attach to a run loop that never runs, so
    /// the cursor would simply stop blinking. A main-actor controller owns the
    /// timer, while checked redraw state carries the current value between the
    /// timer and render threads. A steady frame schedules no main-actor work.
    private func updateCursorBlinkTimer(shouldBlink: Bool) {
        let changed = redrawState.setCursorBlinkWanted(shouldBlink)
        guard changed else { return }

        let controller = cursorBlinkController
        Task { @MainActor in
            controller.apply(shouldBlink: shouldBlink)
        }
    }

    private func pruneKittyTextureCache(kitty: SnapshotKitty) {
        let liveIds = kitty.renderSnapshot.imagesById
        if kittyTextureCache.isEmpty {
            return
        }
        let staleIds = kittyTextureCache.keys.filter { liveIds[$0] == nil }
        if staleIds.isEmpty {
            return
        }
        for imageId in staleIds {
            kittyTextureCache.removeValue(forKey: imageId)
#if DEBUG
            kittyTextureFailures.remove(imageId)
#endif
        }
    }

    /// Whether a shader library can be built here at all.
    ///
    /// Exposed for tests that optionally exercise Metal. Cheap and cached —
    /// building the library once is the only honest way to answer this.
    static let shaderLibraryIsAvailable: Bool = {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return (try? makeLibrary(device: device)) != nil
    }()

    private static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        if let library = device.makeDefaultLibrary(),
           libraryHasRequiredFunctions(library) {
            return library
        }
        if let url = findMetallibURL() {
            do {
                let library = try device.makeLibrary(URL: url)
                if libraryHasRequiredFunctions(library) {
                    return library
                }
            } catch {
                throw MetalError.shaderLibraryLoadFailed(String(describing: error))
            }
        }
        guard let source = loadShaderSource() else {
            throw MetalError.shaderSourceMissing("Apple/Metal/Shaders.metal")
        }
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            if libraryHasRequiredFunctions(library) {
                return library
            }
            throw MetalError.shaderFunctionMissing(requiredShaderFunctions().joined(separator: ", "))
        } catch let error as MetalError {
            throw error
        } catch {
            throw MetalError.shaderCompilationFailed(String(describing: error))
        }
    }

    private static func libraryHasRequiredFunctions(_ library: MTLLibrary) -> Bool {
        for name in requiredShaderFunctions() {
            if library.makeFunction(name: name) == nil {
                return false
            }
        }
        return true
    }

    private static func requiredShaderFunctions() -> [String] {
        return [
            "terminal_text_vertex",
            "terminal_cell_text_vertex",
            "terminal_text_fragment",
            "terminal_text_fragment_gray",
            "terminal_color_vertex",
            "terminal_cell_color_vertex",
            "terminal_color_fragment"
        ]
    }

    private static func loadShaderSource() -> String? {
        for bundle in candidateBundles() {
            if let url = bundle.url(forResource: "Shaders", withExtension: "metal"),
               let source = try? String(contentsOf: url, encoding: .utf8) {
                return source
            }
        }
        return nil
    }

    private static func findMetallibURL() -> URL? {
        for bundle in candidateBundles() {
            if let url = bundle.url(forResource: "default", withExtension: "metallib") {
                return url
            }
            if let resourceURL = bundle.resourceURL,
               let urls = try? FileManager.default.contentsOfDirectory(at: resourceURL,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles]) {
                if let match = urls.first(where: { $0.pathExtension == "metallib" }) {
                    return match
                }
            }
        }
        return nil
    }

    private static func candidateBundles() -> [Bundle] {
        var bundles: [Bundle] = []
        #if SWIFT_PACKAGE
        // Deliberately not `Bundle.module`: SwiftPM's generated accessor for
        // executable targets calls `fatalError` (aborting the whole process,
        // not throwing) instead of returning nil when it can't locate
        // `SwiftTerm_SwiftTerm.bundle`. Its only two candidates are
        // `Bundle.main.bundleURL` (the .app's *root*, not `Contents/Resources`
        // where a packaged .app actually puts SwiftPM resource bundles) and
        // the build machine's absolute `.build/.../SwiftTerm_SwiftTerm.bundle`
        // path baked into the binary at compile time. That means any app that
        // bundles this package and ships the resource bundle correctly still
        // crashes the instant Metal rendering is requested on a machine other
        // than the one that built it. Probe for the same bundle name
        // ourselves — mirroring the accessor's own main-bundle-relative
        // lookup, plus the `Contents/Resources` location it misses — so a
        // missing bundle falls through to the next candidate instead of
        // aborting the process.
        let bundleName = "SwiftTerm_SwiftTerm.bundle"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(bundleName),
           let resourceBundle = Bundle(url: url) {
            bundles.append(resourceBundle)
        }
        if let url = Bundle.main.bundleURL.appendingPathComponent(bundleName) as URL?,
           let resourceBundle = Bundle(url: url) {
            bundles.append(resourceBundle)
        }
        // SwiftPM puts resources beside the .xctest bundle, which may be
        // loaded by a separate runner. Never search arbitrary app siblings.
        for bundle in [Bundle.main, Bundle(for: MetalTerminalRenderer.self)]
            where bundle.bundleURL.pathExtension == "xctest" {
            let url = bundle.bundleURL.deletingLastPathComponent()
                .appendingPathComponent(bundleName)
            if let resourceBundle = Bundle(url: url) {
                bundles.append(resourceBundle)
            }
        }
        #endif
        bundles.append(Bundle(for: MetalTerminalRenderer.self))
        bundles.append(Bundle.main)
        return bundles
    }
}
#endif
