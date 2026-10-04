#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS) || os(macCatalyst)
import CoreGraphics

enum CursorGeometry {
    /// Keep the bar inside the cell bounds in both renderers.
    static func barRect(in bounds: CGRect, direction: BidiDirection,
                        width: CGFloat) -> CGRect {
        let barWidth = min(max(0, width), max(0, bounds.width))
        let x = direction == .rightToLeft ? bounds.maxX - barWidth : bounds.minX
        return CGRect(x: x, y: bounds.minY, width: barWidth,
                      height: max(0, bounds.height))
    }
}
#endif
#endif
