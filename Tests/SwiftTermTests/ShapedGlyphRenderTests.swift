//
//  ShapedGlyphRenderTests.swift
//
//  Regression coverage for shaped runs whose glyph count differs from their
//  source cell count. Avenir Next shapes `ffi` into fewer glyphs than cells,
//  so runs must be mapped back to cells through the segment's UTF-16 to cell
//  map: a run positioned by counting glyphs drops the ligature's background
//  and underline and draws the next run against the wrong column. Both
//  renderers are covered — Core Graphics through `cacheDisplay`, Metal
//  through the headless target.
//
#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

/// Offscreen Core Graphics render and pixel-to-cell helpers.
@MainActor
private enum RenderTestSupport {
    /// Paints `view` into an offscreen bitmap through the Core Graphics path.
    static func render(_ view: TerminalView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Bitmap pixels covering `columns`, as a half-open range.
    static func pixelRange(in rep: NSBitmapImageRep,
                           view: TerminalView,
                           columns: Range<Int>) -> Range<Int> {
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let x0 = max(0, Int(CGFloat(columns.lowerBound) * view.cellDimension.width * scale))
        let x1 = min(rep.pixelsWide, Int(CGFloat(columns.upperBound) * view.cellDimension.width * scale))
        guard x0 < x1 else { return 0..<0 }
        return x0..<x1
    }

    /// Bitmap pixels covering terminal cell `column`, as a half-open range.
    static func pixelColumns(in rep: NSBitmapImageRep,
                             view: TerminalView,
                             column: Int) -> Range<Int> {
        pixelRange(in: rep, view: view, columns: column..<(column + 1))
    }

    /// Number of pixels in `columns` whose color satisfies `matches`.
    static func pixelCount(in rep: NSBitmapImageRep,
                           columns: Range<Int>,
                           matches: (NSColor) -> Bool) -> Int {
        columns.reduce(into: 0) { count, x in
            for y in 0..<rep.pixelsHigh where matches(rep.colorAt(x: x, y: y) ?? .clear) {
                count += 1
            }
        }
    }

    /// Number of pixels in cell `column` whose color satisfies `matches`.
    static func pixelCount(in rep: NSBitmapImageRep,
                           view: TerminalView,
                           column: Int,
                           matches: (NSColor) -> Bool) -> Int {
        pixelCount(in: rep,
                   columns: pixelColumns(in: rep, view: view, column: column),
                   matches: matches)
    }
}

@MainActor
struct ShapedGlyphRenderTests {
    /// Red background and blue underline over `ffi`, then a green `X` on the
    /// default background. Red and blue mark the cells the ligature came
    /// from; green marks the cell `X` is drawn on.
    private static let ligatedRow =
        "\u{1b}[48;2;255;0;0m\u{1b}[58;2;0;0;255m\u{1b}[4mffi\u{1b}[24;49m\u{1b}[38;2;0;255;0mX"

    /// A wide character with a blue underline; the glyph keeps the default
    /// foreground, so blue in the bitmap can only be decoration ink.
    private static let wideUnderlinedRow = "\u{1b}[58;2;0;0;255m\u{1b}[4m日"

    /// A green `ﬃ` (U+FB03). Menlo has no glyph for it, so CoreText takes it
    /// from Lucida Grande, whose glyph is about 1.6 Menlo cells wide.
    private static let fallbackLigatureRow = "\u{1b}[38;2;0;255;0m\u{FB03}"

    /// A green Devanagari conjunct: one fallback glyph covering two cells,
    /// which must keep its two-cell span rather than be fitted to one.
    private static let conjunctRow = "\u{1b}[38;2;0;255;0mक्ष"

