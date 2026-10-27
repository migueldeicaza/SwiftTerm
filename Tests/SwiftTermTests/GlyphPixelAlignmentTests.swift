#if os(macOS) && canImport(MetalKit) && DEBUG
import AppKit
import Metal
import Testing
@testable import SwiftTerm

@MainActor
struct CoreGraphicsGlyphPixelAlignmentTests {
    /// A caret is drawn in its own translated coordinate system. Compare its
    /// actual pixels with the same glyph drawn on the parent's integral grid,
    /// including a double-height transform and a fractional caret origin.
    @Test func caretUsesTheParentDevicePixelGrid() throws {
        let font = try #require(NSFont(name: "Menlo", size: 12))
        let view = TerminalView(frame: .zero, font: font)
        let bounds = CGRect(origin: .zero,
                            size: CGSize(width: view.cellDimension.width, height: view.cellDimension.height))
        let caret = CaretView(frame: bounds, cursorStyle: .steadyBlock, terminal: view)
        caret.renderCursorColor = .white
        caret.renderTextColor = .black
        caret.renderNormalFont = font
        caret.ctline = CTLineCreateWithAttributedString(NSAttributedString(string: "I", attributes: [.font: font]))
        var character = UniChar(73)
        var glyph = CGGlyph(0)
        try #require(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
        let baseline = CellGeometry.baselineOffset(normalFont: font, cellHeight: bounds.height)
        let origin = CGPoint(x: 8.3, y: 8.3)
        for scale: CGFloat in [1, 2, 3] {
            for lineScale: CGFloat in [1, 2] {
                let pixelScale = scale * lineScale
                let size = 192
                func context() throws -> CGContext {
                    let context = try #require(CGContext(data: nil, width: size, height: size,
                                                        bitsPerComponent: 8, bytesPerRow: size * 4,
                                                        space: CGColorSpaceCreateDeviceRGB(),
                                                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                    context.setFillColor(NSColor.white.cgColor)
                    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
                    context.scaleBy(x: pixelScale, y: pixelScale)
                    return context
                }
                let actual = try context()
                actual.translateBy(x: origin.x, y: origin.y)
                withExtendedLifetime(view) { caret.drawCursor(in: actual, hasFocus: true) }
                let expected = try context()
                expected.setFillColor(NSColor.black.cgColor)
                var position = CGPoint(x: (origin.x * pixelScale).rounded() / pixelScale,
                                       y: ((origin.y + baseline) * pixelScale).rounded() / pixelScale)
                CTFontDrawGlyphs(font, &glyph, &position, 1, expected)
                let count = size * size * 4
                let actualData = UnsafeRawBufferPointer(start: try #require(actual.data), count: count)
                let expectedData = UnsafeRawBufferPointer(start: try #require(expected.data), count: count)
                #expect(actualData.elementsEqual(expectedData),
                        "caret raster differs from the parent pixel grid at scale \(pixelScale)")
            }
        }
    }
}

@MainActor
@Suite(.serialized)
struct GlyphPixelAlignmentTests {
    nonisolated static var metalIsUsable: Bool {
        MetalTerminalRenderer.shaderLibraryIsAvailable
    }

