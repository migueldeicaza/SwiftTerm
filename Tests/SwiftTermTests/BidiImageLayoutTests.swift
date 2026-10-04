#if os(macOS)
import Testing
@testable import SwiftTerm

final class BidiImageLayoutTests {
    final class Image: TerminalImage {
        let pixelWidth = 1
        let pixelHeight = 1
        var col: Int
        let columnWidth: Int
        init(_ col: Int, _ width: Int) {
            self.col = col
            columnWidth = width
        }
    }

    func spans(_ images: [Image], cols: Int = 10) -> [BidiImageSpan] {
        let line = BufferLine(cols: 10)
        line.images = images
        return TerminalBidi.imageSpans(line: line, cols: cols)
    }

    @Test func overlappingRangesMergeButAdjacentRangesStaySeparate() {
        #expect(spans([Image(4, 3), Image(1, 4), Image(7, 1)]) == [
            BidiImageSpan(logicalColumn: 1, width: 6),
            BidiImageSpan(logicalColumn: 7, width: 1)
        ])
    }

    @Test func imageBeyondTrimmedTextIsIncluded() {
        let line = BufferLine(cols: 10)
        #expect(line.getTrimmedLength() == 0)
        line.images = [Image(6, 2)]
        #expect(TerminalBidi.imageSpans(line: line, cols: 10) == [
            BidiImageSpan(logicalColumn: 6, width: 2)
        ])
    }

    @Test func lastColumnAndLineLengthClampRanges() {
        #expect(spans([Image(7, 8)], cols: 8) == [BidiImageSpan(logicalColumn: 7, width: 1)])
        #expect(spans([Image(9, 8)], cols: 20) == [BidiImageSpan(logicalColumn: 9, width: 1)])
    }

    @Test func wideCellBoundariesIncludeLeadAndTail() {
        let line = BufferLine(cols: 10)
        line[3] = CharData(attribute: CharData.defaultAttr, code: 0x4E00, size: 2)
        line[4] = CharData(attribute: CharData.defaultAttr, code: 0, size: 0)
        for image in [Image(4, 1), Image(3, 1)] {
            line.images = [image]
            #expect(TerminalBidi.imageSpans(line: line, cols: 10) == [
                BidiImageSpan(logicalColumn: 3, width: 2)
            ])
        }
        line.images = [Image(3, 1)]
        #expect(TerminalBidi.imageSpans(line: line, cols: 4) == [
            BidiImageSpan(logicalColumn: 3, width: 1)
        ])
    }

    @Test func extremeMetadataDoesNotOverflow() {
        #expect(spans([Image(1, Int.max)]) == [BidiImageSpan(logicalColumn: 1, width: 9)])
        #expect(spans([Image(-1, Int.max)]) == [BidiImageSpan(logicalColumn: 0, width: 10)])
        #expect(spans([Image(Int.min, Int.max), Image(Int.max, 1),
                       Image(0, Int.min), Image(0, 0)]).isEmpty)
        #expect(spans([Image(0, 1)], cols: Int.min).isEmpty)
    }
}
#endif
