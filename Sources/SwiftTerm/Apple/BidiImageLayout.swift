#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS) || os(macCatalyst)
import CoreGraphics

struct BidiImageGeometry {
    let fullRect: CGRect
    let visibleRect: CGRect
    let uvRect: CGRect
}

extension TerminalBidi {
    /// Keep image pixels in their original order within the visual object.
    static func visualImageColumn(_ logicalColumn: Int, layout: BidiRowLayout?) -> Int {
        guard let layout, layout.logicalToVisualCol.indices.contains(logicalColumn) else {
            return logicalColumn
        }
        return layout.logicalToVisualCol[logicalColumn]
    }

    /// Preserve the source crop when an image moves into visual column order.
    static func imageGeometry(_ image: TerminalImage, layout: BidiRowLayout?,
                              cols: Int, cellWidth: CGFloat, rowBase: CGFloat)
        -> BidiImageGeometry? {
        guard cols > 0, image.col < cols, image.columnWidth > 0,
              image.pixelWidth > 0, image.pixelHeight > 0,
              cellWidth.isFinite, cellWidth > 0 else { return nil }
        let (sum, overflow) = image.col.addingReportingOverflow(image.columnWidth)
        let end = min(cols, overflow ? Int.max : sum)
        let start = max(0, image.col)
        guard start < end else { return nil }
        let sourceOffset = (CGFloat(start) - CGFloat(image.col)) * cellWidth
        let pixelWidth = CGFloat(image.pixelWidth)
        let visibleWidth = min(CGFloat(end - start) * cellWidth, pixelWidth - sourceOffset)
        guard visibleWidth > 0 else { return nil }
        let x = CGFloat(visualImageColumn(start, layout: layout)) * cellWidth
        let y = rowBase - CGFloat(image.pixelHeight)
        return BidiImageGeometry(
            fullRect: CGRect(x: x - sourceOffset, y: y,
                             width: pixelWidth, height: CGFloat(image.pixelHeight)),
            visibleRect: CGRect(x: x, y: y, width: visibleWidth,
                                height: CGFloat(image.pixelHeight)),
            uvRect: CGRect(x: sourceOffset / pixelWidth, y: 0,
                           width: visibleWidth / pixelWidth, height: 1))
    }
}
#endif
#endif