    /// Inspect the actual glyph quads sent to Metal, including the plain-row
    /// fast path and the separate block-cursor path. A fractional view height
    /// must not put the integer atlas bitmap between device pixels.
    @Test(.enabled(if: metalIsUsable))
    func rowAndCursorGlyphOriginsUseDevicePixels() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        for scale: CGFloat in [1, 1.5, 2, 3] {
            for plainText in [false, true] {
                let frame = CGRect(x: 0, y: 0, width: 360, height: 140.3)
                let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                let view = TerminalView(frame: frame, font: font)
                view.frameDriver.invalidate()
                view.metalScaleFactorOverride = scale
                view.caretViewTracksFocus = false
                view.feed(text: "ASCII text\r\n\u{1b}[3mitalic\u{1b}[0m symbols\r\n"
                               + "\u{1b}#6double width\r\n\u{1b}#3double height\r\n\u{1b}#4double height\r\n"
                               + "W\u{1b}[1D\u{1b}[2 q")

                let target = TerminalMetalLayerView(frame: frame)
                target.renderDevice = device
                target.metalLayer.framebufferOnly = false
                target.renderContentsScale = scale
                target.renderDrawableSize = CGSize(width: frame.width * scale, height: frame.height * scale)
                let renderer = try MetalTerminalRenderer(target: target)
                renderer.waitForCompletionAfterCommit = true
                renderer.capturesDrawData = true
                renderer.plainTextEnabled = plainText
                #expect(view.renderSnapshotForMetal(renderer: renderer, target: target))
                let data = try #require(renderer.lastDrawData)
                var glyphCount = 0
                for (index, row) in data.rows.enumerated() {
                    guard let buffer = row.glyphGrayBuffer else { continue }
                    let values = buffer.contents().bindMemory(to: TextCell.self, capacity: row.glyphGrayCount)
                    let lowerClip = Float((frame.height - view.cellDimension.height * CGFloat(index + 1)) * scale)
                    let upperClip = lowerClip + Float(view.cellDimension.height * scale)
                    for cell in UnsafeBufferPointer(start: values, count: row.glyphGrayCount) {
                        glyphCount += 1
                        #expect(abs(cell.position.x - cell.position.x.rounded()) < 0.001)
                        let y0 = cell.position.y
                        let y1 = y0 + cell.size.y
                        // DEC double-height rows crop quads at fractional row
                        // boundaries and adjust UVs accordingly. Preserve that
                        // crop, checking the remaining atlas edge's grid.
                        if abs(y0 - y0.rounded()) >= 0.001 {
                            #expect(abs(y0 - lowerClip) < 0.001)
                            #expect(abs(y1 - y1.rounded()) < 0.001 || abs(y1 - upperClip) < 0.001)
                        }
                    }
                }
                try #require(glyphCount > 0)
                let cursor = data.cursorGlyphVerticesGray
                try #require(!cursor.isEmpty)
                let minX = try #require(cursor.map(\.position.x).min())
                let minY = try #require(cursor.map(\.position.y).min())
                #expect(abs(minX - minX.rounded()) < 0.001)
                #expect(abs(minY - minY.rounded()) < 0.001)
            }
        }
    }

    @Test(.enabled(if: metalIsUsable))
    func rowAndCursorGlyphsHaveSameBitmapPlacement() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fontURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app/"
                          + "Contents/Resources/Fonts/SF-Mono-Regular.otf")
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor]
        let descriptor = try #require(descriptors?.first)
        let font = CTFontCreateWithFontDescriptor(descriptor, 16, nil) as NSFont
        let scale: CGFloat = 3

        func expectCursorCopy(buffer: MTLBuffer?, count: Int,
                              cursor: [GlyphVertex], label: String) throws {
            let buffer = try #require(buffer)
            try #require(count == 1)
            try #require(cursor.count == 6)
            let cells = buffer.contents().bindMemory(to: TextCell.self, capacity: count)
            let cell = cells[0]
            for vertex in cursor {
                // The cursor clips its copy to the cell, so compare the
                // position-to-UV mapping rather than the clipped quad origin.
                let expectedU = cell.texOrigin.x
                    + (vertex.position.x - cell.position.x) * cell.texSize.x / cell.size.x
                let expectedV = cell.texOrigin.y
                    + (vertex.position.y - cell.position.y) * cell.texSize.y / cell.size.y
                #expect(abs(vertex.texCoord.x - expectedU) < 0.00001,
                        "\(label) cursor x differs from the row bitmap placement")
                #expect(abs(vertex.texCoord.y - expectedV) < 0.00001,
                        "\(label) cursor y differs from the row bitmap placement")
            }
        }

        for text in ["W", "😀"] {
            let frame = CGRect(x: 0, y: 0, width: 100, height: 40)
            let view = TerminalView(frame: frame, font: font)
            view.frameDriver.invalidate()
            view.metalScaleFactorOverride = scale
            view.caretViewTracksFocus = false
            view.feed(text: "\(text)\u{1b}[1G\u{1b}[2 q")
            #expect(view.cellDimension.width == 10)

            let target = TerminalMetalLayerView(frame: frame)
            target.renderDevice = device
            target.metalLayer.framebufferOnly = false
            target.renderContentsScale = scale
            target.renderDrawableSize = CGSize(width: frame.width * scale, height: frame.height * scale)
            let renderer = try MetalTerminalRenderer(target: target)
            renderer.waitForCompletionAfterCommit = true
            renderer.capturesDrawData = true
            #expect(view.renderSnapshotForMetal(renderer: renderer, target: target))
            let data = try #require(renderer.lastDrawData)
            let row = try #require(data.rows.first)
            if text == "😀" {
                try expectCursorCopy(buffer: row.glyphColorBuffer, count: row.glyphColorCount,
                                     cursor: data.cursorGlyphVerticesColor, label: "color")
            } else {
                try expectCursorCopy(buffer: row.glyphGrayBuffer, count: row.glyphGrayCount,
                                     cursor: data.cursorGlyphVerticesGray, label: "grayscale")
            }
        }
    }
}
#endif
