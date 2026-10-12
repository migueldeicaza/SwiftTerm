#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

@MainActor
final class FontDimensionTests {
    @Test func cellWidthSnapsToNearestDevicePixel() throws {
        let font = try #require(NSFont(name: "Monaco", size: 12))
        let view = TerminalView(frame: .zero, font: font)
        let glyph = font.glyph(withName: "W")
        let advance = font.advancement(forGlyph: glyph).width
        let scale = view.backingScaleFactor()
        let expectedWidth = (advance * scale).rounded() / scale

        #expect(view.cellDimension.width == expectedWidth)
        #expect((view.cellDimension.width * scale).rounded() == view.cellDimension.width * scale)
    }

    /// STHeiti, like many CJK fonts, has no glyph named "W", so the cell width
    /// must come from the glyph for the character W, not from .notdef.
    @Test func cellWidthComesFromTheCharacterWInFontsWithoutGlyphNames() throws {
        let font = try #require(NSFont(name: "STHeitiSC-Light", size: 24))
        #expect(font.glyph(withName: "W") == 0)

        var characters: [UniChar] = [0x57]
        var glyphs: [CGGlyph] = [0]
        #expect(CTFontGetGlyphsForCharacters(font as CTFont, &characters, &glyphs, 1))
        let advance = font.advancement(forGlyph: NSGlyph(glyphs[0])).width

        let view = TerminalView(frame: .zero, font: font)
        let scale = view.backingScaleFactor()
        #expect(view.cellDimension.width == (advance * scale).rounded() / scale)
        #expect(view.cellDimension.width < font.pointSize)
    }
}
#endif
