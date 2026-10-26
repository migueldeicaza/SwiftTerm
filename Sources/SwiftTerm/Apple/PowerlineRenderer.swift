#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics
import Foundation

/// Cell-aligned rendering for the Powerline and Powerline-Extra separators
/// used by prompts (powerlevel10k, Starship, Oh My Posh).
///
/// Font glyphs are deliberately not used here: their antialiased outline can
/// land between the terminal's pixel-aligned background cells and expose a
/// seam.  These shapes share the cell grid with the background renderer and
/// extend only their joining edge by one physical pixel.
///
/// Covered code points (Nerd Fonts `pl`/`ple` set):
/// - U+E0B0–U+E0B3 solid and thin triangles
/// - U+E0B4–U+E0B7 solid and thin half circles
/// - U+E0B8–U+E0BF slanted half-cell triangles and thin diagonals
/// - U+E0C0–U+E0C3 solid and thin flames
/// - U+E0D6–U+E0D7 inverse hard dividers (solid cell with an arrow cutout)
enum PowerlineRenderer {
    enum Direction: Equatable {
        case left
        case right
    }

    enum Shape: Equatable {
        /// Solid arrowhead: full-height flat joining edge, tip at the
        /// opposite edge's midpoint.
        case triangle
        /// Thin arrowhead: the two sloped edges stroked, nothing filled.
        case triangleOutline
        /// Solid half ellipse with a full-height flat joining edge.
        case rounded
        /// Thin circular arc bulging toward the outer edge; the arc is a
        /// clipped circle segment (like the font glyphs), not the squashed
        /// ellipse of the filled variant.
        case roundedOutline
        /// Solid half-cell triangle covering the flat joining edge and the
        /// bottom edge (U+E0B8/U+E0BA).
        case slantLower
        /// Solid half-cell triangle covering the flat joining edge and the
        /// top edge (U+E0BC/U+E0BE).
        case slantUpper
        /// Thin "\" stroke from the top-left to the bottom-right corner.
        case diagonalBack
        /// Thin "/" stroke from the bottom-left to the top-right corner.
        case diagonalForward
        /// Solid flame silhouette with a full-height flat joining edge.
        case flame
        /// The flame silhouette stroked instead of filled.
        case flameOutline
        /// Full-cell fill with an arrowhead cut out (the inverse divider
        /// shows the cell background through the cutout).
        case triangleInverse
    }

    struct Glyph {
        let direction: Direction
        let shape: Shape

        /// Whether the shape has a full-height flat edge adjoining the
        /// same-colored neighbor, so the one-device-pixel join overdraw is
        /// safe to apply.  Thin/outline shapes sit on a single background
        /// (their foreground differs from the neighbor's), and the inverse
        /// divider's edge is an intentional color transition: overdrawing
        /// there would paint a visible stripe into the neighbor cell.
        var hasSolidJoinEdge: Bool {
            switch shape {
            case .triangle, .rounded, .slantLower, .slantUpper, .flame:
                return true
            case .triangleOutline, .roundedOutline,
                 .diagonalBack, .diagonalForward,
                 .flameOutline, .triangleInverse:
                return false
            }
        }

        /// Whether the path is stroked rather than filled.
        var isStroked: Bool {
            switch shape {
            case .triangleOutline, .roundedOutline,
                 .diagonalBack, .diagonalForward, .flameOutline:
                return true
            case .triangle, .rounded, .slantLower, .slantUpper,
                 .flame, .triangleInverse:
                return false
            }
        }
    }

