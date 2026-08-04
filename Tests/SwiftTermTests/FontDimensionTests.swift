#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

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
}
#endif
