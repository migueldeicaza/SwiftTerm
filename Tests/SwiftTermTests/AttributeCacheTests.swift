//
//  AttributeCacheTests.swift
//  SwiftTermTests
//
//  Covers the attribute-dictionary cache added after a Time Profiler trace
//  showed `[NSAttributedString.Key: Any]` rebuilds dominating the main thread.
//

import Foundation
import Testing
@testable import SwiftTerm

#if os(macOS)
import AppKit

@Suite("AttributeCache")
@MainActor
struct AttributeCacheTests {
    private func makeView() -> TerminalView {
        TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
    }

    /// A renderer-owned builder, matching how the real render paths use it.
    private func makeBuilder() -> SnapshotTextBuilder {
        SnapshotTextBuilder()
    }

    private func makeContext(_ view: TerminalView, cols: Int = 80,
                             rows: Int = 1) -> SnapshotRenderContext {
        SnapshotRenderContext(viewState: FrameViewState(view: view), style: .empty,
                              ansiColors: view.withTerminal { $0.ansiColors }, cols: cols, rows: rows)
    }

    /// Repeated lookups within one context must return equal dictionaries, and
    /// the second lookup must come from the cache.
    @Test func repeatedLookupsAreStableWithinAContext() {
        let view = makeView()
        let builder = makeBuilder()
        let context = makeContext(view)
        let attribute = Attribute(fg: .defaultColor, bg: .defaultColor, style: .none)

        let first = builder.getAttributes(attribute, withUrl: false, context: context)
        #expect(first != nil)
        #expect(builder.attributeCache.count == 1)

        let second = builder.getAttributes(attribute, withUrl: false, context: context)
        #expect(builder.attributeCache.count == 1)
        #expect((first?[.foregroundColor] as? TTColor) == (second?[.foregroundColor] as? TTColor))
        #expect(first?.objectiveC === second?.objectiveC)
    }

