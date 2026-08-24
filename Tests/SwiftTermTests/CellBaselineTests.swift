#if os(macOS)
import AppKit
import CoreText
import Testing
@testable import SwiftTerm

/// `CellGeometry.baselineOffset` is the single definition of where a glyph's
/// baseline sits inside its cell. Every renderer reads it, so these tests pin
/// the two properties the renderers depend on: it does not move at
/// `lineSpacing == 1`, and above 1 it centers the natural line in the cell.
@MainActor
final class CellBaselineTests {
    private static let fonts: [(name: String, size: CGFloat)] = [
        ("Monaco", 10), ("Monaco", 12), ("Monaco", 13.5), ("Monaco", 24),
        ("Menlo", 11), ("Menlo", 14), ("SF Mono", 12), ("Courier", 13),
    ]

    private func classicOffset (_ font: NSFont) -> CGFloat {
        ceil(CTFontGetDescent(font) + CTFontGetLeading(font))
    }

    /// The offset every renderer used before line spacing was distributed. Any
    /// change here at the default spacing is a visible regression for every
    /// user who never touches `lineSpacing`.
    @Test func defaultSpacingKeepsTheClassicBaseline() throws {
        for spec in Self.fonts {
            guard let font = NSFont(name: spec.name, size: spec.size) else { continue }
            let view = TerminalView(frame: .zero, font: font)
            #expect(view.lineSpacing == 1)
            #expect(view.baselineOffset == classicOffset(font),
                    "\(spec.name) \(spec.size)pt moved at lineSpacing == 1")
        }
    }

    /// A cell a point or two taller than the font's natural line — which
    /// pixel-grid snapping alone can produce on a fractional backing scale —
    /// must not shift the baseline either: there is no whole point to give the
    /// glyph, and half-point baselines are what blur text.
    @Test func extraUnderTwoPointsDoesNotMoveTheBaseline() throws {
        let font = try #require(NSFont(name: "Monaco", size: 12))
        let natural = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        for extra in [-4.0, 0.0, 0.01, 0.5, 0.999, 1.0, 1.5, 1.999] as [CGFloat] {
            #expect(CellGeometry.baselineOffset(normalFont: font, cellHeight: natural + extra)
                    == classicOffset(font),
                    "extra of \(extra)pt should be left where it is")
        }
        // Two whole points is the first split worth making: one each side.
        #expect(CellGeometry.baselineOffset(normalFont: font, cellHeight: natural + 2)
                == classicOffset(font) + 1)
    }

    /// The baseline rises by whole points only, and never past the point where
    /// the ascender would be pushed out of the cell.
    @Test func baselineRisesInWholePointsAndStaysInTheCell() throws {
        let font = try #require(NSFont(name: "Monaco", size: 12))
        let natural = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        var previous = classicOffset(font)
        for extra in stride(from: CGFloat(0), through: 40, by: 0.5) {
            let offset = CellGeometry.baselineOffset(normalFont: font, cellHeight: natural + extra)
            #expect(offset == offset.rounded(), "baseline landed off the pixel grid at \(extra)")
            #expect(offset >= previous, "baseline moved backwards at \(extra)")
            #expect(offset + CTFontGetAscent(font) <= natural + extra,
                    "ascender pushed out of the cell at \(extra)")
            previous = offset
        }
    }

    /// Above 1 the extra height is split evenly, so the font's natural line
    /// ends up centered in the taller cell rather than pinned to its top.
    @Test func extraSpacingIsSplitEvenlyAboveAndBelow() throws {
        let font = try #require(NSFont(name: "Monaco", size: 12))
        let natural = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))

        for spacing in [1.2, 1.4, 1.6, 2.0] as [CGFloat] {
            let view = TerminalView(frame: .zero, font: font)
            view.lineSpacing = spacing
            let cellHeight = view.cellDimension.height
            let extra = cellHeight - natural
            try #require(extra >= 1, "lineSpacing \(spacing) should add real height")

            let offset = view.baselineOffset
            // Space under the descender vs. over the ascender: the whole point
            // of the change is that these are within a rounding step, instead
            // of all of the slack sitting above the text.
            let below = offset - CTFontGetDescent(font) - CTFontGetLeading(font)
            let above = cellHeight - offset - CTFontGetAscent(font)
            #expect(abs(above - below) <= 1,
                    "lineSpacing \(spacing): \(below)pt below vs \(above)pt above")
            #expect(offset > classicOffset(font))
            #expect(offset < cellHeight - CTFontGetAscent(font) + 1)
        }
    }

    /// The caret, the CoreGraphics path, and the Metal path all position text
    /// from the frame's snapshot context. If that disagrees with the view the
    /// glyph inside the block cursor sits on a different baseline than the row
    /// it covers — the divergence this consolidation removes.
    @Test func snapshotContextAgreesWithTheView() throws {
        let font = try #require(NSFont(name: "Monaco", size: 13))
        for spacing in [1.0, 1.3, 1.6] as [CGFloat] {
            let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), font: font)
            view.lineSpacing = spacing
            #expect(CellGeometry.baselineOffset(normalFont: view.fontSet.normal,
                                                cellHeight: view.cellDimension.height)
                    == view.baselineOffset,
                    "lineSpacing \(spacing): snapshot geometry diverged from the view")
        }
    }
}
#endif
