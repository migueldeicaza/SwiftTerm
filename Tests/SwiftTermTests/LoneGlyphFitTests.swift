//
//  LoneGlyphFitTests.swift
//
//  Issue #827: a glyph that the width table puts in one column, but that the
//  font draws wider than the cell, must stay inside its cell. The column
//  count does not change; only the drawing is fitted to the cell.
//
#if os(macOS)
import AppKit
import CoreText
import Testing

@testable import SwiftTerm

struct LoneGlyphFitTests {
    /// D2Coding at 13 pt: the cell is 6.5 pt wide.
    private static let cell: CGFloat = 6.5

    private func metrics(advance: CGFloat, inkX: CGFloat, inkWidth: CGFloat,
                         inkY: CGFloat = -1, inkHeight: CGFloat = 10) -> GlyphMetrics {
        GlyphMetrics(inkBounds: CGRect(x: inkX, y: inkY, width: inkWidth, height: inkHeight),
                     horizontalAdvance: advance,
                     fontSize: 13,
                     fitInkSizeScale: 1)
    }

    /// The ink of the fitted glyph, in the cell's coordinates.
    private func fittedInk(_ m: GlyphMetrics, _ fit: GlyphSlotFit) -> ClosedRange<CGFloat> {
        let ink = m.inkBounds
        return (fit.dx + ink.minX * fit.scale)...(fit.dx + ink.maxX * fit.scale)
    }

