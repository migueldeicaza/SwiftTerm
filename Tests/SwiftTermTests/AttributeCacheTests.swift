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

    private func makeContext(_ view: TerminalView) -> SnapshotRenderContext {
        SnapshotRenderContext(viewState: FrameViewState(view: view), style: .empty,
                              ansiColors: view.withTerminal { $0.ansiColors }, cols: 80)
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
