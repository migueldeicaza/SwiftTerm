//
//  GlyphFallbackTests.swift
//  SwiftTermTests
//
//  Covers the host glyph-fallback hook: candidate selection against the
//  requested face, run batching, style stability, cache invalidation, and
//  caret parity.
//

import Foundation
import Testing
@testable import SwiftTerm

#if os(macOS)
import AppKit

/// A provider that claims a configurable scalar set and hands out one stable
/// font instance, the way the contract requires.
private final class MockFallbackProvider: TerminalGlyphFallbackProvider, @unchecked Sendable {
    var claimed: Set<UInt32>
    var policy: TerminalGlyphPlacementPolicy
    var generation: UInt64 = 1
    let font: NSFont

    init (claiming scalars: Set<UInt32>,
          policy: TerminalGlyphPlacementPolicy = TerminalGlyphPlacementPolicy(placement: .icon)) {
        claimed = scalars
        self.policy = policy
        font = NSFont(name: "Apple Symbols", size: 12)
            ?? NSFont(name: "Zapf Dingbats", size: 12)
            ?? NSFont.systemFont(ofSize: 12)
    }

    func placementPolicy (for scalar: Unicode.Scalar) -> TerminalGlyphPlacementPolicy? {
        claimed.contains(scalar.value) ? policy : nil
    }

    func fallbackFont (forPointSize size: CGFloat) -> CTFont? {
        font as CTFont
    }
}

@Suite("GlyphFallback")
@MainActor
struct GlyphFallbackTests {
    /// A Nerd Font codepoint the default monospaced system font does not have.
    static let nerdIcon: UInt32 = 0xEA61

    private func makeView (cols: Int = 12, rows: Int = 4) -> TerminalView {
        TerminalView(frame: .zero, font: nil,
                     options: TerminalOptions(cols: cols, rows: rows, scrollback: 20))
    }

