#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS) || os(macCatalyst)
import CoreGraphics

struct BidiImageGeometry {
    let fullRect: CGRect
    let visibleRect: CGRect
    let uvRect: CGRect
}

struct BidiImageSpan: Equatable {
    let logicalColumn: Int
    let width: Int
    var endColumn: Int { logicalColumn + width }
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

    /// Return visible image ranges. Each range covers complete terminal cells.
    static func imageSpans(line: BufferLine, cols: Int) -> [BidiImageSpan] {
        let limit = min(cols, line.count)
        guard limit > 0, let images = line.images else { return [] }
        var spans: [BidiImageSpan] = []
        for image in images {
            let width = image.columnWidth
            guard width > 0, image.col < limit else { continue }
            let (sum, overflow) = image.col.addingReportingOverflow(width)
            let rawEnd = overflow ? Int.max : sum
            guard rawEnd > 0 else { continue }
            var start = max(0, image.col)
            var end = min(limit, rawEnd)
            guard start < end else { continue }
            // Include the lead cell when the range starts on a wide-cell tail.
            if start > 0, line.packedView(at: start).width == 0,
               line.packedView(at: start - 1).width == 2 {
                start -= 1
            }
            // Include the tail when the range ends after a wide-cell lead.
            if end < limit, line.packedView(at: end).width == 0,
               line.packedView(at: end - 1).width == 2 {
                end += 1
            }
            spans.append(BidiImageSpan(logicalColumn: start, width: end - start))
        }
        spans.sort { $0.logicalColumn < $1.logicalColumn }
        var merged: [BidiImageSpan] = []
        for span in spans {
            if let last = merged.last, span.logicalColumn < last.endColumn {
                merged[merged.count - 1] = BidiImageSpan(
                    logicalColumn: last.logicalColumn,
                    width: max(last.endColumn, span.endColumn) - last.logicalColumn)
            } else {
                merged.append(span)
            }
        }
        return merged
    }
}
#endif
#endif
