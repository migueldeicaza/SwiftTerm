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
        SnapshotRenderContext(view: view, style: .empty,
                              ansiColors: view.getTerminal().ansiColors, cols: 80)
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

    /// The important one: a new context invalidates the cache. Without this a
    /// palette or font change would keep rendering with the old colors.
    @Test func newContextInvalidatesTheCache() {
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

    /// Every context is distinct, so a stale entry cannot survive one.
    @Test func contextIdentityIsUnique() {
        let view = makeView()
        let builder = makeBuilder()
        var seen = Set<UInt64>()
        for _ in 0..<50 {
            seen.insert(makeContext(view).identity)
        }
        #expect(seen.count == 50)
    }
}
#endif
