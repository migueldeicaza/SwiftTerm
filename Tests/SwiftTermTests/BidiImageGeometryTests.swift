#if os(macOS)
import CoreGraphics
import Testing

@testable import SwiftTerm

struct BidiImageGeometryTests {
    final class Image: TerminalImage {
        let pixelWidth: Int
        let pixelHeight = 20
        var col: Int
        let columnWidth: Int

        init(col: Int, columns: Int, pixels: Int) {
            self.col = col
            columnWidth = columns
            pixelWidth = pixels
        }
    }

    private func layout(_ mapping: [Int]) -> BidiRowLayout {
        BidiRowLayout(visualCells: [], logicalToVisualCol: mapping,
                      visualToLogicalCol: [],
                      logicalDirections: Array(repeating: .rightToLeft, count: mapping.count),
                      baseDirection: .rightToLeft, paragraphRevision: 0)
    }

    private func geometry(_ image: Image, mapping: [Int]? = nil) -> BidiImageGeometry? {
        TerminalBidi.imageGeometry(image, layout: mapping.map(layout),
                                   cols: 10, cellWidth: 10, rowBase: 40)
    }

    @Test func rightCropStaysInsideTheRelocatedVisibleSpan() throws {
        let image = Image(col: 8, columns: 6, pixels: 60)
        let result = try #require(geometry(image, mapping: [9, 8, 7, 6, 5, 4, 3, 2, 0, 1]))
        #expect(result.fullRect == CGRect(x: 0, y: 20, width: 60, height: 20))
        #expect(result.visibleRect == CGRect(x: 0, y: 20, width: 20, height: 20))
        #expect(result.uvRect.minX == 0)
        #expect(abs(result.uvRect.width - 1.0 / 3.0) < 0.000001)
    }

    @Test func leftCropRetainsTheSourceOffsetAfterRelocation() throws {
        let image = Image(col: -2, columns: 5, pixels: 50)
        let result = try #require(geometry(image, mapping: [7, 8, 9, 6, 5, 4, 3, 2, 1, 0]))
        #expect(result.fullRect == CGRect(x: 50, y: 20, width: 50, height: 20))
        #expect(result.visibleRect == CGRect(x: 70, y: 20, width: 30, height: 20))
        #expect(result.uvRect == CGRect(x: 0.4, y: 0, width: 0.6, height: 1))
        #expect(result.visibleRect.minX - result.fullRect.minX == result.uvRect.minX * 50)

        let logical = try #require(geometry(image))
        #expect(logical.fullRect.minX == -20)
        #expect(logical.visibleRect.minX == 0)
        #expect(logical.uvRect == result.uvRect)
    }

    @Test func overlappingImagesKeepTheirOriginalOffsetsWithinTheObject() throws {
        let mapping = [9, 3, 4, 5, 6, 7, 8, 2, 1, 0]
        let first = try #require(geometry(Image(col: 1, columns: 4, pixels: 40), mapping: mapping))
        let second = try #require(geometry(Image(col: 4, columns: 3, pixels: 30), mapping: mapping))
        #expect(first.visibleRect.minX == 30)
        #expect(second.visibleRect.minX == 60)
        #expect(second.visibleRect.minX - first.visibleRect.minX == 30)
        #expect(first.uvRect == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(second.uvRect == first.uvRect)
    }

    @Test func fractionalLastColumnUsesOnlyTheActualImagePixels() throws {
        let result = try #require(geometry(Image(col: 7, columns: 3, pixels: 25)))
        #expect(result.visibleRect == CGRect(x: 70, y: 20, width: 25, height: 20))
        #expect(result.uvRect.width == 1)
    }

    @Test func columnCountIgnoresFloatingPointError() {
        for (cellWidth, cells) in [(9.6, 7), (6.9, 3), (10.2, 15), (8.4, 31)] {
            #expect(imageColumnCount(width: cellWidth * Double(cells), cellWidth: cellWidth) == cells)
        }
        #expect(imageColumnCount(width: 9.6 * 7 + 0.001, cellWidth: 9.6) == 8)
        #expect(imageColumnCount(width: 25, cellWidth: 10) == 3)
        #expect(imageColumnCount(width: 0.5, cellWidth: 10) == 1)
        #expect(imageColumnCount(width: 0, cellWidth: 10) == nil)
        #expect(imageColumnCount(width: 10, cellWidth: .nan) == nil)
        #expect(imageColumnCount(width: .greatestFiniteMagnitude, cellWidth: 1) == nil)
    }

    @Test func extremeMetadataAndInvalidGeometryAreRejectedOrClamped() throws {
        let image = Image(col: 1, columns: Int.max, pixels: 100)
        let result = try #require(geometry(image))
        #expect(result.visibleRect == CGRect(x: 10, y: 20, width: 90, height: 20))
        #expect(geometry(Image(col: Int.min, columns: Int.max, pixels: 100)) == nil)
        #expect(geometry(Image(col: Int.max, columns: 1, pixels: 100)) == nil)
        #expect(geometry(Image(col: -5, columns: 6, pixels: 10)) == nil)
        #expect(geometry(Image(col: 0, columns: 0, pixels: 100)) == nil)
        #expect(geometry(Image(col: 0, columns: 1, pixels: 0)) == nil)
        for cellWidth in [CGFloat.zero, -1, .infinity, .nan] {
            #expect(TerminalBidi.imageGeometry(image, layout: nil, cols: 10,
                                               cellWidth: cellWidth, rowBase: 40) == nil)
        }
    }
}
#endif