    private func makeView(feeding text: String,
                          font: String = "AvenirNext-Regular") -> TerminalView {
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 200),
            font: NSFont(name: font, size: 14))
        view.nativeBackgroundColor = .black
        view.feed(text: text)
        view.frameTick()
        return view
    }

    private func isRed(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        return rgb.redComponent > 0.7 && rgb.greenComponent < 0.3 && rgb.blueComponent < 0.3
    }

    private func isGreen(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        return rgb.greenComponent > 0.7 && rgb.redComponent < 0.3 && rgb.blueComponent < 0.3
    }

    private func isBlue(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        return rgb.blueComponent > 0.7 && rgb.redComponent < 0.3 && rgb.greenComponent < 0.3
    }

    /// The defect only exists while the font ligates `ffi`. Assert that here
    /// so a future font that stops ligating fails loudly instead of leaving
    /// a test that passes on a row with nothing to shape.
    private func assertLigaturePrecondition(_ view: TerminalView) throws {
        let info = view.withTerminal { terminal in
            view.buildAttributedStringLocked(row: 0,
                                             line: terminal.buffer.lines[0],
                                             cols: terminal.cols)
        }
        let segment = try #require(info.segments.first)
        let line = CTLineCreateWithAttributedString(segment.attributedString)
        let glyphCount = (CTLineGetGlyphRuns(line) as? [CTRun] ?? [])
            .reduce(0) { $0 + CTRunGetGlyphCount($1) }
        #expect(glyphCount < segment.attributedString.length,
                "\"\(segment.attributedString.string)\" no longer shapes into fewer glyphs than cells")
    }

    @Test func coreGraphicsShapedRunCoversAllSourceCells() throws {
        let view = makeView(feeding: Self.ligatedRow)
        try assertLigaturePrecondition(view)
        let rep = try #require(RenderTestSupport.render(view))

        func red(_ column: Int) -> Int {
            RenderTestSupport.pixelCount(in: rep, view: view, column: column,
                                         matches: { self.isRed($0) })
        }
        func green(_ column: Int) -> Int {
            RenderTestSupport.pixelCount(in: rep, view: view, column: column,
                                         matches: { self.isGreen($0) })
        }

        // The ligature's background spans every source cell it covers.
        #expect(red(0) > 0)
        #expect(red(1) > 0)
        #expect(red(2) > 0)
        #expect(red(3) == 0)
        // So does its underline; the middle half of the cell skips any
        // antialiasing spill from the previous cell's stroke.
        let lastCell = RenderTestSupport.pixelRange(in: rep, view: view, columns: 2..<3)
        let lastCellMiddle = (lastCell.lowerBound + lastCell.count / 4)..<(lastCell.upperBound - lastCell.count / 4)
        #expect(RenderTestSupport.pixelCount(in: rep, columns: lastCellMiddle,
                                             matches: { self.isBlue($0) }) > 0)
        // And the shaped-down run does not pull the next glyph leftwards.
        #expect(green(3) > 0)
        #expect(green(2) == 0)
    }

    /// A decoration covers the cell it is drawn for, wide or not: a stroke
    /// one column wide leaves the right half of a double-width cell bare.
    /// A fallback glyph wider than its single cell is shrunk to the cell
    /// instead of painting over the next one.
    @Test func coreGraphicsFallbackGlyphStaysInItsCell() throws {
        let view = makeView(feeding: Self.fallbackLigatureRow, font: "Menlo-Regular")
        let rep = try #require(RenderTestSupport.render(view))
        func green(_ column: Int) -> Int {
            RenderTestSupport.pixelCount(in: rep, view: view, column: column,
                                         matches: { self.isGreen($0) })
        }
        #expect(green(0) > 0)
        #expect(green(1) == 0)
    }

    @Test func coreGraphicsFallbackConjunctKeepsItsCells() throws {
        let view = makeView(feeding: Self.conjunctRow, font: "Menlo-Regular")
        let rep = try #require(RenderTestSupport.render(view))
        #expect(RenderTestSupport.pixelCount(in: rep, view: view, column: 1,
                                             matches: { self.isGreen($0) }) > 0)
    }

    @Test func coreGraphicsWideCellDecorationSpansItsColumns() throws {
        let view = makeView(feeding: Self.wideUnderlinedRow)
        let rep = try #require(RenderTestSupport.render(view))

        let secondColumn = RenderTestSupport.pixelRange(in: rep, view: view, columns: 1..<2)
        try #require(!secondColumn.isEmpty)
        let rightHalf = (secondColumn.lowerBound + secondColumn.count / 2)..<secondColumn.upperBound

        #expect(RenderTestSupport.pixelCount(in: rep, view: view, column: 0,
                                             matches: { self.isBlue($0) }) > 0)
        #expect(RenderTestSupport.pixelCount(in: rep, columns: rightHalf,
                                             matches: { self.isBlue($0) }) > 0)
    }
}

#if canImport(MetalKit)
import Metal
import MetalKit

extension ShapedGlyphRenderTests {
    /// One rendered Metal frame, read back for pixel assertions.
    private struct MetalFrame {
        let pixels: [UInt8]
        let bytesPerRow: Int
        let width: Int
        let height: Int
        let isBGRA: Bool
        let scale: CGFloat
        let cellWidth: CGFloat

        /// Pixel columns covering terminal cells `columns`.
        func pixelColumns(_ columns: Range<Int>) -> Range<Int> {
            let x0 = max(0, Int(CGFloat(columns.lowerBound) * cellWidth * scale))
            let x1 = min(width, Int(CGFloat(columns.upperBound) * cellWidth * scale))
            guard x0 < x1 else { return 0..<0 }
            return x0..<x1
        }

