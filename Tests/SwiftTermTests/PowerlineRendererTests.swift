#if os(macOS)
import CoreGraphics
import XCTest
@testable import SwiftTerm

final class PowerlineRendererTests: XCTestCase {
    func testMapsSupportedPowerlineGlyphsAndRejectsOtherPrivateUseCharacters() throws {
        let rightTriangle = try XCTUnwrap(PowerlineRenderer.glyph(for: 0xE0B0))
        XCTAssertEqual(rightTriangle.direction, .right)
        XCTAssertEqual(rightTriangle.shape, .triangle)
        let leftTriangle = try XCTUnwrap(PowerlineRenderer.glyph(for: 0xE0B2))
        XCTAssertEqual(leftTriangle.direction, .left)
        XCTAssertEqual(leftTriangle.shape, .triangle)
        let rightRounded = try XCTUnwrap(PowerlineRenderer.glyph(for: 0xE0B4))
        XCTAssertEqual(rightRounded.direction, .right)
        XCTAssertEqual(rightRounded.shape, .rounded)
        let leftRounded = try XCTUnwrap(PowerlineRenderer.glyph(for: 0xE0B6))
        XCTAssertEqual(leftRounded.direction, .left)
        XCTAssertEqual(leftRounded.shape, .rounded)
        XCTAssertNil(PowerlineRenderer.glyph(for: 0xE0B1))
        XCTAssertNil(PowerlineRenderer.glyph(for: 0xE0B3))
        XCTAssertNil(PowerlineRenderer.glyph(for: 0xE0B5))
        XCTAssertNil(PowerlineRenderer.glyph(for: 0xE0B7))
        XCTAssertNil(PowerlineRenderer.glyph(for: 0xE0C0))
    }

    func testCustomGlyphSettingControlsPowerlineRendering() {
        XCTAssertTrue(PowerlineRenderer.shouldRender(codePoint: 0xE0B0, customGlyphsEnabled: true))
        XCTAssertFalse(PowerlineRenderer.shouldRender(codePoint: 0xE0B0, customGlyphsEnabled: false))
        XCTAssertFalse(PowerlineRenderer.shouldRender(codePoint: 0xE0C0, customGlyphsEnabled: true))
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

    private enum Direction { case left, right }

    private struct Bitmap {
        let width: Int
        let height: Int
        let cellMinX: Int
        let cellMaxX: Int
        let alpha: [UInt8]

        subscript(_ x: Int, _ y: Int) -> UInt8 { alpha[y * width + x] }
    }

    private func bitmap(codePoint: UInt32, scale: Int, horizontalTransform: Int = 1) throws -> Bitmap {
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
                                   color: CGColor(gray: 1, alpha: 1))
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

    private func assertHasAntialiasedEdge(_ bitmap: Bitmap, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(bitmap.alpha.contains(where: { $0 > 0 && $0 < 255 }),
                      "sloped and rounded outer edges should remain antialiased",
                      file: file,
                      line: line)
    }
}
#endif
