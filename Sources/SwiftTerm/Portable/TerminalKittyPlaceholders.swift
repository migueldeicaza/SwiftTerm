#if !SWIFTTERM_EMBEDDED
/// A rectangle in top-row-first pixel coordinates.
public struct TerminalKittyPlaceholderRect: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

/// The visible part of a virtual image in one terminal cell.
public struct TerminalKittyPlaceholderPlacement: Sendable, Equatable {
    public let imageId: UInt32
    public let token: UInt64
    public let insertionOrder: UInt64
    public let source: TerminalKittyPlaceholderRect
    public let destination: TerminalKittyPlaceholderRect
}

extension Terminal {
    /// Resolve visible Unicode placeholders and crop aspect-fit virtual images
    /// to their cells. Call while holding terminalLock. Use a Kitty snapshot
    /// made under that same lock so image and text state agree.
    public func visibleKittyPlaceholderPlacements(
        snapshot: KittyGraphicsRenderSnapshot, cellWidth: Int, cellHeight: Int
    ) -> [TerminalKittyPlaceholderPlacement] {
        guard cellWidth > 0, cellHeight > 0 else { return [] }
        let records = Dictionary(grouping: snapshot.placements.filter(\.isVirtual), by: \.imageId)
        guard !records.isEmpty else { return [] }
        let cw = Double(cellWidth), ch = Double(cellHeight)
        let display = displayBuffer
        var result: [TerminalKittyPlaceholderPlacement] = []
        for row in 0..<rows {
            let index = display.yDisp + row
            guard index >= 0, index < display.lines.count else { continue }
            let line = display.lines[index]
            var previous: KittyPlaceholderCell?
            var previousAttribute: Attribute?
            for col in 0..<min(cols, line.count) {
                let cell = line.packedView(at: col)
                guard cell.code == Int32(KittyPlaceholder.baseScalar) else {
                    previous = nil
                    previousAttribute = nil
                    continue
                }
                let attribute = cell.attribute
                let placeholder = KittyPlaceholderDecoder.decode(
                    cell: cell, attribute: attribute, row: row, col: col,
                    previous: previous, previousAttribute: previousAttribute)
                previous = placeholder
                previousAttribute = placeholder == nil ? nil : attribute
                guard let placeholder,
                      let record = records[placeholder.imageId]?.first(where: {
                          (placeholder.placementId == 0 || $0.placementId == placeholder.placementId) &&
                          $0.geometry.columns > placeholder.placeholderCol &&
                          $0.geometry.rows > placeholder.placeholderRow
                      }), snapshot.imagesById[record.imageId] != nil else { continue }
                let source = record.visibleSource
                guard source.width > 0, source.height > 0 else { continue }
                let width = Double(record.geometry.columns) * cw
                let height = Double(record.geometry.rows) * ch
                let scale = min(width / Double(source.width), height / Double(source.height))
                guard scale > 0, scale.isFinite else { continue }
                let fitWidth = Double(source.width) * scale
                let fitHeight = Double(source.height) * scale
                let x = Double(col - placeholder.placeholderCol) * cw + Double(record.pixelOffsetX) + (width - fitWidth) / 2
                let y = Double(row - placeholder.placeholderRow) * ch + Double(record.pixelOffsetY) + (height - fitHeight) / 2
                let left = max(Double(col) * cw, x)
                let top = max(Double(row) * ch, y)
                let right = min(Double(col + 1) * cw, x + fitWidth)
                let bottom = min(Double(row + 1) * ch, y + fitHeight)
                guard right > left, bottom > top else { continue }
                result.append(TerminalKittyPlaceholderPlacement(
                    imageId: record.imageId, token: record.token, insertionOrder: record.insertionOrder,
                    source: TerminalKittyPlaceholderRect(
                        x: Double(source.x) + (left - x) / scale,
                        y: Double(source.y) + (top - y) / scale,
                        width: (right - left) / scale, height: (bottom - top) / scale),
                    destination: TerminalKittyPlaceholderRect(x: left, y: top, width: right - left, height: bottom - top)))
            }
        }
        return result
    }
}
#endif