        func count(inPixels columns: Range<Int>,
                   matches: (UInt8, UInt8, UInt8) -> Bool) -> Int {
            var matched = 0
            for y in 0..<height {
                for x in columns {
                    let index = (y * bytesPerRow) + (x * 4)
                    if matches(pixels[index + (isBGRA ? 2 : 0)],
                               pixels[index + 1],
                               pixels[index + (isBGRA ? 0 : 2)]) {
                        matched += 1
                    }
                }
            }
            return matched
        }

        func count(inColumns columns: Range<Int>,
                   matches: (UInt8, UInt8, UInt8) -> Bool) -> Int {
            count(inPixels: pixelColumns(columns), matches: matches)
        }
    }

    /// Renders `view` through the Metal renderer, which is the macOS host's
    /// default path. Returns nil rather than failing when the environment
    /// offers no usable device or drawable, like the other Metal suites.
    private func metalFrame(of view: TerminalView) -> MetalFrame? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        // The snapshot draws at the view's rendering scale, so the drawable
        // has to match it or every row lands outside the texture.
        let renderingScale = view.metalRenderingScaleFactor()
        let layerView = TerminalMetalLayerView(frame: view.bounds)
        layerView.renderDevice = device
        layerView.metalLayer.framebufferOnly = false
        layerView.renderContentsScale = renderingScale
        layerView.renderDrawableSize = CGSize(width: view.bounds.width * renderingScale,
                                              height: view.bounds.height * renderingScale)
        guard let renderer = try? MetalTerminalRenderer(target: layerView) else { return nil }
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesRenderedTexture = true
        guard view.renderSnapshotForMetal(renderer: renderer, target: layerView),
              let texture = renderer.lastRenderedTexture,
              texture.width > 0,
              texture.height > 0 else { return nil }

        let bytesPerRow = texture.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!,
                             bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                             mipmapLevel: 0)
        }
        return MetalFrame(pixels: pixels,
                          bytesPerRow: bytesPerRow,
                          width: texture.width,
                          height: texture.height,
                          isBGRA: layerView.renderPixelFormat == .bgra8Unorm,
                          scale: CGFloat(texture.width) / view.bounds.width,
                          cellWidth: view.cellDimension.width)
    }

    @Test func metalShapedRunCoversAllSourceCells() throws {
        let view = makeView(feeding: Self.ligatedRow)
        try assertLigaturePrecondition(view)
        let frame = try #require(metalFrame(of: view))

        func red(_ column: Int) -> Int {
            frame.count(inColumns: column..<(column + 1)) { r, g, b in r > 180 && g < 80 && b < 80 }
        }
        func green(_ column: Int) -> Int {
            frame.count(inColumns: column..<(column + 1)) { r, g, b in g > 180 && r < 80 && b < 80 }
        }

        #expect(red(0) > 0)
        #expect(red(1) > 0)
        #expect(red(2) > 0)
        #expect(red(3) == 0)
        let lastCell = frame.pixelColumns(2..<3)
        let lastCellMiddle = (lastCell.lowerBound + lastCell.count / 4)..<(lastCell.upperBound - lastCell.count / 4)
        #expect(frame.count(inPixels: lastCellMiddle) { r, g, b in b > 180 && r < 80 && g < 80 } > 0)
        #expect(green(3) > 0)
        #expect(green(2) == 0)
    }

    @Test func metalFallbackGlyphStaysInItsCell() throws {
        let view = makeView(feeding: Self.fallbackLigatureRow, font: "Menlo-Regular")
        let frame = try #require(metalFrame(of: view))
        let isGreen = { (r: UInt8, g: UInt8, b: UInt8) in g > 180 && r < 80 && b < 80 }
        #expect(frame.count(inColumns: 0..<1, matches: isGreen) > 0)
        #expect(frame.count(inColumns: 1..<2, matches: isGreen) == 0)
    }

    @Test func metalFallbackConjunctKeepsItsCells() throws {
        let view = makeView(feeding: Self.conjunctRow, font: "Menlo-Regular")
        let frame = try #require(metalFrame(of: view))
        #expect(frame.count(inColumns: 1..<2) { r, g, b in g > 180 && r < 80 && b < 80 } > 0)
    }

    @Test func metalWideCellDecorationSpansItsColumns() throws {
        let view = makeView(feeding: Self.wideUnderlinedRow)
        let frame = try #require(metalFrame(of: view))

        let secondColumn = frame.pixelColumns(1..<2)
        try #require(!secondColumn.isEmpty)
        let rightHalf = (secondColumn.lowerBound + secondColumn.count / 2)..<secondColumn.upperBound
        let isBlue = { (r: UInt8, g: UInt8, b: UInt8) in b > 180 && r < 80 && g < 80 }

        #expect(frame.count(inColumns: 0..<1, matches: isBlue) > 0)
        #expect(frame.count(inPixels: rightHalf, matches: isBlue) > 0)
    }
}
#endif
#endif
