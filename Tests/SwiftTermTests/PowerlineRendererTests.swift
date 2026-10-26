#if os(macOS)
import CoreGraphics
import XCTest
@testable import SwiftTerm

final class PowerlineRendererTests: XCTestCase {
    func testMapsSupportedPowerlineGlyphsAndRejectsOtherPrivateUseCharacters() throws {
        let expected: [(UInt32, PowerlineRenderer.Direction, PowerlineRenderer.Shape)] = [
            (0xE0B0, .right, .triangle),
            (0xE0B1, .right, .triangleOutline),
            (0xE0B2, .left, .triangle),
            (0xE0B3, .left, .triangleOutline),
            (0xE0B4, .right, .rounded),
            (0xE0B5, .right, .roundedOutline),
            (0xE0B6, .left, .rounded),
            (0xE0B7, .left, .roundedOutline),
            (0xE0B8, .right, .slantLower),
            (0xE0B9, .right, .diagonalBack),
            (0xE0BA, .left, .slantLower),
            (0xE0BB, .left, .diagonalForward),
            (0xE0BC, .right, .slantUpper),
            (0xE0BD, .left, .diagonalForward),
            (0xE0BE, .left, .slantUpper),
            (0xE0BF, .right, .diagonalBack),
            (0xE0C0, .right, .flame),
            (0xE0C1, .right, .flameOutline),
            (0xE0C2, .left, .flame),
            (0xE0C3, .left, .flameOutline),
            (0xE0D6, .left, .triangleInverse),
            (0xE0D7, .right, .triangleInverse),
        ]
        for (codePoint, direction, shape) in expected {
            let glyph = try XCTUnwrap(PowerlineRenderer.glyph(for: codePoint),
                                      "U+\(String(codePoint, radix: 16)) must be covered")
            XCTAssertEqual(glyph.direction, direction, "U+\(String(codePoint, radix: 16))")
            XCTAssertEqual(glyph.shape, shape, "U+\(String(codePoint, radix: 16))")
        }
        // Pixelated squares, ice waveform, honeycomb, lego and trapezoid
        // glyphs are not procedurally rendered yet, and neither are the
        // non-separator powerline symbols.
        for codePoint: UInt32 in [0xE0A0, 0xE0A1, 0xE0A2, 0xE0A3,
                                  0xE0C4, 0xE0C5, 0xE0C6, 0xE0C7,
                                  0xE0C8, 0xE0CA, 0xE0CC, 0xE0CD,
                                  0xE0CE, 0xE0CF, 0xE0D0, 0xE0D1,
                                  0xE0D2, 0xE0D4, 0xE0D8, 0xE0FF] {
            XCTAssertNil(PowerlineRenderer.glyph(for: codePoint),
                         "U+\(String(codePoint, radix: 16)) must stay on the font path")
        }
        XCTAssertNil(PowerlineRenderer.glyph(for: 0x0041))
    }

    func testJoinOverdrawOnlyAppliesToSolidJoinEdges() {
        for codePoint: UInt32 in [0xE0B0, 0xE0B2, 0xE0B4, 0xE0B6,
                                  0xE0B8, 0xE0BA, 0xE0BC, 0xE0BE,
                                  0xE0C0, 0xE0C2] {
            let glyph = PowerlineRenderer.glyph(for: codePoint)
            XCTAssertEqual(glyph?.hasSolidJoinEdge, true, "U+\(String(codePoint, radix: 16))")
            XCTAssertNotNil(PowerlineRenderer.devicePixelJoinRect(
                codePoint: codePoint,
                transformedCellRect: CGRect(x: 20, y: 10, width: 32, height: 48)),
                "U+\(String(codePoint, radix: 16))")
        }
        // Thin and inverse shapes have no full-height edge adjoining a
        // same-colored neighbor: overdrawing would paint a visible stripe.
        for codePoint: UInt32 in [0xE0B1, 0xE0B3, 0xE0B5, 0xE0B7,
                                  0xE0B9, 0xE0BB, 0xE0BD, 0xE0BF,
                                  0xE0C1, 0xE0C3, 0xE0D6, 0xE0D7] {
            let glyph = PowerlineRenderer.glyph(for: codePoint)
            XCTAssertEqual(glyph?.hasSolidJoinEdge, false, "U+\(String(codePoint, radix: 16))")
            XCTAssertNil(PowerlineRenderer.devicePixelJoinRect(
                codePoint: codePoint,
                transformedCellRect: CGRect(x: 20, y: 10, width: 32, height: 48)),
                "U+\(String(codePoint, radix: 16))")
        }
    }

