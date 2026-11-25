#if os(macOS)
import AppKit
import CoreText
import Foundation
import XCTest
@testable import SwiftTerm

final class FontSmoothingRenderingTests: XCTestCase {
    private func totalAlpha(font: CTFont, text: String, smooth: Bool, darkOnLight: Bool) -> Int {
        let rasterizer = CoreTextGlyphRasterizer()
        rasterizer.fontSmoothing = smooth

        let chars = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count))

        var sum = 0
        for glyph in glyphs {
            guard case .bitmap(let bitmap) = rasterizer.rasterize(font: font, glyph: glyph, darkOnLight: darkOnLight) else {
                continue
            }
            XCTAssertFalse(bitmap.isColor)
            var idx = 3
            while idx < bitmap.pixels.count {
                sum += Int(bitmap.pixels[idx])
                idx += 4
            }
        }
        return sum
    }

    func testLightBackgroundSmoothingAvoidsDarkModeDilation() throws {
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, 24.0, nil)
        let unsmoothed = totalAlpha(font: font, text: "Hmnlt0123", smooth: false, darkOnLight: false)
        let unsmoothedLight = totalAlpha(font: font, text: "Hmnlt0123", smooth: false, darkOnLight: true)
        let smoothedLight = totalAlpha(font: font, text: "Hmnlt0123", smooth: true, darkOnLight: true)
        let smoothedDark = totalAlpha(font: font, text: "Hmnlt0123", smooth: true, darkOnLight: false)

        // When font smoothing is off, polarity does not alter rasterized coverage.
        XCTAssertEqual(unsmoothed, unsmoothedLight)
        XCTAssertLessThanOrEqual(unsmoothed, smoothedLight)
        XCTAssertLessThanOrEqual(smoothedLight, smoothedDark)

        // Hosts with AppleFontSmoothing = 0 (or headless CI) produce identical
        // smoothed and unsmoothed coverage; skip strict inequality checks there.
        try XCTSkipIf(smoothedDark == unsmoothed, "Host has macOS font smoothing disabled")
        XCTAssertLessThan(smoothedLight, smoothedDark)
        XCTAssertLessThan(unsmoothed, smoothedLight)
    }

    func testColorFontRemainsColorUnderDarkOnLightSmoothing() {
        let emojiFont = CTFontCreateWithName("AppleColorEmoji" as CFString, 24.0, nil)
        XCTAssertTrue(CoreTextGlyphRasterizer.canContainColorGlyphs(emojiFont))

        let menlo = CTFontCreateWithName("Menlo-Regular" as CFString, 24.0, nil)
        XCTAssertFalse(CoreTextGlyphRasterizer.canContainColorGlyphs(menlo))

        let chars = Array("😀".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(emojiFont, chars, &glyphs, chars.count))

        let rasterizer = CoreTextGlyphRasterizer()
        rasterizer.fontSmoothing = true
        if case .bitmap(let bitmap) = rasterizer.rasterize(font: emojiFont, glyph: glyphs[0], darkOnLight: true) {
            XCTAssertTrue(bitmap.isColor)
        } else {
            XCTFail("Expected colour bitmap for emoji glyph")
        }
    }

    func testGlyphKeySeparatesPolaritiesWithoutEviction() {
        let darkKey = GlyphKey(rasterFontToken: 1, glyph: 42, darkOnLight: false)
        let lightKey = GlyphKey(rasterFontToken: 1, glyph: 42, darkOnLight: true)
        XCTAssertNotEqual(darkKey, lightKey)
    }

    @MainActor
    func testMetalTextBlendingDefaultsAndUpdatesOnViews() {
        let terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        XCTAssertEqual(terminalView.metalTextBlending, .native)
        terminalView.metalTextBlending = .linearCorrected
        XCTAssertEqual(terminalView.metalTextBlending, .linearCorrected)

        let renderView = TerminalRenderView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        XCTAssertEqual(renderView.metalTextBlending, .native)
        renderView.metalTextBlending = .linearCorrected
        XCTAssertEqual(renderView.metalTextBlending, .linearCorrected)
    }
}
#endif
