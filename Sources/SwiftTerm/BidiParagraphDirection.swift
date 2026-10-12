//
//  BidiParagraphDirection.swift
//  SwiftTerm
//
//  Portable rules for the base direction of a BiDi paragraph. The Apple
//  renderer (Apple/TerminalBidi.swift) and the key encoder use these rules,
//  so the Left and Right arrow keys follow the direction that the renderer
//  draws. Nothing here typesets text.
//

/// Cell-level bidirectional text support. The portable part finds paragraph
/// directions. The Apple part adds the CoreText layout.
enum TerminalBidi {

    /// Fast check: does this scalar require BiDi processing?
    /// Covers Hebrew through Arabic Extended-A contiguously, the presentation
    /// form blocks, and the RTL directional formatting characters.
    @inline(__always)
    static func isRTLTrigger(_ v: UInt32) -> Bool {
        if v > 0xFFFF {
            let probe = supplementaryProbeScalar(v)
            return probe == 0x05D0 || probe == 0x0621
        }
        if v < 0x0590 { return false }
        switch v {
        case 0x0590...0x08FF,           // Hebrew ... Arabic Extended-A
             0xFB1D...0xFDFF,           // Hebrew/Arabic presentation forms A
             0xFE70...0xFEFC,           // Arabic presentation forms B
             0x10800...0x10FFF,         // historic right-to-left scripts
             0x1E800...0x1EFFF,         // Mende, Adlam, and Arabic math
             0x200F, 0x202B, 0x202E,    // RLM, RLE, RLO
             0x2067:                    // RLI
            return true
        default:
            return false
        }
    }

    /// Keep supplementary letters and digits in their Unicode direction class.
    static func supplementaryProbeScalar(_ value: UInt32) -> UInt16 {
        var lower = 0
        var upper = supplementaryBidiProbes.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let entry = supplementaryBidiProbes[middle]
            if value < entry.0.lowerBound {
                upper = middle
            } else if value > entry.0.upperBound {
                lower = middle + 1
            } else {
                return entry.1
            }
        }
        return 0x0041
    }

    /// Returns the direction of a scalar that sets the paragraph direction.
    /// Only letters and the LRM and RLM marks count, in all Unicode planes.
    /// Icons, flags and other symbols do not set the direction.
    @inline(__always)
    static func strongDirection(_ scalar: UnicodeScalar) -> BidiDirection? {
        let value = scalar.value
        if value < 0x80 {
            let lower = value | 0x20
            return lower >= 0x61 && lower <= 0x7A ? .leftToRight : nil
        }
        if value == 0x200F {
            return .rightToLeft
        }
        if value == 0x200E {
            return .leftToRight
        }
        guard scalar.properties.isAlphabetic else {
            return nil
        }
        return isRTLTrigger(value) ? .rightToLeft : .leftToRight
    }

    /// Returns the direction of the first scalar in a cell that sets the
    /// paragraph direction.
    @inline(__always)
    static func strongDirection(of text: Character) -> BidiDirection? {
        for scalar in text.unicodeScalars {
            if let direction = strongDirection(scalar) {
                return direction
            }
        }
        return nil
    }

    // MARK: - Cells

    /// Return visible image ranges. Each range covers complete terminal cells.
    static func imageSpans(line: BufferLine, cols: Int) -> [BidiImageSpan] {
#if SWIFTTERM_EMBEDDED
        return []
#else
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
#endif
    }

    /// Calls `body` with the column, width and text of each non-erased cell of
    /// a row, in logical order. An image span is one U+FFFC cell. The walk
    /// stops when `body` returns false. Returns the column after the last cell
    /// visited. The renderer and the direction resolver both use this walk,
    /// so they see the same cells.
    @inline(__always)
    static func forEachCell(line: BufferLine, cols: Int,
                            _ body: (_ col: Int, _ width: Int, _ text: Character) -> Bool) -> Int {
        let images = imageSpans(line: line, cols: cols)
        let contentLimit = min(cols, line.count,
                               max(line.getTrimmedLength(), images.last?.endColumn ?? 0))
        var col = 0
        var imageIndex = 0
        while col < contentLimit {
            if imageIndex < images.count, images[imageIndex].logicalColumn == col {
                let image = images[imageIndex]
                guard body(col, image.width, "\u{FFFC}") else { return col }
                col = image.endColumn
                imageIndex += 1
                continue
            }
            let ch = line.packedView(at: col)
            let width = max(1, Int(ch.width))
            let character: Character = ch.code == 0 ? " " : ch.getCharacter()
            guard body(col, width, character) else { return col }
            col += width
        }
        return col
    }

    // MARK: - Paragraph direction

    /// Finds a paragraph without visiting more than `maximumRows` rows. A nil
    /// result means that the row is invalid or that the paragraph is too large
    /// for paragraph-wide rendering.
    static func paragraphBounds(row: Int, buffer: Buffer,
                                maximumRows: Int) -> ClosedRange<Int>? {
        guard row >= 0, row < buffer.lines.count else {
            return nil
        }
        let limit = max(1, maximumRows)
        var first = row
        var count = 1
        while first > 0 && buffer.lines[first].isWrapped {
            guard count < limit else {
                return nil
            }
            first -= 1
            count += 1
        }
        var last = row
        while last + 1 < buffer.lines.count && buffer.lines[last + 1].isWrapped {
            guard count < limit else {
                return nil
            }
            last += 1
            count += 1
        }
        return first...last
    }

    /// Returns the direction of the first strong character in a row, or nil
    /// when the row has no strong character.
    static func detectedBaseDirection(line: BufferLine, cols: Int) -> BidiDirection? {
        var direction: BidiDirection?
        _ = forEachCell(line: line, cols: cols) { _, _, text in
            direction = strongDirection(of: text)
            return direction == nil
        }
        return direction
    }

    /// Returns the base direction of the paragraph that contains `row`. The
    /// result is the direction that the renderer uses for the paragraph. The
    /// function reads at most `maximumRows` rows and does not typeset. Call it
    /// while holding the terminal lock.
    static func baseDirection(row: Int, buffer: Buffer, cols: Int, maximumRows: Int,
                              hostPolicy: BidiHostPolicy) -> BidiDirection {
        guard hostPolicy == .respectTerminal, row >= 0, row < buffer.lines.count else {
            return .leftToRight
        }
        let state = buffer.lines[row].bidiState
        if state.supportMode == .explicit {
            return state.fallbackDirection
        }
        guard let bounds = paragraphBounds(row: row, buffer: buffer,
                                           maximumRows: maximumRows) else {
            // The renderer uses explicit display when the paragraph exceeds
            // the limit. With autodetection, it keeps logical order.
            return state.autodetectDirection ? .leftToRight : state.fallbackDirection
        }
        // The first row of the paragraph holds the paragraph state.
        let paragraphState = buffer.lines[bounds.lowerBound].bidiState
        guard paragraphState.autodetectDirection else {
            return paragraphState.fallbackDirection
        }
        for paragraphRow in bounds {
            if let direction = detectedBaseDirection(line: buffer.lines[paragraphRow],
                                                     cols: cols) {
                return direction
            }
        }
        return paragraphState.fallbackDirection
    }
}

/// A run of columns that one inline image covers.
struct BidiImageSpan: Equatable {
    let logicalColumn: Int
    let width: Int
    var endColumn: Int { logicalColumn + width }
}