    @Test func segmentBuilderUsesCachedFoundationAttributes() throws {
        let view = makeView()
        let builder = makeBuilder()
        let context = makeContext(view)
        let cached = try #require(builder.getAttributes(
            Attribute(fg: .ansi256(code: 1), bg: .ansi256(code: 2), style: .bold),
            withUrl: false,
            context: context))
        var segmentBuilder = TerminalView.ViewLineSegmentBuilder(column: 3, columnWidth: 1)

        segmentBuilder.append(text: "A", attributes: cached, cellUTF16Lengths: [1])
        segmentBuilder.append(text: "e\u{301}", attributes: cached, cellUTF16Lengths: [2])

        let segment = try #require(segmentBuilder.buildIfNeeded())
        #expect(segment.attributedString.string == "Ae\u{301}")
        #expect(segment.attributedString.attribute(.font, at: 0, effectiveRange: nil) != nil)
        #expect(segment.attributedString.attribute(.foregroundColor, at: 2,
                                                    effectiveRange: nil) != nil)
        #expect(segment.utf16ToCellOrdinal == [0, 1, 1])
    }

    /// The URL flag must not collide with the plain entry: a linked run is
    /// underlined and a plain one is not.
    @Test func urlFlagIsPartOfTheKey() {
        let view = makeView()
        let builder = makeBuilder()
        let context = makeContext(view)
        let attribute = Attribute(fg: .defaultColor, bg: .defaultColor, style: .none)

        let plain = builder.getAttributes(attribute, withUrl: false, context: context)
        let linked = builder.getAttributes(attribute, withUrl: true, context: context)
        #expect(builder.attributeCache.count == 2)
        #expect(plain?[.underlineStyle] == nil)
        #expect(linked?[.underlineStyle] != nil)
    }

    /// Distinct attributes must not share an entry.
    @Test func distinctAttributesGetDistinctEntries() {
        let view = makeView()
        let builder = makeBuilder()
        let context = makeContext(view)

        _ = builder.getAttributes(Attribute(fg: .ansi256(code: 1), bg: .defaultColor, style: .none),
                               withUrl: false, context: context)
        _ = builder.getAttributes(Attribute(fg: .ansi256(code: 2), bg: .defaultColor, style: .none),
                               withUrl: false, context: context)
        #expect(builder.attributeCache.count == 2)
    }

    /// Styles disappear from the screen while the render context stays the
    /// same. Their dictionaries must eventually leave the cache as well.
    @Test(arguments: [false, true])
    func attributeCacheReleasesOldStyles(withUrl: Bool) {
        let builder = SnapshotTextBuilder(attributeCacheCapacity: 8)
        let context = makeContext(makeView(), cols: 1)
        weak var firstDictionary: NSDictionary?

        for value in 0..<12 {
            autoreleasepool {
                let attribute = Attribute(
                    fg: .trueColor(red: UInt8(value >> 8),
                                   green: UInt8(value & 0xff), blue: 37),
                    bg: .defaultColor, style: .none)
                let attributes = builder.getAttributes(attribute, withUrl: withUrl,
                                                       context: context)
                if value == 0 {
                    firstDictionary = attributes?.objectiveC
                    #expect(firstDictionary != nil)
                }
            }
        }

        #expect(builder.attributeCache.count <= 8)
        #expect(firstDictionary == nil)
    }

    /// Blank truecolor backgrounds use inline packed keys, so their variety
    /// is not limited by the arena's interned style table. Repaint one cell
    /// repeatedly to exercise the actual packed rendering path.
    @Test func packedAttributeCacheStaysBoundedAcrossBackgroundChanges() {
        let builder = SnapshotTextBuilder(attributeCacheCapacity: 8)
        let context = makeContext(makeView(), cols: 1)
        let line = BufferLine(cols: 1)
        let row = TerminalSnapshot.Row(source: line, borrowing: true)
        var maximumCachedAttributes = 0

        for value in 0..<12 {
            autoreleasepool {
                let background = Attribute.Color.trueColor(
                    red: UInt8(value >> 8), green: UInt8(value & 0xff), blue: 37)
                line.fill(with: CharData(
                    attribute: Attribute(fg: .defaultColor, bg: background, style: .none),
                    code: 0))
                let rendered = builder.buildAttributedString(row: row, absoluteRow: 0,
                                                              context: context)
                let color = rendered.segments.first?.attributedString.attribute(
                    .backgroundColor, at: 0, effectiveRange: nil) as? NSColor
                #expect(color == NSColor.make(red: CGFloat(value >> 8) / 255,
                                               green: CGFloat(value & 0xff) / 255,
                                               blue: 37.0 / 255, alpha: 1))
                maximumCachedAttributes = max(maximumCachedAttributes,
                                              builder.packedAttributeCacheCount)
            }
        }

        #expect(maximumCachedAttributes > 0)
        #expect(maximumCachedAttributes <= 8)
    }

    @Test(arguments: [false, true])
    func largeGridKeepsAttributeCacheWarm(withUrl: Bool) throws {
        let view = makeView()
        let builder = makeBuilder()
        let context = makeContext(view, cols: 100, rows: 42)
        let attributes = (0..<4_200).map { value in
            Attribute(fg: .trueColor(red: UInt8(value >> 8),
                                     green: UInt8(value & 0xff), blue: 37),
                      bg: .defaultColor, style: .none)
        }
        let firstPass = try attributes.map {
            try #require(builder.getAttributes($0, withUrl: withUrl, context: context))
        }
        let nextFrame = makeContext(view, cols: 100, rows: 42)
        #expect(nextFrame.identity == context.identity)
        for (attribute, first) in zip(attributes, firstPass) {
            let second = try #require(builder.getAttributes(
                attribute, withUrl: withUrl, context: nextFrame))
            #expect(first.objectiveC === second.objectiveC)
        }
        #expect(builder.attributeCache.count == attributes.count)
    }

    @Test func largeGridKeepsPackedAttributeCacheWarm() throws {
        let view = makeView()
        let builder = SnapshotTextBuilder(trueColorCacheCapacity: 1)
        let arena = CellArena()
        let rows = (0..<42).map { row in
            let line = BufferLine(cols: 100, arena: arena)
            for col in 0..<100 {
                let value = row * 100 + col
                line[col] = CharData(attribute: Attribute(
                    fg: .defaultColor,
                    bg: .trueColor(red: UInt8(value >> 8),
                                   green: UInt8(value & 0xff), blue: 37), style: .none), code: 0)
            }
            return TerminalSnapshot.Row(source: line, borrowing: true)
        }
        var firstPass: [NSColor] = []
        for pass in 0..<2 {
            let context = makeContext(view, cols: 100, rows: rows.count)
            for (index, row) in rows.enumerated() {
                let rendered = builder.buildAttributedString(row: row, absoluteRow: index,
                                                              context: context)
                let text = try #require(rendered.segments.first?.attributedString)
                for col in 0..<100 {
                    let color = try #require(text.attribute(
                        .backgroundColor, at: col, effectiveRange: nil) as? NSColor)
                    if pass == 0 {
                        firstPass.append(color)
                    } else {
                        // The one-entry color cache cannot hide an attribute-cache miss.
                        #expect(color === firstPass[index * 100 + col])
                    }
                }
            }
            #expect(builder.packedAttributeCacheCount == 4_200)
        }
    }

    @Test func gridResizeUpdatesAttributeCacheCapacity() {
        let view = makeView()
        let builder = SnapshotTextBuilder(attributeCacheCapacity: 2)
        for rows in [2, 1] {
            let context = makeContext(view, cols: 1, rows: rows)
            for value in 0..<4 {
                _ = builder.getAttributes(
                    Attribute(fg: .ansi256(code: UInt8(value)), bg: .defaultColor, style: .none),
                    withUrl: false, context: context)
            }
            #expect(builder.attributeCache.count == 2 * rows)
        }
    }

    /// A visual-input change invalidates the cache. Without this a palette or
    /// font change would keep rendering with the old colors.
    @Test func changedVisualInputsInvalidateTheCache() {
        let view = makeView()
        let builder = makeBuilder()
        let attribute = Attribute(fg: .defaultColor, bg: .defaultColor, style: .none)

        view.nativeForegroundColor = NSColor.red
        let firstContext = makeContext(view)
        let before = builder.getAttributes(attribute, withUrl: false, context: firstContext)
        #expect(builder.attributeCache.count == 1)

        view.nativeForegroundColor = NSColor.green
        let secondContext = makeContext(view)
        #expect(secondContext.identity != firstContext.identity)

        let after = builder.getAttributes(attribute, withUrl: false, context: secondContext)
        // Cache was cleared, so only the new entry remains.
        #expect(builder.attributeCache.count == 1)
        #expect(builder.attributeCacheContextID == secondContext.identity)

        let beforeColor = before?[.foregroundColor] as? TTColor
        let afterColor = after?[.foregroundColor] as? TTColor
        #expect(beforeColor != nil && afterColor != nil)
        #expect(beforeColor != afterColor)
    }

    /// A new frame with unchanged visual inputs must keep the cache warm.
    @Test func contextIdentityIsStable() {
        let view = makeView()
        let builder = makeBuilder()
        let attribute = Attribute(fg: .defaultColor, bg: .defaultColor, style: .none)
        let firstContext = makeContext(view)
        _ = builder.getAttributes(attribute, withUrl: false, context: firstContext)
        let secondContext = makeContext(view)

        #expect(secondContext.identity == firstContext.identity)
        _ = builder.getAttributes(attribute, withUrl: false, context: secondContext)
        #expect(builder.attributeCache.count == 1)
    }

    @Test func trueColorsAreInternedAcrossAttributeRoles() {
        let view = makeView()
        let builder = makeBuilder()
        let context = makeContext(view)
        let color = Attribute.Color.trueColor(red: 17, green: 34, blue: 51)

        let foreground = builder.getAttributes(
            Attribute(fg: color, bg: .defaultInvertedColor, style: .none),
            withUrl: false, context: context)?[.foregroundColor] as? TTColor
        let background = builder.getAttributes(
            Attribute(fg: .defaultColor, bg: color, style: .none),
            withUrl: false, context: context)?[.backgroundColor] as? TTColor

        #expect(foreground != nil)
        #expect(background != nil)
        #expect(foreground === background)
        #expect(builder.trueColorCacheCount == 1)
    }

    @Test func trueColorInternCacheClearsAtItsBound() {
        let view = makeView()
        let builder = SnapshotTextBuilder(trueColorCacheCapacity: 2)
        let context = makeContext(view)

        _ = builder.mapColor(color: .trueColor(red: 1, green: 2, blue: 3),
                             isFg: true, isBold: false, context: context)
        _ = builder.mapColor(color: .trueColor(red: 4, green: 5, blue: 6),
                             isFg: true, isBold: false, context: context)
        #expect(builder.trueColorCacheCount == 2)

        _ = builder.mapColor(color: .trueColor(red: 7, green: 8, blue: 9),
                             isFg: true, isBold: false, context: context)
        #expect(builder.trueColorCacheCount == 1)
    }

    @Test func metalColorConversionIsStableAndBounded() {
        let first = TTColor.make(red: 17.0 / 255, green: 34.0 / 255,
                                 blue: 51.0 / 255, alpha: 1)
        let equal = TTColor.make(red: 17.0 / 255, green: 34.0 / 255,
                                 blue: 51.0 / 255, alpha: 1)
        let cache = MetalColorSIMDCache(maxEntries: 2)

        #expect(cache.value(for: first) == cache.value(for: equal))
        _ = cache.value(for: TTColor.make(red: 0, green: 1, blue: 0, alpha: 1))
        _ = cache.value(for: TTColor.make(red: 0, green: 0, blue: 1, alpha: 1))
        #expect(cache.count <= cache.maxEntries)
    }

    @Test func renderContextIdentityTracksEffectiveAppearanceColors() {
        let dynamic = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .white : .black
        }
        let view = makeView()
        view.nativeForegroundColor = dynamic
        view.appearance = NSAppearance(named: .aqua)
        let light = makeContext(view)

        view.appearance = NSAppearance(named: .darkAqua)
        let dark = makeContext(view)

        #expect(light.identity != dark.identity)
        #expect(light.effectiveForegroundColor != dark.effectiveForegroundColor)
    }