    private func renderFirstRow (_ view: TerminalView) throws -> ViewLineInfo {
        let snapshot = TerminalSnapshot()
        view.withTerminal { terminal in
            _ = snapshot.refresh(terminal: terminal, viewState: FrameViewState(view: view),
                                 selection: SnapshotSelectionState(selection: view.selection),
                                 deferBidiTypesetting: false)
        }
        let row = try #require(snapshot.rows.first)
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view),
                                            snapshot: snapshot)
        return view.textBuilder.buildAttributedString(row: row,
                                                      absoluteRow: snapshot.firstRow,
                                                      context: context)
    }

    private func attributes (at index: Int, in info: ViewLineInfo)
        -> [NSAttributedString.Key: Any]
    {
        let joined = NSMutableAttributedString()
        for segment in info.segments {
            joined.append(segment.attributedString)
        }
        return joined.attributes(at: index, effectiveRange: nil)
    }

    // MARK: Resolver primitives

    @Test func baseScalarAcceptsSingleAndVariationSelector() {
        #expect(GlyphFallbackResolver.baseScalar(of: "\u{EA61}")?.value == Self.nerdIcon)
        #expect(GlyphFallbackResolver.baseScalar(of: "\u{2665}\u{FE0E}")?.value == 0x2665)
        #expect(GlyphFallbackResolver.baseScalar(of: "A")?.value == 0x41)
        // Multi-scalar clusters that are not base+VS are never candidates.
        #expect(GlyphFallbackResolver.baseScalar(of: "🇺🇸") == nil)
        #expect(GlyphFallbackResolver.baseScalar(of: "e\u{301}") == nil)
    }

    @Test func fontHasGlyphIsADirectQuery() {
        let menlo = NSFont(name: "Menlo", size: 12)!
        #expect(GlyphFallbackResolver.fontHasGlyph(menlo, scalar: "A"))
        #expect(!GlyphFallbackResolver.fontHasGlyph(menlo, scalar: Unicode.Scalar(Self.nerdIcon)!))
        // Supplementary-plane scalars go through as surrogate pairs.
        let emoji = NSFont(name: "Apple Color Emoji", size: 12)!
        #expect(GlyphFallbackResolver.fontHasGlyph(emoji, scalar: "\u{1F600}"))
        #expect(!GlyphFallbackResolver.fontHasGlyph(menlo, scalar: "\u{F0001}"))
    }

    // MARK: Selection

    @Test func claimedMissingScalarUsesFallbackFont() throws {
        let view = makeView()
        let provider = MockFallbackProvider(claiming: [Self.nerdIcon])
        view.glyphFallbackProvider = provider
        view.feed(text: "\u{EA61}")

        let info = try renderFirstRow(view)
        let attrs = attributes(at: 0, in: info)
        #expect((attrs[.font] as? NSFont) === provider.font)
        #expect(attrs[SwiftTermGlyphPolicyKey] as? TerminalGlyphPlacementPolicy == provider.policy)
        // No text-presentation selector is appended to a fallback run.
        let scalars = info.segments.first?.attributedString.string.unicodeScalars
        #expect(scalars?.first?.value == Self.nerdIcon)
        #expect(scalars?.contains { $0.value == 0xFE0E } == false)
    }

    @Test func primaryFontKeepsPriority() throws {
        let view = makeView()
        let provider = MockFallbackProvider(claiming: [0x41]) // "A", which the primary has
        view.glyphFallbackProvider = provider
        view.feed(text: "A")

        let attrs = attributes(at: 0, in: try renderFirstRow(view))
        #expect((attrs[.font] as? NSFont) !== provider.font)
        #expect(attrs[SwiftTermGlyphPolicyKey] == nil)
    }

    @Test func unclaimedPrivateUseScalarIsUntouched() throws {
        let view = makeView()
        view.glyphFallbackProvider = MockFallbackProvider(claiming: [Self.nerdIcon])
        view.feed(text: "\u{E999}")

        let attrs = attributes(at: 0, in: try renderFirstRow(view))
        #expect(attrs[SwiftTermGlyphPolicyKey] == nil)
    }

    @Test func nilProviderLeavesOutputUnchanged() throws {
        let plainView = makeView()
        plainView.feed(text: "\u{EA61}x")
        let baseline = try renderFirstRow(plainView)
        let baselineAttrs = attributes(at: 0, in: baseline)
        #expect(baselineAttrs[SwiftTermGlyphPolicyKey] == nil)
        #expect((baselineAttrs[.font] as? NSFont) === plainView.font)
    }

    @Test func boldItalicCellsUseRegularFallbackFaceAndKeepDecorations() throws {
        let view = makeView()
        let provider = MockFallbackProvider(claiming: [Self.nerdIcon])
        view.glyphFallbackProvider = provider
        view.feed(text: "\u{1b}[1;3;4;31m\u{EA61}")

        let attrs = attributes(at: 0, in: try renderFirstRow(view))
        // The fallback face is the provider's regular face for every style.
        #expect((attrs[.font] as? NSFont) === provider.font)
        #expect(attrs[.underlineStyle] != nil)
        let red = attrs[.foregroundColor] as? NSColor

        // Same SGR on a plain cell: the fallback must not change the color
        // mapping (bold maps ANSI 31 to the bright variant in both cases).
        let plainView = makeView()
        plainView.feed(text: "\u{1b}[1;31mx")
        let plainRed = attributes(at: 0, in: try renderFirstRow(plainView))[.foregroundColor] as? NSColor
        #expect(red == plainRed)
    }

    @Test func consecutiveIconsBatchAndBoundariesFlush() throws {
        let view = makeView()
        let provider = MockFallbackProvider(claiming: [Self.nerdIcon])
        view.glyphFallbackProvider = provider
        view.feed(text: "\u{EA61}\u{EA61}x")

        let info = try renderFirstRow(view)
        let joined = NSMutableAttributedString()
        for segment in info.segments {
            joined.append(segment.attributedString)
        }
        var range = NSRange()
        let first = joined.attributes(at: 0, effectiveRange: &range)
        #expect((first[.font] as? NSFont) === provider.font)
        #expect(range.length == 2)
        let after = joined.attributes(at: 2, effectiveRange: nil)
        #expect((after[.font] as? NSFont) !== provider.font)
        #expect(after[SwiftTermGlyphPolicyKey] == nil)
        // Column bookkeeping: every cell contributed exactly one UTF-16 unit.
        #expect(info.segments.allSatisfy { $0.utf16IsCellIdentity })
    }

    // MARK: Placement policy fit

    /// Synthetic metrics: cell 10x20, baseline 4 from the bottom, primary-font
    /// icon height 14.
    private func policyFit (ink: CGRect, placement: TerminalGlyphPlacementPolicy.Placement,
                            columnWidth: Int = 1, maximumCellWidth: Int? = nil,
                            relativeBounds: CGRect? = nil) -> GlyphSlotFit {
        let metrics = GlyphMetrics(inkBounds: ink, horizontalAdvance: ink.width,
                                   fontSize: 12, fitInkSizeScale: 1)
        let policy = TerminalGlyphPlacementPolicy(placement: placement,
                                                  maximumCellWidth: maximumCellWidth,
                                                  relativeBounds: relativeBounds)
        return GlyphSlotFit.calculate(metrics: metrics, policy: policy,
                                      columnWidth: columnWidth,
                                      cellDimension: CGSize(width: 10, height: 20),
                                      baselineFromBottom: 4,
                                      iconHeight: 14,
                                      renderingScale: 1)
    }

    @Test func oneColumnIconIsLimitedToIconHeightAndCentered() {
        let fit = policyFit(ink: CGRect(x: 0, y: -2, width: 8, height: 30), placement: .icon)
        #expect(abs(fit.scale - 14.0 / 30.0) < 0.001)
        // Vertically centered: scaled ink center lands on the cell's midline.
        let inkCenterFromBaseline = (-2 + 15) * fit.scale
        #expect(abs(fit.dy - (10 - 4 - inkCenterFromBaseline)) < 0.001)
    }

    @Test func fittingIconIsNeverUpscaledAndIsCentered() {
        let fit = policyFit(ink: CGRect(x: 1, y: 0, width: 6, height: 10), placement: .icon)
        #expect(fit.scale == 1)
        #expect(abs(fit.dx - 1) < 0.001)  // (10 - 6) / 2 minus the ink origin of 1
        #expect(abs(fit.dy - 1) < 0.001)  // midline 10, baseline 4, ink center 5
    }

    @Test func coverIgnoresTheIconHeightLimit() {
        let icon = policyFit(ink: CGRect(x: 0, y: 0, width: 10, height: 18), placement: .icon)
        #expect(abs(icon.scale - 14.0 / 18.0) < 0.001)
        let cover = policyFit(ink: CGRect(x: 0, y: 0, width: 10, height: 18), placement: .cover)
        #expect(cover.scale == 1)
    }

    @Test func coverEnlargesASmallGlyphToFillTheSlot() {
        // Unlike icon, cover may upscale: min(10/5, 20/8) = 2.
        let fit = policyFit(ink: CGRect(x: 0, y: 0, width: 5, height: 8), placement: .cover)
        #expect(abs(fit.scale - 2) < 0.001)
        #expect(fit.isUniform)
    }

    @Test func stretchFillsBothAxesExactly() {
        let fit = policyFit(ink: CGRect(x: 0, y: 2, width: 5, height: 8), placement: .stretch)
        #expect(abs(fit.scaleX - 2) < 0.001)      // 10 / 5
        #expect(abs(fit.scaleY - 2.5) < 0.001)    // 20 / 8
        // The scaled box spans the whole slot, so no horizontal centering slack.
        #expect(abs(fit.dx) < 0.001)
    }

    @Test func twoColumnIconUsesItsFullSlot() {
        let fit = policyFit(ink: CGRect(x: 0, y: 0, width: 18, height: 16),
                            placement: .icon, columnWidth: 2)
        // 18 fits inside 2 cells (20) and the icon-height limit is one-column only.
        #expect(fit.scale == 1)
        #expect(abs(fit.dx - 1) < 0.001)
    }

    @Test func maximumCellWidthCapsTheSlot() {
        let fit = policyFit(ink: CGRect(x: 0, y: 0, width: 18, height: 10),
                            placement: .explicitWidth, columnWidth: 2, maximumCellWidth: 1)
        #expect(abs(fit.scale - 10.0 / 18.0) < 0.001)
    }

    @Test func groupedGlyphsShareTheGroupFrame() {
        // Two group members whose ink differs but whose relative bounds place
        // them in the same virtual box must get the same scale.
        let tall = policyFit(ink: CGRect(x: 0, y: 0, width: 8, height: 24),
                             placement: .grouped, columnWidth: 1,
                             relativeBounds: CGRect(x: 0, y: 0, width: 1, height: 1))
        let short = policyFit(ink: CGRect(x: 0, y: 0, width: 8, height: 12),
                              placement: .grouped, columnWidth: 1,
                              relativeBounds: CGRect(x: 0, y: 0, width: 1, height: 0.5))
        #expect(abs(tall.scale - short.scale) < 0.001)
    }

    // MARK: Cache invalidation

    @Test func providerGenerationIsPartOfContextIdentity() {
        let view = makeView()
        let provider = MockFallbackProvider(claiming: [Self.nerdIcon])

        let bareContext = SnapshotRenderContext(viewState: FrameViewState(view: view),
                                                style: .empty,
                                                ansiColors: view.withTerminal { $0.ansiColors },
                                                cols: 80)
        view.glyphFallbackProvider = provider
        let withProvider = SnapshotRenderContext(viewState: FrameViewState(view: view),
                                                 style: .empty,
                                                 ansiColors: view.withTerminal { $0.ansiColors },
                                                 cols: 80)
        #expect(bareContext.identity != withProvider.identity)

        provider.generation += 1
        let bumped = SnapshotRenderContext(viewState: FrameViewState(view: view),
                                           style: .empty,
                                           ansiColors: view.withTerminal { $0.ansiColors },
                                           cols: 80)
        #expect(withProvider.identity != bumped.identity)
    }

    // MARK: Caret

    @Test func caretOverAnIconCarriesTheFallbackFont() throws {
        let view = makeView()
        let provider = MockFallbackProvider(claiming: [Self.nerdIcon])
        view.glyphFallbackProvider = provider
        view.feed(text: "\u{EA61}\u{1b}[1D")

        let snapshot = TerminalSnapshot()
        view.withTerminal { terminal in
            _ = snapshot.refresh(terminal: terminal, viewState: FrameViewState(view: view),
                                 selection: SnapshotSelectionState(selection: view.selection),
                                 deferBidiTypesetting: false)
        }
        let renderData = try #require(snapshot.cursor?.renderData)
        #expect((renderData.attributes[.font] as? NSFont) === provider.font)
        #expect(renderData.attributes[SwiftTermGlyphPolicyKey] != nil)
    }
}
#endif