    @Test func glyphThatFitsTheCellIsUnchanged() {
        let m = metrics(advance: Self.cell, inkX: 0.5, inkWidth: 5.5)
        #expect(GlyphSlotFit.fitLoneGlyphToCell(metrics: m, cellWidth: Self.cell,
                                                renderingScale: 1, edgeInset: 0).isIdentity)
    }

    /// A wide advance with ink that is already inside the cell paints
    /// nothing over the next cell, so it is not moved.
    @Test func wideAdvanceWithInkInsideTheCellIsUnchanged() {
        let m = metrics(advance: 2 * Self.cell, inkX: 0.5, inkWidth: 5)
        #expect(GlyphSlotFit.fitLoneGlyphToCell(metrics: m, cellWidth: Self.cell,
                                                renderingScale: 1, edgeInset: 0).isIdentity)
    }

    /// D2Coding U+2460 `①`: a 2-cell advance with ink about 1.75 cells wide.
    /// The ink sets the scale, so the glyph is larger than the 0.5 that the
    /// advance would give, and it is inside the cell.
    @Test func wideInkIsScaledToTheCellNotToTheAdvance() {
        let m = metrics(advance: 2 * Self.cell, inkX: 0.8, inkWidth: 11.4)
        let fit = GlyphSlotFit.fitLoneGlyphToCell(metrics: m, cellWidth: Self.cell,
                                                  renderingScale: 1, edgeInset: 0)
        #expect(abs(fit.scale - Self.cell / 11.4) < 0.0001)
        #expect(fit.scale > 0.5)
        let ink = fittedInk(m, fit)
        #expect(ink.lowerBound >= -0.0001)
        #expect(ink.upperBound <= Self.cell + 0.0001)
        // The ink keeps its vertical center: (midY * scale) + dy == midY.
        #expect(abs(m.inkBounds.midY * fit.scale + fit.dy - m.inkBounds.midY) < 0.0001)
    }

    /// D2Coding U+02BC `ʼ`: narrow ink centered in a 2-cell advance, so it
    /// starts at the right edge of the first cell. It is moved into the cell
    /// at full size.
    @Test func narrowInkOffTheCellIsMovedNotScaled() {
        let m = metrics(advance: 2 * Self.cell, inkX: 5.68, inkWidth: 1.62)
        let fit = GlyphSlotFit.fitLoneGlyphToCell(metrics: m, cellWidth: Self.cell,
                                                  renderingScale: 1, edgeInset: 0)
        #expect(fit.scale == 1)
        #expect(fit.dy == 0)
        let ink = fittedInk(m, fit)
        #expect(ink.lowerBound >= 0)
        #expect(ink.upperBound <= Self.cell)
        // Centered as the font centered it in its own advance box.
        #expect(abs((ink.lowerBound + ink.upperBound) / 2 - Self.cell / 2) < 0.05)
    }

    /// A fitted glyph keeps its ink one device pixel from each cell edge, so
    /// antialiasing does not reach the next cell.
    @Test func fittedInkKeepsTheEdgeInset() {
        let inset: CGFloat = 0.5
        for m in [metrics(advance: 2 * Self.cell, inkX: 0.8, inkWidth: 11.4),
                  metrics(advance: 2 * Self.cell, inkX: 5.68, inkWidth: 1.62)] {
            let fit = GlyphSlotFit.fitLoneGlyphToCell(metrics: m, cellWidth: Self.cell,
                                                      renderingScale: 1, edgeInset: inset)
            let ink = fittedInk(m, fit)
            #expect(ink.lowerBound >= inset - 0.0001)
            #expect(ink.upperBound <= Self.cell - inset + 0.0001)
        }
    }

    /// The Metal path measures in pixels and applies offsets in points.
    @Test func renderingScaleGivesTheSameFitInPoints() {
        let points = metrics(advance: 2 * Self.cell, inkX: 0.8, inkWidth: 11.4)
        let pixels = GlyphMetrics(inkBounds: points.inkBounds.applying(.init(scaleX: 2, y: 2)),
                                  horizontalAdvance: points.horizontalAdvance * 2,
                                  fontSize: 26, fitInkSizeScale: 1)
        let a = GlyphSlotFit.fitLoneGlyphToCell(metrics: points, cellWidth: Self.cell, renderingScale: 1, edgeInset: 0.5)
        let b = GlyphSlotFit.fitLoneGlyphToCell(metrics: pixels, cellWidth: Self.cell, renderingScale: 2, edgeInset: 1)
        #expect(abs(a.scale - b.scale) < 0.0001)
        #expect(abs(a.dx - b.dx) < 0.0001)
        #expect(abs(a.dy - b.dy) < 0.0001)
    }

    @Test func monospacedFontHasNoOverflowSet() throws {
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, 13, nil)
        try #require((CTFontCopyPostScriptName(font) as String) == "Menlo-Regular")
        #expect(OverflowGlyphSet(font: font, cellWidth: OverflowGlyphSet.cellAdvance(of: font)) == nil)
    }

    /// Courier draws a few one-column symbols wider than its cell.
    @Test func overflowSetHasOnlyTheWideGlyphs() throws {
        let font = CTFontCreateWithName("Courier" as CFString, 13, nil)
        try #require((CTFontCopyPostScriptName(font) as String) == "Courier")
        let set = try #require(OverflowGlyphSet(font: font, cellWidth: OverflowGlyphSet.cellAdvance(of: font)))
        func glyph(_ scalar: UniChar) -> CGGlyph {
            var c = [scalar]; var g: [CGGlyph] = [0]
            _ = CTFontGetGlyphsForCharacters(font, &c, &g, 1)
            return g[0]
        }
        #expect(set.contains(glyph(0x220F)))    // ∏
        #expect(!set.contains(glyph(0x41)))     // A
        #expect(!set.contains(glyph(0x57)))     // W
    }

    @MainActor
    @Test func frameFontSetReportsHowEachFontIsFitted() throws {
        let menlo = try #require(NSFont(name: "Menlo-Regular", size: 13))
        let menloFonts = FrameFontSet(TerminalView.FontSet(font: menlo))
        #expect(menloFonts.loneGlyphFitting(for: menloFonts.normal).isNone)
        let fallback = CTFontCreateWithName("LucidaGrande" as CFString, 13, nil)
        guard case .fallback = menloFonts.loneGlyphFitting(for: fallback) else {
            Issue.record("a font outside the set must use the fallback fit")
            return
        }

        let courier = try #require(NSFont(name: "Courier", size: 13))
        let courierFonts = FrameFontSet(TerminalView.FontSet(font: courier))
        guard case .overflowing = courierFonts.loneGlyphFitting(for: courierFonts.normal) else {
            Issue.record("Courier has glyphs wider than its cell")
            return
        }
    }
}
#endif