    func testCustomGlyphSettingControlsPowerlineRendering() {
        XCTAssertTrue(PowerlineRenderer.shouldRender(codePoint: 0xE0B0, customGlyphsEnabled: true))
        XCTAssertFalse(PowerlineRenderer.shouldRender(codePoint: 0xE0B0, customGlyphsEnabled: false))
        XCTAssertTrue(PowerlineRenderer.shouldRender(codePoint: 0xE0C0, customGlyphsEnabled: true))
        XCTAssertFalse(PowerlineRenderer.shouldRender(codePoint: 0xE0C4, customGlyphsEnabled: true))
    }

    func testTriangleDirectionsAndJoinOverdrawAtTwoAndThreeX() throws {
        for scale in [2, 3] {
            let right = try bitmap(codePoint: 0xE0B0, scale: scale)
            let left = try bitmap(codePoint: 0xE0B2, scale: scale)
            assertTriangle(right, direction: .right)
            assertTriangle(left, direction: .left)
            assertHasAntialiasedEdge(right)
            assertHasAntialiasedEdge(left)
            assertJoinOverdraw(right, direction: .right)
            assertJoinOverdraw(left, direction: .left)
        }
    }

    func testRoundedDirectionsAndJoinOverdrawAtTwoAndThreeX() throws {
        for scale in [2, 3] {
            let right = try bitmap(codePoint: 0xE0B4, scale: scale)
            let left = try bitmap(codePoint: 0xE0B6, scale: scale)
            assertRounded(right, direction: .right)
            assertRounded(left, direction: .left)
            assertHasAntialiasedEdge(right)
            assertHasAntialiasedEdge(left)
            assertJoinOverdraw(right, direction: .right)
            assertJoinOverdraw(left, direction: .left)
        }
    }