    static func glyph(for codePoint: UInt32) -> Glyph? {
        switch codePoint {
        case 0xE0B0: return Glyph(direction: .right, shape: .triangle)
        case 0xE0B1: return Glyph(direction: .right, shape: .triangleOutline)
        case 0xE0B2: return Glyph(direction: .left, shape: .triangle)
        case 0xE0B3: return Glyph(direction: .left, shape: .triangleOutline)
        case 0xE0B4: return Glyph(direction: .right, shape: .rounded)
        case 0xE0B5: return Glyph(direction: .right, shape: .roundedOutline)
        case 0xE0B6: return Glyph(direction: .left, shape: .rounded)
        case 0xE0B7: return Glyph(direction: .left, shape: .roundedOutline)
        case 0xE0B8: return Glyph(direction: .right, shape: .slantLower)
        case 0xE0B9: return Glyph(direction: .right, shape: .diagonalBack)
        case 0xE0BA: return Glyph(direction: .left, shape: .slantLower)
        case 0xE0BB: return Glyph(direction: .left, shape: .diagonalForward)
        case 0xE0BC: return Glyph(direction: .right, shape: .slantUpper)
        case 0xE0BD: return Glyph(direction: .left, shape: .diagonalForward)
        case 0xE0BE: return Glyph(direction: .left, shape: .slantUpper)
        case 0xE0BF: return Glyph(direction: .right, shape: .diagonalBack)
        case 0xE0C0: return Glyph(direction: .right, shape: .flame)
        case 0xE0C1: return Glyph(direction: .right, shape: .flameOutline)
        case 0xE0C2: return Glyph(direction: .left, shape: .flame)
        case 0xE0C3: return Glyph(direction: .left, shape: .flameOutline)
        case 0xE0D6: return Glyph(direction: .left, shape: .triangleInverse)
        case 0xE0D7: return Glyph(direction: .right, shape: .triangleInverse)
        default: return nil
        }
    }

    static func shouldRender(codePoint: UInt32, customGlyphsEnabled: Bool) -> Bool {
        customGlyphsEnabled && glyph(for: codePoint) != nil
    }

