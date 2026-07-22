#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics
import Foundation

/// Cell-aligned rendering for the four Powerline separators used by prompts.
///
/// Font glyphs are deliberately not used here: their antialiased outline can
/// land between the terminal's pixel-aligned background cells and expose a
/// seam.  These shapes share the cell grid with the background renderer and
/// extend only their joining edge by one physical pixel.
enum PowerlineRenderer {
    enum Direction: Equatable {
        case left
        case right
    }

    enum Shape: Equatable {
        case triangle
        case rounded
    }

    struct Glyph {
        let direction: Direction
        let shape: Shape
    }

    static func glyph(for codePoint: UInt32) -> Glyph? {
        switch codePoint {
        case 0xE0B0: return Glyph(direction: .right, shape: .triangle)
        case 0xE0B2: return Glyph(direction: .left, shape: .triangle)
        case 0xE0B4: return Glyph(direction: .right, shape: .rounded)
        case 0xE0B6: return Glyph(direction: .left, shape: .rounded)
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
        switch glyph.shape {
        case .triangle:
            path.move(to: CGPoint(x: joinX, y: minY))
            path.addLine(to: CGPoint(x: outerX, y: midY))
            path.addLine(to: CGPoint(x: joinX, y: maxY))
            path.closeSubpath()
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
        }
        return path
    }

    /// A one-device-pixel strip adjoining the flat edge of a cell that has
    /// already been transformed into device-pixel coordinates.
    static func devicePixelJoinRect(codePoint: UInt32, transformedCellRect: CGRect) -> CGRect? {
        guard let glyph = glyph(for: codePoint) else { return nil }
        let minX = min(transformedCellRect.minX, transformedCellRect.maxX)
        let maxX = max(transformedCellRect.minX, transformedCellRect.maxX)
        return glyph.direction == .right
            ? CGRect(x: minX - 1, y: transformedCellRect.minY, width: 1, height: transformedCellRect.height)
            : CGRect(x: maxX, y: transformedCellRect.minY, width: 1, height: transformedCellRect.height)
    }

    static func draw(codePoint: UInt32,
                     in context: CGContext,
                     cellRect: CGRect,
                     scaleX: CGFloat,
                     scaleY: CGFloat,
                     color: CGColor,
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
        if includeJoinOverdraw {
            context.setShouldAntialias(false)
            context.setAllowsAntialiasing(false)
            context.fill(joinRect)
        }
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.setFillColor(color)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }
}

struct PowerlineRenderItem {
    let column: Int
    let columnWidth: Int
    let codePoint: UInt32
    let foregroundColor: TTColor
}
#endif
