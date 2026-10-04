#if os(macOS)
import AppKit
import Testing
#if canImport(MetalKit)
import Metal
import MetalKit
#endif
@testable import SwiftTerm

@MainActor
struct BidiImageRenderingTests {
    let rtl = BidiPresentationState(supportMode: .explicit, autodetectDirection: false,
                                    fallbackDirection: .rightToLeft)

    func makeView(_ text: String = "", state: BidiPresentationState = .default) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 120),
                                font: nil, options: TerminalOptions(cols: 12, rows: 4,
                                                                  initialBidiState: state))
        view.feed(text: text)
        return view
    }

    func image(_ view: TerminalView, col: Int, width: Int = 3) -> TerminalView.AppleImage {
        let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 8,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<8 {
            for x in 0..<20 {
                let offset = y * pixels.bytesPerRow + x * 4
                pixels.bitmapData![offset] = x < 10 ? 255 : 0
                pixels.bitmapData![offset + 1] = 0
                pixels.bitmapData![offset + 2] = x < 10 ? 0 : 255
                pixels.bitmapData![offset + 3] = 255
            }
        }
        let bitmap = NSImage(size: NSSize(width: 20, height: 8))
        bitmap.addRepresentation(pixels)
        return TerminalView.AppleImage(image: bitmap, width: 20, height: 8,
                                      onCol: col, columnWidth: width)
    }

    func attach(_ image: TerminalView.AppleImage, to view: TerminalView) {
        view.withTerminal { terminal in
            terminal.buffer.attachImage(image, toLineAt: terminal.buffer.yBase)
            terminal.updateFullScreen()
        }
    }

    func snapshot(_ view: TerminalView) -> TerminalSnapshot {
        let snapshot = TerminalSnapshot()
        view.withTerminal { terminal in
            _ = snapshot.refresh(terminal: terminal, viewState: FrameViewState(view: view),
                                 selection: SnapshotSelectionState(selection: view.selection))
        }
        return snapshot
    }

    func renderedText(_ view: TerminalView, _ snapshot: TerminalSnapshot) -> String {
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: snapshot)
        return view.textBuilder.buildAttributedString(row: snapshot.rows[0],
            absoluteRow: snapshot.firstRow, context: context)
            .segments.map { $0.attributedString.string }.joined()
    }

    @Test func explicitRTLImageIsAtomicAndSuppressesCoveredText() throws {
        let view = makeView("abcdef", state: rtl)
        attach(image(view, col: 1), to: view)
        let captured = snapshot(view)
        let layout = try #require(captured.rows[0].bidiLayout)
        let object = try #require(layout.visualCells.first { $0.logicalCol == 1 })
        #expect(object.width == 3)
        #expect(layout.logicalToVisualCol[1] == captured.cols - 4)
        #expect(layout.logicalToVisualCol[2] == captured.cols - 3)
        #expect(layout.logicalToVisualCol[3] == captured.cols - 2)
        #expect(!layout.visualCells.contains { $0.logicalCol == 2 || $0.logicalCol == 3 })
        let text = renderedText(view, captured)
        #expect(text.contains("a"))
        #expect(text.contains("e"))
        #expect(!text.contains("b") && !text.contains("c") && !text.contains("d"))
        #expect(!text.contains("\u{FFFC}"))
    }

    @Test func implicitImageUsesOneNeutralObject() throws {
        let view = makeView("אבXYZגד")
        attach(image(view, col: 2), to: view)
        let captured = snapshot(view)
        var cells: [TerminalBidi.Cell] = []
        let used = TerminalBidi.appendCells(line: captured.rows[0].line, row: 0,
                                            cols: captured.cols, to: &cells)
        #expect(used == 7)
        #expect(cells.map(\.text) == ["א", "ב", "\u{FFFC}", "ג", "ד"])
        let layout = try #require(captured.rows[0].bidiLayout)
        #expect(layout.visualCells.filter { $0.width == 3 }.count == 1)
        #expect(layout.logicalToVisualCol[2] == captured.cols - 5)
        #expect(!renderedText(view, captured).contains("XYZ"))
    }

    @Test func ltrImageSuppressesCoveredTextWithoutLayout() {
        let view = makeView("abcdef")
        attach(image(view, col: 1), to: view)
        let captured = snapshot(view)
        #expect(captured.rows[0].bidiLayout == nil)
        let text = renderedText(view, captured)
        #expect(text.contains("a") && text.contains("ef"))
        #expect(!text.contains("b") && !text.contains("c") && !text.contains("d"))
    }

    @Test func imageAfterTrimmedTextParticipatesInRTLLayout() throws {
        let view = makeView("a", state: rtl)
        attach(image(view, col: 6, width: 2), to: view)
        let captured = snapshot(view)
        let layout = try #require(captured.rows[0].bidiLayout)
        #expect(layout.visualCells.contains { $0.logicalCol == 6 && $0.width == 2 })
        #expect(layout.logicalToVisualCol[6] == captured.cols - 8)
    }

    @Test(arguments: [BidiSupportMode.explicit, .implicit])
    func movedImageRebuildsLayoutAndPreservesCapturedGeometry(mode: BidiSupportMode) throws {
        let view = makeView("abcdef", state: BidiPresentationState(
            supportMode: mode, autodetectDirection: false, fallbackDirection: .rightToLeft))
        let source = image(view, col: 1)
        attach(source, to: view)
        let first = snapshot(view)
        let oldRevision = first.rows[0].bidiParagraphRevision
        let generation = view.withTerminal { $0.buffer.lines[$0.buffer.yBase].generation }
        view.withTerminal { _ in source.col = 4 }
        let second = snapshot(view)
        #expect(view.withTerminal { $0.buffer.lines[$0.buffer.yBase].generation } == generation)
        #expect(second.rows[0].bidiParagraphRevision != oldRevision)
        #expect(first.rows[0].images[0].col == 1)
        #expect(first.rows[0].line.images?[0].col == 1)
        #expect(second.rows[0].images[0].col == 4)
        let layout = try #require(second.rows[0].bidiLayout)
        #expect(layout.visualCells.contains { $0.logicalCol == 4 && $0.width == 3 })

        // Refresh the same snapshot after a geometry-only edit. Its cell copy
        // is unchanged, but its image object and cached map must both move.
        let secondRevision = second.rows[0].bidiParagraphRevision
        view.withTerminal { terminal in
            source.col = 2
            _ = second.refresh(terminal: terminal, viewState: FrameViewState(view: view),
                               selection: SnapshotSelectionState(selection: view.selection))
        }
        #expect(second.rows[0].bidiParagraphRevision != secondRevision)
        #expect(second.rows[0].images[0].col == 2)
        #expect(second.rows[0].line.images?[0].col == 2)
        #expect(second.rows[0].bidiLayout?.visualCells.contains {
            $0.logicalCol == 2 && $0.width == 3
        } == true)
        #expect(first.rows[0].images[0].col == 1)
    }

    @Test(arguments: [false, true])
    func coreGraphicsMovesImageWithoutFlippingPixels(rightClipped: Bool) throws {
        let view = makeView(state: rtl)
        try view.setUseMetal(false)
        let sourceColumn = rightClipped ? snapshot(view).cols - 1 : 1
        attach(image(view, col: sourceColumn), to: view)
        let captured = snapshot(view)
        let layout = try #require(captured.rows[0].bidiLayout)
        let visualColumn = layout.logicalToVisualCol[sourceColumn]
        let expectedX = CGFloat(visualColumn) * view.cellDimension.width
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 120,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        _ = view.renderOwner.prepareFrame(viewState: FrameViewState(view: view))
        view.drawTerminalContents(dirtyRect: view.bounds, context: graphics.cgContext,
                                  bufferOffset: 0)
        NSGraphicsContext.restoreGraphicsState()
        var redX: [Int] = []
        var blueX: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.8 && color.blueComponent < 0.2 && color.greenComponent < 0.2 {
                    redX.append(x)
                }
                if color.blueComponent > 0.8 && color.redComponent < 0.2 && color.greenComponent < 0.2 {
                    blueX.append(x)
                }
            }
        }
        let redLeft = try #require(redX.min())
        let redRight = try #require(redX.max())
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        if rightClipped {
            #expect(blueX.isEmpty)
            #expect(CGFloat(redRight) / scale < expectedX + view.cellDimension.width)
        } else {
            let blueLeft = try #require(blueX.min())
            #expect(redRight < blueLeft)
        }
        #expect(abs(CGFloat(redLeft) / scale - expectedX) < 2)
        #expect(visualColumn != sourceColumn)
    }

    @Test func fontChangeUpdatesTheImageSpanSoTheImageIsNotCropped() throws {
        let view = makeView()
        let initialColumns = try #require(imageColumnCount(
            width: 20, cellWidth: Double(view.cellDimension.width)))
        let source = image(view, col: 0, width: initialColumns)
        attach(source, to: view)

        view.font = NSFont.monospacedSystemFont(ofSize: 6, weight: .regular)
        let cellWidth = view.cellDimension.width
        let columns = try #require(imageColumnCount(width: 20, cellWidth: Double(cellWidth)))
        #expect(columns > initialColumns)
        #expect(source.columnWidth == columns)
        let geometry = try #require(TerminalBidi.imageGeometry(
            source, layout: nil, cols: 80, cellWidth: cellWidth, rowBase: 40))
        #expect(geometry.visibleRect.width == 20)
        #expect(geometry.uvRect.width == 1)
    }

    @Test func rasterImageCoversItsColumnsInTheLayoutAndTheText() throws {
        let view = makeView("abcdef", state: rtl)
        let raster = try #require(TerminalRasterImage(
            id: 1, width: 2, height: 2, rgba: [UInt8](repeating: 255, count: 16)))
        view.withTerminal { terminal in
            terminal.buffer.x = 1
            terminal.insertRasterImage(raster, cellWidth: 10, cellHeight: 20,
                                       width: .pixels(25), height: .pixels(20),
                                       preserveAspectRatio: false)
        }
        let captured = snapshot(view)
        #expect(captured.rows[0].images.first?.columnWidth == 3)
        #expect(captured.rows[0].images.first?.image == nil)
        let layout = try #require(captured.rows[0].bidiLayout)
        #expect(layout.visualCells.contains { $0.logicalCol == 1 && $0.width == 3 })
        let text = renderedText(view, captured)
        #expect(text.contains("a") && text.contains("e"))
        #expect(!text.contains("b") && !text.contains("c") && !text.contains("d"))
    }

    @Test func insertedFractionalWidthRoundsUpToWholeColumns() throws {
        let view = makeView()
        let source = image(view, col: 0).image
        let requestedWidth = Int(view.cellDimension.width * 2) + 1
        view.withTerminal { terminal in
            view.insertImage(source, terminal: terminal, width: .pixels(requestedWidth),
                             height: .cells(1), preserveAspectRatio: false)
        }
        let stripe = try #require(snapshot(view).rows[0].images.first)
        #expect(stripe.columnWidth == Int(ceil(CGFloat(requestedWidth) / view.cellDimension.width)))
    }