    /// Returns the in-cell shape with all cell boundaries snapped to pixels.
    static func path(codePoint: UInt32, cellRect: CGRect, scaleX: CGFloat, scaleY: CGFloat) -> CGPath? {
        guard let glyph = glyph(for: codePoint), scaleX > 0, scaleY > 0 else { return nil }
        let minX = (cellRect.minX * scaleX).rounded(.down) / scaleX
        let maxX = (cellRect.maxX * scaleX).rounded(.up) / scaleX
        let minY = (cellRect.minY * scaleY).rounded(.down) / scaleY
        let maxY = (cellRect.maxY * scaleY).rounded(.up) / scaleY
        let midY = ((minY + maxY) * scaleY / 2).rounded() / scaleY
        let joinX = glyph.direction == .right ? minX : maxX
        let outerX = glyph.direction == .right ? maxX : minX

        let path = CGMutablePath()
        // NOTE: the rendering coordinate system is y-up in both backends (the
        // CoreGraphics view context is unflipped, and the Metal atlas bitmap is
        // sampled the same way), so `minY` is the cell's visual BOTTOM edge and
        // `maxY` its visual top.
        switch glyph.shape {
        case .triangle:
            path.move(to: CGPoint(x: joinX, y: minY))
            path.addLine(to: CGPoint(x: outerX, y: midY))
            path.addLine(to: CGPoint(x: joinX, y: maxY))
            path.closeSubpath()
        case .triangleOutline:
            path.move(to: CGPoint(x: joinX, y: minY))
            path.addLine(to: CGPoint(x: outerX, y: midY))
            path.addLine(to: CGPoint(x: joinX, y: maxY))
        case .rounded:
            path.move(to: CGPoint(x: joinX, y: minY))
            // A half ellipse from the flat edge's top to its bottom.  The
            // 4/3 control distance makes the curve reach `outerX` at mid-cell.
            let radiusX = abs(outerX - joinX)
            let controlX = glyph.direction == .right
                ? joinX + (4.0 / 3.0) * radiusX
                : joinX - (4.0 / 3.0) * radiusX
            path.addCurve(to: CGPoint(x: joinX, y: maxY),
                          control1: CGPoint(x: controlX, y: minY),
                          control2: CGPoint(x: controlX, y: maxY))
            path.closeSubpath()
        case .roundedOutline:
            // A circular arc crossing the top and bottom edges, bulging to
            // 3/4 of the cell width at mid-height (the same geometry other
            // cell-aligned renderers use for the thin half circles).
            let width = maxX - minX
            let height = maxY - minY
            func arcPoint(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
                let x = glyph.direction == .right ? minX + fx * width : maxX - fx * width
                return CGPoint(x: x, y: minY + fy * height)
            }
            path.move(to: arcPoint(-1.0 / 4.0, -1.0 / 3.0))
            path.addQuadCurve(to: arcPoint(-1.0 / 4.0, 4.0 / 3.0),
                              control: arcPoint(7.0 / 4.0, 1.0 / 2.0))
        case .slantLower:
            // Visually lower half: bottom edge (minY) plus the flat join edge.
            path.move(to: CGPoint(x: joinX, y: minY))
            path.addLine(to: CGPoint(x: outerX, y: minY))
            path.addLine(to: CGPoint(x: joinX, y: maxY))
            path.closeSubpath()
        case .slantUpper:
            // Visually upper half: top edge (maxY) plus the flat join edge.
            path.move(to: CGPoint(x: joinX, y: maxY))
            path.addLine(to: CGPoint(x: outerX, y: maxY))
            path.addLine(to: CGPoint(x: joinX, y: minY))
            path.closeSubpath()
        case .diagonalBack:
            // Visual "\": top-left corner to bottom-right corner.
            path.move(to: CGPoint(x: minX, y: maxY))
            path.addLine(to: CGPoint(x: maxX, y: minY))
        case .diagonalForward:
            // Visual "/": bottom-left corner to top-right corner.
            path.move(to: CGPoint(x: minX, y: minY))
            path.addLine(to: CGPoint(x: maxX, y: maxY))
        case .flame, .flameOutline:
            // Overshoot vertically by one device pixel: the flame tips would
            // otherwise leave the top/bottom corner pixels half covered. The
            // overshoot clips away.
            addFlame(to: path, direction: glyph.direction,
                     minX: minX, maxX: maxX,
                     minY: minY - 1 / scaleY, maxY: maxY + 1 / scaleY,
                     includeFlatEdge: glyph.shape == .flame)
        case .triangleInverse:
            path.addRect(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
            path.move(to: CGPoint(x: joinX, y: minY))
            path.addLine(to: CGPoint(x: outerX, y: midY))
            path.addLine(to: CGPoint(x: joinX, y: maxY))
            path.closeSubpath()
        }
        return path
    }

    /// A one-device-pixel strip adjoining the flat edge of a cell that has
    /// already been transformed into device-pixel coordinates.
    static func devicePixelJoinRect(codePoint: UInt32, transformedCellRect: CGRect) -> CGRect? {
        guard let glyph = glyph(for: codePoint), glyph.hasSolidJoinEdge else { return nil }
        let minX = min(transformedCellRect.minX, transformedCellRect.maxX)
        let maxX = max(transformedCellRect.minX, transformedCellRect.maxX)
        return glyph.direction == .right
            ? CGRect(x: minX - 1, y: transformedCellRect.minY, width: 1, height: transformedCellRect.height)
            : CGRect(x: maxX, y: transformedCellRect.minY, width: 1, height: transformedCellRect.height)
    }

    /// - Parameter lineWidthPx: stroke width for the thin (outline) shapes,
    ///   in device pixels.  0 falls back to a one-device-pixel hairline.
    static func draw(codePoint: UInt32,
                     in context: CGContext,
                     cellRect: CGRect,
                     scaleX: CGFloat,
                     scaleY: CGFloat,
                     color: CGColor,
                     lineWidthPx: Int = 0,
                     includeJoinOverdraw: Bool = true) {
        guard let path = path(codePoint: codePoint, cellRect: cellRect, scaleX: scaleX, scaleY: scaleY) else { return }
        guard let glyph = glyph(for: codePoint) else { return }
        let pixel = 1 / scaleX
        let minX = (cellRect.minX * scaleX).rounded(.down) / scaleX
        let maxX = (cellRect.maxX * scaleX).rounded(.up) / scaleX
        let minY = (cellRect.minY * scaleY).rounded(.down) / scaleY
        let maxY = (cellRect.maxY * scaleY).rounded(.up) / scaleY
        let joinRect = glyph.direction == .right
            ? CGRect(x: minX - pixel, y: minY, width: pixel, height: maxY - minY)
            : CGRect(x: maxX, y: minY, width: pixel, height: maxY - minY)
        context.saveGState()
        context.setFillColor(color)
        if includeJoinOverdraw, glyph.hasSolidJoinEdge {
            context.setShouldAntialias(false)
            context.setAllowsAntialiasing(false)
            context.fill(joinRect)
        }
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        // The outline shapes (thin arcs, diagonals, stroked flame) deliberately
        // reach the cell corners or beyond; clip to the cell so the
        // CoreGraphics path stays inside it exactly like the Metal path, which
        // rasterizes into a cell-sized bitmap.
        context.clip(to: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        if glyph.isStroked {
            context.setStrokeColor(color)
            // Thickness tracks the vertical device scale: equal to scaleX on
            // single and doubled-up/down lines, and on double-width lines it
            // avoids the half-thickness stroke that dividing by the doubled
            // scaleX would produce.
            context.setLineWidth(CGFloat(max(1, lineWidthPx)) / scaleY)
            context.setLineJoin(.round)
            context.addPath(path)
            context.strokePath()
        } else if glyph.shape == .triangleInverse {
            context.addPath(path)
            context.drawPath(using: .eoFill)
        } else {
            context.addPath(path)
            context.fillPath()
        }
        context.restoreGState()
    }

    /// Draw the cursor's copy with the row's DEC transform. Thin separators
    /// must reuse the base-cell path and stroke, rather than widening the
    /// path to the cursor bounds while keeping an unscaled stroke.
    static func drawCaret(codePoint: UInt32,
                          in context: CGContext,
                          bounds: CGRect,
                          renderMode: BufferLine.RenderLineMode,
                          scale: CGFloat,
                          color: CGColor,
                          lineWidthPx: Int) {
        let doubleWidth: CGFloat = renderMode == .single ? 1 : 2
        let doubleHeight: CGFloat
        switch renderMode {
        case .doubledDown, .doubledTop: doubleHeight = 2
        case .single, .doubleWidth: doubleHeight = 1
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)
        let yOffset = renderMode == .doubledTop ? -bounds.height : 0
        context.translateBy(x: bounds.minX, y: bounds.minY + yOffset)
        context.scaleBy(x: doubleWidth, y: doubleHeight)
        draw(codePoint: codePoint,
             in: context,
             cellRect: CGRect(x: 0, y: 0, width: bounds.width / doubleWidth, height: bounds.height),
             scaleX: scale * doubleWidth,
             scaleY: scale * doubleHeight,
             color: color,
             lineWidthPx: lineWidthPx * Int(doubleHeight),
             includeJoinOverdraw: false)
    }

    // MARK: - Flame silhouette

    /// One segment of the flame outline, in font units (y up).
    private enum FlameSegment {
        case move(x: CGFloat, y: CGFloat)
        case line(x: CGFloat, y: CGFloat)
        case curve(c1x: CGFloat, c1y: CGFloat, c2x: CGFloat, c2y: CGFloat, x: CGFloat, y: CGFloat)
    }

    /// Normalization box of the flame outline in font units: the extent of the
    /// flat joining edge, not the whole bounding box, so the edge fills the
    /// cell height exactly and only the flame tips overshoot (and clip).
    private static let flameBounds = (minX: -200.971 as CGFloat, minY: -496.67 as CGFloat,
                                      maxX: 2722.16 as CGFloat, maxY: 1845.66 as CGFloat)

    /// The Nerd Font `ple-flame` silhouette, transcribed from the
    /// powerline-extra-symbols source (`src/uniE0C0_flame-thick.eps`) and
    /// normalized into the cell at draw time. The solid path includes the flat
    /// joining edge; the thin path follows only the organic outline and stays open.
    /// Source: https://github.com/ryanoasis/powerline-extra-symbols
    /// Copyright (c) 2016 Ryan L McIntyre; MIT license (see LICENSE).
    private static let flameLowerPath: [FlameSegment] = [
        .move(x: 2157.17, y: 445.633),
        .curve(c1x: 1962.06, c1y: 357.672, c2x: 1714.88, c2y: 239.342, x: 1616.59, y: 239.101),
        .curve(c1x: 1569.17, c1y: 238.987, c2x: 1486.07, c2y: 221.028, x: 1392.25, y: 253.274),
        .curve(c1x: 1245.91, c1y: 303.555, c2x: 1063.72, c2y: 418.728, x: 994.192, y: 362.44),
        .curve(c1x: 917.992, c1y: 300.784, c2x: 905.246, c2y: 278.838, x: 805.399, y: 247.271),
        .line(x: 821.927, y: 233.929),
        .curve(c1x: 905.483, c1y: 166.467, c2x: 922.354, c2y: 77.4551, x: 1054.89, y: 54.7725),
        .curve(c1x: 1136.74, c1y: 40.7676, c2x: 1238.29, c2y: 55.0156, x: 1319.64, y: 78.1855),
        .curve(c1x: 1191.88, c1y: 3.97754, c2x: 1007.37, c2y: -17.9238, x: 879.504, y: -16.3516),
        .curve(c1x: 715.842, c1y: -14.3398, c2x: 525.757, c2y: 162.711, x: 345.399, y: 94.4902),
        .curve(c1x: 263.871, c1y: 63.6289, c2x: 161.86, c2y: -26.9697, x: 167.859, y: -138.188),
        .line(x: 168.824, y: -156.082),
        .curve(c1x: 279.217, c1y: -97.0234, c2x: 345.249, c2y: -108.88, x: 450.019, y: -166.715),
        .curve(c1x: 527.24, c1y: -209.336, c2x: 617.42, c2y: -210.514, x: 702.477, y: -230.545),
        .curve(c1x: 556.852, c1y: -255.031, c2x: 423.041, c2y: -327.984, x: 281.979, y: -294.123),
        .curve(c1x: 125.055, c1y: -256.453, c2x: -49.3613, c2y: -525.24, x: -200.971, y: -496.67),
    ]

    private static let flameFlatEdgePath: [FlameSegment] = [
        .curve(c1x: -196.96, c1y: -279.114, c2x: -194.395, c2y: 1058.37, x: -194.519, y: 1348.09),
        .curve(c1x: -194.58, c1y: 1490.43, c2x: -204.668, c2y: 1676.29, x: -201.389, y: 1845.66),
    ]

    private static let flameUpperPath: [FlameSegment] = [
        .curve(c1x: -144.492, c1y: 1843.4, c2x: -150.387, c2y: 1833.88, x: -99.2002, y: 1775.53),
        .curve(c1x: 10.9062, c1y: 1660.2, c2x: 148.43, c2y: 1731.66, x: 260.156, y: 1801.83),
        .curve(c1x: 367.912, c1y: 1869.49, c2x: 476.387, c2y: 1879.91, x: 579.878, y: 1828.5),
        .curve(c1x: 449.878, c1y: 1832.89, c2x: 410.693, c2y: 1760.81, x: 323.836, y: 1658.59),
        .curve(c1x: 297.757, c1y: 1627.91, c2x: 198.798, c2y: 1596.31, x: 145.898, y: 1557.81),
        .curve(c1x: 118.434, c1y: 1537.83, c2x: 98.5342, c2y: 1508.98, x: 122.329, y: 1477.18),
        .curve(c1x: 225.405, c1y: 1339.43, c2x: 472.99, c2y: 1536.32, x: 547.34, y: 1588.14),
        .curve(c1x: 688.859, c1y: 1686.77, c2x: 792.757, c2y: 1714.67, x: 944.408, y: 1646.55),
        .curve(c1x: 1089.46, c1y: 1581.41, c2x: 1195.5, c2y: 1618.08, x: 1312.36, y: 1685.85),
        .curve(c1x: 1205.44, c1y: 1586.31, c2x: 1098.31, c2y: 1565.83, x: 951.386, y: 1512.45),
        .curve(c1x: 870.913, c1y: 1483.21, c2x: 825.922, c2y: 1436.71, x: 816.5, y: 1386.12),
        .curve(c1x: 802.2, c1y: 1309.32, c2x: 870.771, c2y: 1236.25, x: 988.992, y: 1214.43),
        .curve(c1x: 1193.33, c1y: 1176.71, c2x: 1353.72, c2y: 1342.82, x: 1529.92, y: 1396.21),
        .curve(c1x: 1749.13, c1y: 1462.64, c2x: 1961.54, c2y: 1426.49, x: 2166.16, y: 1319.97),
        .curve(c1x: 2362.82, c1y: 1217.6, c2x: 2533.46, c2y: 1146.58, x: 2722.16, y: 1245.58),
        .curve(c1x: 2419.64, c1y: 979.899, c2x: 2025.04, c2y: 1300.62, x: 1690.26, y: 1076.74),
        .curve(c1x: 1589.48, c1y: 1009.34, c2x: 1525.91, c2y: 960.363, x: 1407, y: 929.312),
        .line(x: 1423.18, y: 915.136),
        .curve(c1x: 1494.92, c1y: 852.272, c2x: 1625.93, c2y: 848.675, x: 1704.8, y: 832.277),
        .curve(c1x: 1757.12, c1y: 821.396, c2x: 1813.92, c2y: 824.847, x: 1861.32, y: 833.605),
        .curve(c1x: 1765.17, c1y: 788.387, c2x: 1679.65, c2y: 755.136, x: 1564.7, y: 748.968),
        .curve(c1x: 1401.42, c1y: 740.213, c2x: 1281.46, c2y: 759.489, x: 1151.41, y: 619.893),
        .line(x: 1128.74, y: 595.568),
        .line(x: 1161.56, y: 600.862),
        .curve(c1x: 1224.16, c1y: 610.959, c2x: 1343.92, c2y: 511.806, x: 1460.6, y: 444.534),
        .curve(c1x: 1534.25, c1y: 402.074, c2x: 1609.84, c2y: 390.877, x: 1649.74, y: 379.385),
        .curve(c1x: 1727.55, c1y: 356.962, c2x: 1966.83, c2y: 400.936, x: 2157.17, y: 445.633),
    ]

    private static let solidFlamePath = flameLowerPath + flameFlatEdgePath + flameUpperPath
    private static let thinFlamePath = [FlameSegment.move(x: -201.389, y: 1845.66)]
        + flameUpperPath + flameLowerPath.dropFirst()

    private static func addFlame(to path: CGMutablePath,
                                 direction: Direction,
                                 minX: CGFloat, maxX: CGFloat,
                                 minY: CGFloat, maxY: CGFloat,
                                 includeFlatEdge: Bool) {
        let srcWidth = flameBounds.maxX - flameBounds.minX
        let srcHeight = flameBounds.maxY - flameBounds.minY
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let fx = (x - flameBounds.minX) / srcWidth
            // Both the font data and the rendering coordinate system are y-up.
            return CGPoint(x: direction == .right
                           ? minX + fx * (maxX - minX)
                           : maxX - fx * (maxX - minX),
                           y: minY + (y - flameBounds.minY) / srcHeight * (maxY - minY))
        }
        for segment in includeFlatEdge ? solidFlamePath : thinFlamePath {
            switch segment {
            case let .move(x, y):
                path.move(to: map(x, y))
            case let .line(x, y):
                path.addLine(to: map(x, y))
            case let .curve(c1x, c1y, c2x, c2y, x, y):
                path.addCurve(to: map(x, y), control1: map(c1x, c1y), control2: map(c2x, c2y))
            }
        }
        if includeFlatEdge {
            path.closeSubpath()
        }
    }
}

struct PowerlineRenderItem {
    let column: Int
    let columnWidth: Int
    let codePoint: UInt32
    let foregroundColor: TTColor
}
#endif

#endif // !SWIFTTERM_EMBEDDED