    func testThinTrianglesStrokeOnlyTheSlopedEdges() throws {
        for scale in [2, 3] {
            let right = try bitmap(codePoint: 0xE0B1, scale: scale)
            let left = try bitmap(codePoint: 0xE0B3, scale: scale)
            for (bitmap, direction) in [(right, Direction.right), (left, Direction.left)] {
                let joinColumn = direction == .right ? bitmap.cellMinX : bitmap.cellMaxX - 1
                let tipColumn = direction == .right ? bitmap.cellMaxX - 1 : bitmap.cellMinX
                let midY = bitmap.height / 2
                // The flat edge is not filled...
                XCTAssertLessThan(bitmap[joinColumn, midY], 32, file: #filePath, line: #line)
                // ...the stroke passes through the tip at mid-height...
                XCTAssertGreaterThan(bitmap[tipColumn, midY], 0, file: #filePath, line: #line)
                // ...and there is no join overdraw outside the cell.
                assertNoJoinOverdraw(bitmap, direction: direction)
            }
        }
    }

    func testThinHalfCirclesStrokeAnArc() throws {
        for scale in [2, 3] {
            for (codePoint, direction) in [(UInt32(0xE0B5), Direction.right), (UInt32(0xE0B6 + 1), Direction.left)] {
                let bitmap = try bitmap(codePoint: codePoint, scale: scale)
                let joinColumn = direction == .right ? bitmap.cellMinX : bitmap.cellMaxX - 1
                let midY = bitmap.height / 2
                // Flat edge empty at mid-height; the arc bulges to ~3/4 width.
                XCTAssertLessThan(bitmap[joinColumn, midY], 32)
                let bulgeX = direction == .right
                    ? bitmap.cellMinX + (bitmap.cellMaxX - bitmap.cellMinX) * 3 / 4
                    : bitmap.cellMaxX - 1 - (bitmap.cellMaxX - bitmap.cellMinX) * 3 / 4
                var bulgeCoverage = 0
                for x in (bulgeX - 1)...(bulgeX + 1) {
                    bulgeCoverage += Int(bitmap[x, midY])
                }
                XCTAssertGreaterThan(bulgeCoverage, 0)
                assertNoJoinOverdraw(bitmap, direction: direction)
            }
        }
    }

    func testSlantTrianglesFillTheCorrectHalf() throws {
        for scale in [2, 3] {
            // E0B8: lower-left triangle, flat edge on the left.
            let lowerLeft = try bitmap(codePoint: 0xE0B8, scale: scale)
            let midX = (lowerLeft.cellMinX + lowerLeft.cellMaxX - 1) / 2
            let midY = lowerLeft.height / 2
            XCTAssertEqual(lowerLeft[lowerLeft.cellMinX, lowerLeft.height - 1], 255)
            XCTAssertEqual(lowerLeft[midX, lowerLeft.height - 1], 255)
            XCTAssertEqual(lowerLeft[lowerLeft.cellMinX, midY], 255)
            XCTAssertLessThan(lowerLeft[lowerLeft.cellMaxX - 1, 0], 32)
            XCTAssertLessThan(lowerLeft[lowerLeft.cellMaxX - 1, midY], 32)
            assertJoinOverdraw(lowerLeft, direction: .right)
            assertHasAntialiasedEdge(lowerLeft)

            // E0BA: lower-right triangle, flat edge on the right.
            let lowerRight = try bitmap(codePoint: 0xE0BA, scale: scale)
            XCTAssertEqual(lowerRight[lowerRight.cellMaxX - 1, lowerRight.height - 1], 255)
            XCTAssertEqual(lowerRight[midX, lowerRight.height - 1], 255)
            XCTAssertEqual(lowerRight[lowerRight.cellMaxX - 1, midY], 255)
            XCTAssertLessThan(lowerRight[lowerRight.cellMinX, 0], 32)
            XCTAssertLessThan(lowerRight[lowerRight.cellMinX, midY], 32)
            assertJoinOverdraw(lowerRight, direction: .left)

            // E0BC: upper-left triangle, flat edge on the left.
            let upperLeft = try bitmap(codePoint: 0xE0BC, scale: scale)
            XCTAssertEqual(upperLeft[upperLeft.cellMinX, 0], 255)
            XCTAssertEqual(upperLeft[midX, 0], 255)
            XCTAssertEqual(upperLeft[upperLeft.cellMinX, midY], 255)
            XCTAssertLessThan(upperLeft[upperLeft.cellMaxX - 1, upperLeft.height - 1], 32)
            XCTAssertLessThan(upperLeft[upperLeft.cellMaxX - 1, midY], 32)
            assertJoinOverdraw(upperLeft, direction: .right)

            // E0BE: upper-right triangle, flat edge on the right.
            let upperRight = try bitmap(codePoint: 0xE0BE, scale: scale)
            XCTAssertEqual(upperRight[upperRight.cellMaxX - 1, 0], 255)
            XCTAssertEqual(upperRight[midX, 0], 255)
            XCTAssertEqual(upperRight[upperRight.cellMaxX - 1, midY], 255)
            XCTAssertLessThan(upperRight[upperRight.cellMinX, upperRight.height - 1], 32)
            XCTAssertLessThan(upperRight[upperRight.cellMinX, midY], 32)
            assertJoinOverdraw(upperRight, direction: .left)
        }
    }

    func testThinShapesHonorProductionStrokeWidth() throws {
        // Production passes the box-drawing light-line thickness (a few device
        // pixels), not a hairline; the stroke must actually reach that width.
        let scale = 2
        let lineWidthPx = 2 * scale
        let thick = try bitmap(codePoint: 0xE0B9, scale: scale, lineWidthPx: lineWidthPx)
        let hairline = try bitmap(codePoint: 0xE0B9, scale: scale)
        let midX = (thick.cellMinX + thick.cellMaxX - 1) / 2
        let midY = thick.height / 2

        // The center of the stroke is fully covered at production thickness.
        XCTAssertEqual(thick[midX, midY], 255)

        func strokeRun(_ bitmap: Bitmap) -> Int {
            var run = 0
            var x = midX
            while x >= bitmap.cellMinX, bitmap[x, midY] > 0 { run += 1; x -= 1 }
            x = midX + 1
            while x < bitmap.cellMaxX, bitmap[x, midY] > 0 { run += 1; x += 1 }
            return run
        }
        // A 4-device-px stroke on a 16x24 cell diagonal spans ~5 px across the
        // row; the hairline spans 1-2. Both must stay inside the cell.
        XCTAssertGreaterThanOrEqual(strokeRun(thick), lineWidthPx - 1)
        XCTAssertLessThan(strokeRun(hairline), strokeRun(thick))
        assertNoJoinOverdraw(thick, direction: .right)
    }

    func testThinDiagonalsStrokeCornerToCorner() throws {
        for scale in [2, 3] {
            // E0B9 "\": top-left to bottom-right; E0BB "/": bottom-left to top-right.
            let back = try bitmap(codePoint: 0xE0B9, scale: scale)
            let forward = try bitmap(codePoint: 0xE0BB, scale: scale)
            let midX = (back.cellMinX + back.cellMaxX - 1) / 2
            let midY = back.height / 2
            XCTAssertGreaterThan(back[midX, midY], 0)
            XCTAssertGreaterThan(forward[midX, midY], 0)
            // Diagonals never touch the left/right edges with a solid column.
            assertNoJoinOverdraw(back, direction: .right)
            assertNoJoinOverdraw(forward, direction: .left)
        }
    }

    func testFlameFillsFlatEdgeAndLicksOutward() throws {
        for scale in [2, 3] {
            let right = try bitmap(codePoint: 0xE0C0, scale: scale)
            // The flat joining edge is covered for the full height (the
            // flame's organic edge wobbles by a fraction of a pixel, so allow
            // a little antialiasing slack).
            assertCoveredColumn(right, x: right.cellMinX)
            assertJoinOverdraw(right, direction: .right)
            assertHasAntialiasedEdge(right)
            // The flame does not fill the whole cell: the outer half has gaps.
            var outerFilled = 0
            for y in 0..<right.height {
                if right[right.cellMaxX - 2, y] > 0 { outerFilled += 1 }
            }
            XCTAssertLessThan(outerFilled, right.height / 2)

            // The mirrored flame covers the right edge instead.
            let left = try bitmap(codePoint: 0xE0C2, scale: scale)
            assertCoveredColumn(left, x: left.cellMaxX - 1)
            assertJoinOverdraw(left, direction: .left)
        }
    }

    func testThinFlameStrokesTheSilhouetteWithoutJoinOverdraw() throws {
        for scale in [2, 3] {
            let bitmap = try bitmap(codePoint: 0xE0C1, scale: scale)
            assertHasAntialiasedEdge(bitmap)
            XCTAssertTrue(bitmap.alpha.contains(where: { $0 > 0 }))
            assertNoJoinOverdraw(bitmap, direction: .right)
        }
    }

    func testThinFlamesLeaveFlatEdgeEmpty() throws {
        for scale in [2, 3] {
            for (codePoint, direction) in [(UInt32(0xE0C1), Direction.right),
                                           (UInt32(0xE0C3), Direction.left)] {
                let bitmap = try bitmap(codePoint: codePoint, scale: scale)
                let flatEdgeX = direction == .right ? bitmap.cellMinX : bitmap.cellMaxX - 1
                for y in 3..<(bitmap.height - 3) {
                    XCTAssertEqual(bitmap[flatEdgeX, y], 0,
                                   "U+\(String(codePoint, radix: 16)) must not stroke a flat edge at (\(flatEdgeX), \(y))")
                }
            }
        }
    }

    func testInverseDividersFillTheCellAndCutOutTheArrow() throws {
        for scale in [2, 3] {
            // E0D6: full cell minus the left-pointing arrow (flat edge right).
            let inverseLeft = try bitmap(codePoint: 0xE0D6, scale: scale)
            let midX = (inverseLeft.cellMinX + inverseLeft.cellMaxX - 1) / 2
            let midY = inverseLeft.height / 2
            XCTAssertEqual(inverseLeft[inverseLeft.cellMinX + 1, 1], 255)
            XCTAssertEqual(inverseLeft[inverseLeft.cellMinX + 1, inverseLeft.height - 2], 255)
            XCTAssertLessThan(inverseLeft[inverseLeft.cellMaxX - 2, midY], 32)
            XCTAssertLessThan(inverseLeft[inverseLeft.cellMaxX - 2, midY - 4], 32)
            XCTAssertLessThan(inverseLeft[inverseLeft.cellMaxX - 2, midY + 4], 32)
            // The cutout widens from the tip: mid-cell at mid-height is empty.
            XCTAssertLessThan(inverseLeft[midX, midY], 32)
            assertNoJoinOverdraw(inverseLeft, direction: .left)

            // E0D7 mirrors the cutout.
            let inverseRight = try bitmap(codePoint: 0xE0D7, scale: scale)
            XCTAssertEqual(inverseRight[inverseRight.cellMaxX - 2, 1], 255)
            XCTAssertEqual(inverseRight[inverseRight.cellMaxX - 2, inverseRight.height - 2], 255)
            XCTAssertLessThan(inverseRight[inverseRight.cellMinX + 1, midY], 32)
            XCTAssertLessThan(inverseRight[midX, midY], 32)
            assertNoJoinOverdraw(inverseRight, direction: .right)
        }
    }

    func testJoinOverdrawRemainsOneDevicePixelAfterDoubleWidthTransform() throws {
        for scale in [2, 3] {
            let right = try bitmap(codePoint: 0xE0B0, scale: scale, horizontalTransform: 2)
            let left = try bitmap(codePoint: 0xE0B2, scale: scale, horizontalTransform: 2)
            assertJoinOverdraw(right, direction: .right)
            assertJoinOverdraw(left, direction: .left)
        }

        let transformedCell = CGRect(x: 20, y: 10, width: 32, height: 48)
        let rightMetalJoin = try XCTUnwrap(PowerlineRenderer.devicePixelJoinRect(codePoint: 0xE0B0,
                                                                                 transformedCellRect: transformedCell))
        XCTAssertEqual(rightMetalJoin, CGRect(x: 19, y: 10, width: 1, height: 48))
        let leftMetalJoin = try XCTUnwrap(PowerlineRenderer.devicePixelJoinRect(codePoint: 0xE0B2,
                                                                                transformedCellRect: transformedCell))
        XCTAssertEqual(leftMetalJoin, CGRect(x: 52, y: 10, width: 1, height: 48))
    }

    func testAtlasRasterizationDoesNotPaintJoinStrip() throws {
        // Metal stores a cell-sized mask and emits the join strip separately
        // after the DEC transform. The atlas must not contain that strip.
        for codePoint: UInt32 in Array(0xE0B0...0xE0BF) + Array(0xE0C0...0xE0C3) + [0xE0D6, 0xE0D7] {
            let rendered = try bitmap(codePoint: codePoint, scale: 2, includeJoinOverdraw: false)
            for y in 0..<rendered.height {
                XCTAssertEqual(rendered[rendered.cellMinX - 1, y], 0)
                XCTAssertEqual(rendered[rendered.cellMaxX, y], 0)
            }
        }
    }

    private enum Direction { case left, right }

    private struct Bitmap {
        let width: Int
        let height: Int
        let cellMinX: Int
        let cellMaxX: Int
        let alpha: [UInt8]

        subscript(_ x: Int, _ y: Int) -> UInt8 { alpha[y * width + x] }
    }

    private func bitmap(codePoint: UInt32, scale: Int, horizontalTransform: Int = 1, lineWidthPx: Int = 0, includeJoinOverdraw: Bool = true) throws -> Bitmap {
        let cellWidth = 8 * scale * horizontalTransform
        let cellHeight = 12 * scale
        let width = cellWidth + 2
        var pixels = Array(repeating: UInt8(0), count: width * cellHeight * 4)
        let created = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base,
                                          width: width,
                                          height: cellHeight,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            let scaleX = CGFloat(scale * horizontalTransform)
            context.scaleBy(x: scaleX, y: CGFloat(scale))
            let rect = CGRect(x: 1.0 / scaleX,
                              y: 0,
                              width: 8,
                              height: CGFloat(cellHeight) / CGFloat(scale))
            PowerlineRenderer.draw(codePoint: codePoint,
                                   in: context,
                                   cellRect: rect,
                                   scaleX: scaleX,
                                   scaleY: CGFloat(scale),
                                   color: CGColor(gray: 1, alpha: 1),
                                   lineWidthPx: lineWidthPx,
                                   includeJoinOverdraw: includeJoinOverdraw)
            return true
        }
        XCTAssertTrue(created)
        var alpha = Array(repeating: UInt8(0), count: width * cellHeight)
        for index in alpha.indices { alpha[index] = pixels[index * 4 + 3] }
        return Bitmap(width: width, height: cellHeight, cellMinX: 1, cellMaxX: 1 + cellWidth, alpha: alpha)
    }

    private func assertTriangle(_ bitmap: Bitmap, direction: Direction, file: StaticString = #filePath, line: UInt = #line) {
        let midY = bitmap.height / 2
        let outerX = direction == .right ? bitmap.cellMaxX - 1 : bitmap.cellMinX
        XCTAssertGreaterThan(bitmap[outerX, midY], 0, file: file, line: line)
        XCTAssertLessThan(bitmap[outerX, midY], 255, file: file, line: line)
        XCTAssertLessThan(bitmap[outerX, 0], 32, file: file, line: line)
        XCTAssertLessThan(bitmap[outerX, bitmap.height - 1], 32, file: file, line: line)
    }

    private func assertRounded(_ bitmap: Bitmap, direction: Direction, file: StaticString = #filePath, line: UInt = #line) {
        let midY = bitmap.height / 2
        let outerX = direction == .right ? bitmap.cellMaxX - 1 : bitmap.cellMinX
        XCTAssertGreaterThan(bitmap[outerX, midY], 128, file: file, line: line)
        XCTAssertLessThan(bitmap[outerX, 0], 32, file: file, line: line)
    }

    private func assertJoinOverdraw(_ bitmap: Bitmap, direction: Direction, file: StaticString = #filePath, line: UInt = #line) {
        let joinX = direction == .right ? bitmap.cellMinX - 1 : bitmap.cellMaxX
        for y in 0..<bitmap.height {
            XCTAssertEqual(bitmap[joinX, y], 255, "join edge must cover exactly one adjacent physical pixel", file: file, line: line)
        }
        let beyondJoinX = direction == .right ? joinX - 1 : joinX + 1
        if beyondJoinX >= 0 && beyondJoinX < bitmap.width {
            for y in 0..<bitmap.height {
                XCTAssertEqual(bitmap[beyondJoinX, y], 0, "renderer must not overdraw beyond one physical pixel", file: file, line: line)
            }
        }
    }

    private func assertNoJoinOverdraw(_ bitmap: Bitmap, direction: Direction, file: StaticString = #filePath, line: UInt = #line) {
        let joinX = direction == .right ? bitmap.cellMinX - 1 : bitmap.cellMaxX
        guard joinX >= 0 && joinX < bitmap.width else { return }
        for y in 0..<bitmap.height {
            XCTAssertEqual(bitmap[joinX, y], 0, "thin/inverse shapes must not overdraw the neighbor cell", file: file, line: line)
        }
    }

    private func assertCoveredColumn(_ bitmap: Bitmap, x: Int, file: StaticString = #filePath, line: UInt = #line) {
        for y in 0..<bitmap.height {
            XCTAssertGreaterThanOrEqual(bitmap[x, y], 200, "column \(x) must be covered for the full cell height", file: file, line: line)
        }
    }

    private func assertHasAntialiasedEdge(_ bitmap: Bitmap, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(bitmap.alpha.contains(where: { $0 > 0 && $0 < 255 }),
                      "sloped and rounded outer edges should remain antialiased",
                      file: file,
                      line: line)
    }
}
#endif