#if DEBUG
    @Test func unchangedFrameCaptureReusesFontsAndAppearance() {
        let view = makeView()
        _ = FrameViewState(view: view)
        let fontRebuilds = view.frameCaptureCache.fontRebuildCount
        let appearanceRebuilds = view.frameCaptureCache.appearanceRebuildCount

        _ = FrameViewState(view: view)
        #expect(view.frameCaptureCache.fontRebuildCount == fontRebuilds)
        #expect(view.frameCaptureCache.appearanceRebuildCount == appearanceRebuilds)

        view.font = NSFont.monospacedSystemFont(
            ofSize: view.font.pointSize + 1, weight: .regular)
        _ = FrameViewState(view: view)
        #expect(view.frameCaptureCache.fontRebuildCount == fontRebuilds + 1)

        view.selectedTextBackgroundColor = .red
        _ = FrameViewState(view: view)
        #expect(view.frameCaptureCache.appearanceRebuildCount == appearanceRebuilds + 1)
    }

    @Test func snapshotReusesNativeColorConversions() {
        let view = makeView()
        let snapshot = TerminalSnapshot()
        let state = FrameViewState(view: view)
        view.withTerminal { terminal in
            _ = snapshot.refresh(
                terminal: terminal,
                viewState: state,
                selection: SnapshotSelectionState(selection: view.selection))
        }
        let rebuilds = snapshot.nativeColorRebuildCount

        _ = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: snapshot)
        #expect(snapshot.nativeColorRebuildCount == rebuilds)

        view.selectedTextForegroundColor = .red
        _ = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: snapshot)
        #expect(snapshot.nativeColorRebuildCount == rebuilds + 1)
    }
#endif
}
#endif