#if canImport(MetalKit)
    @Test(arguments: [false, true])
    func metalMovesImageWithoutFlippingPixels(rightClipped: Bool) throws {
        // A machine without a Metal device cannot run the pixel check.
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let target = MTKView(frame: CGRect(x: 0, y: 0, width: 320, height: 120), device: device)
        target.colorPixelFormat = .bgra8Unorm
        target.framebufferOnly = false
        target.isPaused = true
        target.enableSetNeedsDisplay = true
        target.renderContentsScale = 1
        target.renderDrawableSize = CGSize(width: 320, height: 120)
        // An offscreen surface can lack a drawable, even with a Metal device.
        guard target.currentDrawable != nil else { return }
        let renderer = try MetalTerminalRenderer(target: target)
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesRenderedTexture = true
        let view = makeView(state: rtl)
        view.metalScaleFactorOverride = 1
        let sourceColumn = rightClipped ? snapshot(view).cols - 1 : 1
        attach(image(view, col: sourceColumn), to: view)
        let captured = snapshot(view)
        let layout = try #require(captured.rows[0].bidiLayout)
        let visualColumn = layout.logicalToVisualCol[sourceColumn]
        let expectedX = CGFloat(visualColumn) * view.cellDimension.width
        #expect(view.renderSnapshotForMetal(renderer: renderer, target: target))
        let texture = try #require(renderer.lastRenderedTexture)
        #expect(texture.pixelFormat == .bgra8Unorm)
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                             mipmapLevel: 0)
        }
        var redX: [Int] = []
        var blueX: [Int] = []
        for y in 0..<texture.height {
            for x in 0..<texture.width {
                let offset = y * bytesPerRow + x * 4
                let blue = bytes[offset]
                let green = bytes[offset + 1]
                let red = bytes[offset + 2]
                if red > 200 && blue < 50 && green < 50 { redX.append(x) }
                if blue > 200 && red < 50 && green < 50 { blueX.append(x) }
            }
        }
        let redLeft = try #require(redX.min())
        let redRight = try #require(redX.max())
        if rightClipped {
            #expect(blueX.isEmpty)
            #expect(CGFloat(redRight) < expectedX + view.cellDimension.width)
        } else {
            let blueLeft = try #require(blueX.min())
            #expect(redRight < blueLeft)
        }
        #expect(abs(CGFloat(redLeft) - expectedX) < 2)
        #expect(visualColumn != sourceColumn)
    }
#endif

    @Test func leftClippedImagePreservesSourceCropInRTLGeometry() throws {
        let view = makeView(state: rtl)
        let source = image(view, col: -1)
        attach(source, to: view)
        let captured = snapshot(view)
        let layout = try #require(captured.rows[0].bidiLayout)
        let geometry = try #require(TerminalBidi.imageGeometry(
            source, layout: layout, cols: captured.cols, cellWidth: 8, rowBase: 16))
        let expectedX = CGFloat(captured.cols - 2) * 8
        #expect(geometry.visibleRect == CGRect(x: expectedX, y: 8, width: 12, height: 8))
        #expect(geometry.fullRect == CGRect(x: expectedX - 8, y: 8, width: 20, height: 8))
        #expect(abs(geometry.uvRect.minX - 0.4) < 0.0001)
        #expect(abs(geometry.uvRect.width - 0.6) < 0.0001)
    }
}
#endif
