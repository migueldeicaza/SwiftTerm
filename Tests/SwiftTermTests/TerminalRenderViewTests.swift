#if os(macOS)
import AppKit
import Foundation
import Testing
#if canImport(MetalKit)
import Metal
#endif

@testable import SwiftTerm

/// An external source with fixed lines, for the render view tests.
@MainActor
final class FixedFrameSource: TerminalExternalFrameSource {
    let store = TerminalRowStore()
    var lines: [Int: BufferLine] = [:]
    var frame: TerminalExternalFrame

    init(columns: Int, rows: Int, topLine: Int) {
        frame = TerminalExternalFrame(columns: columns, rows: rows, topLine: topLine,
                                      cursorLine: topLine, cursorColumn: 0, cursorVisible: false,
                                      cursorStyle: .steadyBlock, isAlternateBuffer: false,
                                      palette: TerminalExternalFrame.makePalette())
    }

    func setLine(_ number: Int, _ text: String, attribute: Attribute = .empty) {
        let line = store.makeLine(columns: frame.columns)
        var column = 0
        for character in text {
            let width = character.unicodeScalars.first.map { $0.value >= 0x1100 && $0.value <= 0x115F || $0.value >= 0x4E00 && $0.value <= 0x9FFF } == true ? 2 : 1
            store.setCell(line, column: column, text: String(character), width: width, attribute: attribute)
            if width == 2 {
                store.setCell(line, column: column + 1, text: nil, width: 0, attribute: attribute)
            }
            column += width
        }
        lines[number] = line
    }

    func withFrame(_ body: (TerminalExternalFrame, TerminalRowStore, (Int) -> BufferLine?) -> Void) {
        body(frame, store) { self.lines[$0] }
    }
}

/// A source that builds its lines while the view looks them up, as a source
/// that converts rows lazily does. Every frame interns new styles.
@MainActor
final class LazyFrameSource: TerminalExternalFrameSource {
    let store = TerminalRowStore()
    var frame = TerminalExternalFrame(columns: 8, rows: 3, topLine: 0, cursorLine: 1, cursorColumn: 2,
                                      cursorVisible: true, cursorStyle: .steadyBlock,
                                      isAlternateBuffer: false, palette: TerminalExternalFrame.makePalette())
    var generation: UInt8 = 0
    var lines: [Int: BufferLine] = [:]

    func withFrame(_ body: (TerminalExternalFrame, TerminalRowStore, (Int) -> BufferLine?) -> Void) {
        generation &+= 1
        body(frame, store) { number in
            let line = self.lines[number] ?? self.store.makeLine(columns: 8)
            let attribute = Attribute(foreground: .trueColor(red: self.generation, green: UInt8(number), blue: 7),
                                      background: .defaultColor, style: [])
            self.store.setCell(line, column: 0, text: "x", width: 1, attribute: attribute)
            self.lines[number] = line
            return line
        }
    }
}

@MainActor
@Suite(.serialized)
struct TerminalRenderViewTests {
    /// Regression: lines built during the lookup intern styles after the
    /// snapshot started; the snapshot must still decode them.
    @Test func linesBuiltDuringLookupDecode() throws {
        let source = LazyFrameSource()
        let view = TerminalRenderView(frame: .zero, font: font)
        view.setFrameSize(NSSize(width: view.cellSize.width * 8, height: view.cellSize.height * 3))
        view.frameSource = source
        for _ in 0 ..< 5 {
            view.frameTick()
            _ = try bitmap(view)
        }
    }

    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func count(_ bitmap: NSBitmapImageRep, _ predicate: (NSColor) -> Bool) -> Int {
        var result = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), predicate(color) {
                    result += 1
                }
            }
        }
        return result
    }

    @Test func rowStoreCellsReadBackThroughThePublicAPI() {
        let store = TerminalRowStore()
        let line = store.makeLine(columns: 6)
        let red = Attribute(foreground: .ansi256(code: 1), background: .trueColor(red: 1, green: 2, blue: 3),
                            style: [.bold], underlineStyle: .curly, underlineColor: .ansi256(code: 4))
        #expect(store.setCell(line, column: 0, text: "A", width: 1, attribute: red))
        #expect(store.setCell(line, column: 1, text: "漢", width: 2, attribute: .empty))
        #expect(store.setCell(line, column: 2, text: nil, width: 0, attribute: .empty))
        #expect(store.setCell(line, column: 3, text: "👩‍👩‍👧", width: 2, attribute: .empty))
        store.setLineState(line, isWrapped: true)

        #expect(line[0].getCharacter() == "A")
        #expect(line[0].attribute == red)
        #expect(line[1].getText() == "漢")
        #expect(line[1].width == 2)
        #expect(line[2].width == 0)
        #expect(line[3].getText() == "👩‍👩‍👧")
        #expect(line.isWrapped)
        #expect(line[5].getText() == "\u{0}")
        // Lines of another store are refused.
        #expect(!TerminalRowStore().setCell(line, column: 0, text: "x", width: 1, attribute: .empty))
        #expect(!store.isNearCapacity)

        // Each new attribute takes one style, once.
        let empty = TerminalRowStore()
        let row = empty.makeLine(columns: 4)
        empty.setCell(row, column: 0, text: "a", width: 1, attribute: .empty)
        let styles = empty.remainingStyleCapacity
        let graphemes = empty.remainingGraphemeCapacity
        empty.setCell(row, column: 1, text: "b", width: 1, attribute: .empty)
        #expect(empty.remainingStyleCapacity == styles)
        for blue in 0 ..< 3 {
            empty.setCell(row, column: blue, text: "e\u{301}", width: 1,
                          attribute: Attribute(foreground: .trueColor(red: 1, green: 2, blue: UInt8(blue)),
                                               background: .defaultColor, style: []))
        }
        #expect(empty.remainingStyleCapacity == styles - 3)
        #expect(empty.remainingGraphemeCapacity < graphemes)
    }

    @Test func renderViewDrawsExternalRows() throws {
        let source = FixedFrameSource(columns: 10, rows: 3, topLine: 500)
        source.setLine(500, "RED", attribute: Attribute(foreground: .defaultColor, background: .ansi256(code: 1), style: []))
        let view = TerminalRenderView(frame: .zero, font: font)
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        view.setFrameSize(NSSize(width: view.cellSize.width * 10, height: view.cellSize.height * 3))
        view.frameSource = source
        view.frameTick()
        let image = try bitmap(view)
        let reddish = count(image) { $0.redComponent > 0.6 && $0.greenComponent < 0.3 && $0.blueComponent < 0.3 }
        #expect(reddish > 0)
        #expect(view.gridSize.columns == 10)
        #expect(view.gridSize.rows == 3)
    }

    @Test func missingRowsDrawAsBackground() throws {
        let source = FixedFrameSource(columns: 10, rows: 3, topLine: 0)
        let view = TerminalRenderView(frame: .zero, font: font)
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        view.setFrameSize(NSSize(width: view.cellSize.width * 10, height: view.cellSize.height * 3))
        view.frameSource = source
        view.frameTick()
        let image = try bitmap(view)
        let lit = count(image) { $0.redComponent + $0.greenComponent + $0.blueComponent > 0.2 }
        #expect(lit == 0)
    }

    /// The render view and a local terminal view paint the same pixels for
    /// the same content.
    @Test func renderViewMatchesTerminalViewPixels() throws {
        let columns = 20
        let rows = 3
        let local = TerminalView(frame: .zero)
        local.font = font
        local.nativeBackgroundColor = .black
        local.nativeForegroundColor = .orange
        local.setFrameSize(NSSize(width: local.cellDimension.width * CGFloat(columns),
                                  height: local.cellDimension.height * CGFloat(rows)))
        local.feed(text: "\u{1b}[?25l\u{1b}[1;32mhello\u{1b}[0m \u{1b}[44mworld\u{1b}[0m\r\nplain text ─│┼")
        local.frameTick()
        let localImage = try bitmap(local)

        let source = FixedFrameSource(columns: columns, rows: rows, topLine: 0)
        let terminal: Terminal = local.terminal
        for row in 0..<rows {
            guard let line = terminal.getLine(row: row) else { continue }
            let copy = source.store.makeLine(columns: columns)
            for column in 0..<min(columns, line.count) {
                let cell = line[column]
                let text = cell.getText()
                source.store.setCell(copy, column: column, text: text == "\u{0}" ? nil : text,
                                     width: Int(cell.width), attribute: cell.attribute)
            }
            source.lines[row] = copy
        }
        source.frame.palette = terminal.ansiColors
        let remote = TerminalRenderView(frame: .zero, font: font)
        remote.nativeBackgroundColor = .black
        remote.nativeForegroundColor = .orange
        remote.setFrameSize(local.frame.size)
        remote.frameSource = source
        remote.frameTick()
        let remoteImage = try bitmap(remote)

        #expect(localImage.pixelsWide == remoteImage.pixelsWide)
        #expect(localImage.pixelsHigh == remoteImage.pixelsHigh)
        var different = 0
        for y in 0..<min(localImage.pixelsHigh, remoteImage.pixelsHigh) {
            for x in 0..<min(localImage.pixelsWide, remoteImage.pixelsWide) {
                let a = localImage.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                let b = remoteImage.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                guard let a, let b else { continue }
                if abs(a.redComponent - b.redComponent) > 0.02 ||
                    abs(a.greenComponent - b.greenComponent) > 0.02 ||
                    abs(a.blueComponent - b.blueComponent) > 0.02 {
                    different += 1
                }
            }
        }
        if different > 0, let directory = ProcessInfo.processInfo.environment["RENDER_DIFF_DIR"] {
            try localImage.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory + "/local.png"))
            try remoteImage.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory + "/remote.png"))
        }
        #expect(different == 0, "\(different) pixels differ")
    }

    /// Copies the visible rows of a local terminal into a fixed source.
    private func mirror(_ local: TerminalView, columns: Int, rows: Int) -> FixedFrameSource {
        let source = FixedFrameSource(columns: columns, rows: rows, topLine: 0)
        let terminal: Terminal = local.terminal
        for row in 0..<rows {
            guard let line = terminal.getLine(row: row) else { continue }
            let copy = source.store.makeLine(columns: columns)
            for column in 0..<min(columns, line.count) {
                let cell = line[column]
                let text = cell.getText()
                source.store.setCell(copy, column: column, text: text == "\u{0}" ? nil : text,
                                     width: Int(cell.width), attribute: cell.attribute)
            }
            source.lines[row] = copy
        }
        source.frame.palette = terminal.ansiColors
        return source
    }

#if canImport(MetalKit)
    /// Renders through a fresh Metal renderer and returns the pixels, or nil
    /// when the machine has no usable Metal device or drawable.
    private func metalPixels(width: Int, height: Int,
                             render: (MetalTerminalRenderer, any MetalRenderTarget) -> Bool) -> [UInt8]? {
        guard MetalTerminalRenderer.shaderLibraryIsAvailable,
              let device = MTLCreateSystemDefaultDevice() else { return nil }
        let target = TerminalMetalLayerView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        target.renderDevice = device
        target.metalLayer.framebufferOnly = false
        target.renderContentsScale = 1
        target.renderDrawableSize = CGSize(width: width, height: height)
        guard let renderer = try? MetalTerminalRenderer(target: target) else { return nil }
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesRenderedTexture = true
        guard render(renderer, target), let texture = renderer.lastRenderedTexture else { return nil }
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return bytes
    }

    /// With the Metal renderer, the render view and a local terminal view
    /// produce the same pixels: same renderer, same shaders, same rows.
    @Test(.enabled(if: MetalTerminalRenderer.shaderLibraryIsAvailable))
    func metalRenderMatchesTerminalView() throws {
        let columns = 20
        let rows = 3
        let local = TerminalView(frame: .zero)
        local.font = font
        local.nativeBackgroundColor = .black
        local.nativeForegroundColor = .orange
        local.setFrameSize(NSSize(width: local.cellDimension.width * CGFloat(columns),
                                  height: local.cellDimension.height * CGFloat(rows)))
        local.feed(text: "\u{1b}[?25l\u{1b}[1;32mhello\u{1b}[0m \u{1b}[44mworld\u{1b}[0m\r\nplain text ─│┼")
        let remote = TerminalRenderView(frame: .zero, font: font)
        remote.nativeBackgroundColor = .black
        remote.nativeForegroundColor = .orange
        remote.setFrameSize(local.frame.size)
        let source = mirror(local, columns: columns, rows: rows)
        remote.frameSource = source

        let width = Int(local.frame.width)
        let height = Int(local.frame.height)
        let localPixels = try #require(metalPixels(width: width, height: height) {
            local.renderSnapshotForMetal(renderer: $0, target: $1)
        })
        let remotePixels = try #require(metalPixels(width: width, height: height) {
            remote.renderSnapshotForMetal(renderer: $0, target: $1)
        })
        #expect(localPixels.count == remotePixels.count)
        var different = 0
        for index in stride(from: 0, to: min(localPixels.count, remotePixels.count), by: 4) where
            localPixels[index] != remotePixels[index] || localPixels[index + 1] != remotePixels[index + 1] ||
            localPixels[index + 2] != remotePixels[index + 2] {
            different += 1
        }
        #expect(different == 0, "\(different) pixels differ")
        // Not everything is background: the text was drawn.
        let lit = stride(from: 0, to: remotePixels.count, by: 4).filter {
            Int(remotePixels[$0]) + Int(remotePixels[$0 + 1]) + Int(remotePixels[$0 + 2]) > 120
        }.count
        #expect(lit > 0)
    }

    @Test(.enabled(if: MetalTerminalRenderer.shaderLibraryIsAvailable))
    func metalCanBeTurnedOnAndOff() throws {
        let source = FixedFrameSource(columns: 10, rows: 3, topLine: 0)
        source.setLine(0, "metal")
        let view = TerminalRenderView(frame: .zero, font: font)
        view.setFrameSize(NSSize(width: view.cellSize.width * 10, height: view.cellSize.height * 3))
        view.frameSource = source
        let overlay = NSView(frame: .zero)
        view.addSubview(overlay)
        for _ in 0 ..< 3 {
            try view.setUseMetal(true)
            #expect(view.isUsingMetalRenderer)
            // The surface goes below the host's overlays.
            #expect(view.subviews.last === overlay)
            view.frameTick()
            try view.setUseMetal(false)
            #expect(!view.isUsingMetalRenderer)
            view.frameTick()
        }
        // Core Graphics draws again, as a view that never used Metal.
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        view.frameTick()
        let image = try bitmap(view)
        let fresh = TerminalRenderView(frame: .zero, font: font)
        fresh.nativeBackgroundColor = .black
        fresh.nativeForegroundColor = .white
        fresh.setFrameSize(view.frame.size)
        fresh.frameSource = source
        fresh.frameTick()
        let expected = try bitmap(fresh)
        let different = differingPixels(image, expected)
        if different > 0, let directory = ProcessInfo.processInfo.environment["RENDER_DIFF_DIR"] {
            try image.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory + "/toggled.png"))
            try expected.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory + "/fresh.png"))
        }
        #expect(different == 0, "\(different) pixels differ after Metal was turned off")
    }
#endif

    /// Copies every line of a local terminal (scrollback too) into a fixed
    /// source, with the wrap and bidi state, numbered like `buffer.lines`.
    private func mirrorAll(_ local: TerminalView, columns: Int, rows: Int) -> FixedFrameSource {
        let terminal: Terminal = local.terminal
        let top = terminal.buffer.yDisp
        let source = FixedFrameSource(columns: columns, rows: rows, topLine: top)
        for index in 0..<terminal.buffer.lines.count {
            guard let line = terminal.bufferLine(atRow: index) else { continue }
            let copy = source.store.makeLine(columns: columns)
            for column in 0..<min(columns, line.count) {
                let cell = line[column]
                let text = cell.getText()
                source.store.setCell(copy, column: column, text: text == "\u{0}" ? nil : text,
                                     width: Int(cell.width), attribute: cell.attribute)
            }
            source.store.setLineState(copy, isWrapped: line.isWrapped, bidiState: line.bidiState)
            source.lines[index] = copy
        }
        source.frame.palette = terminal.ansiColors
        source.frame.cursorVisible = false
        return source
    }

    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        var different = 0
        for y in 0..<min(a.pixelsHigh, b.pixelsHigh) {
            for x in 0..<min(a.pixelsWide, b.pixelsWide) {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let q = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(p.redComponent - q.redComponent) > 0.02 ||
                    abs(p.greenComponent - q.greenComponent) > 0.02 ||
                    abs(p.blueComponent - q.blueComponent) > 0.02 {
                    different += 1
                }
            }
        }
        return different
    }

    /// Bidi on external rows: an Arabic paragraph that wraps across the top
    /// of the view, and a mixed Hebrew and Latin row, draw as in a local
    /// terminal, and the column maps are the local ones.
    @Test func bidiRowsMatchTerminalView() throws {
        let columns = 20
        let rows = 3
        let local = TerminalView(frame: .zero)
        local.font = font
        local.nativeBackgroundColor = .black
        local.nativeForegroundColor = .white
        local.setFrameSize(NSSize(width: local.cellDimension.width * CGFloat(columns),
                                  height: local.cellDimension.height * CGFloat(rows)))
        let arabic = String(repeating: "مرحبا بالعالم ", count: 4)
        local.feed(text: "\u{1b}[?25l" + arabic + "\r\nשלום abc 123")
        local.frameTick()
        let localImage = try bitmap(local)
        let terminal: Terminal = local.terminal
        let top = terminal.buffer.yDisp
        // The paragraph starts above the view.
        #expect(top > 0)
        #expect(terminal.bufferLine(atRow: top)?.isWrapped == true)

        let source = mirrorAll(local, columns: columns, rows: rows)
        let remote = TerminalRenderView(frame: .zero, font: font)
        remote.nativeBackgroundColor = .black
        remote.nativeForegroundColor = .white
        remote.setFrameSize(local.frame.size)
        remote.frameSource = source
        remote.frameTick()
        let remoteImage = try bitmap(remote)

        var reordered = false
        for row in 0..<rows {
            let expected = TerminalBidi.layout(row: top + row, buffer: terminal.buffer, cols: columns,
                                               terminal: terminal, font: remote.font,
                                               hostPolicy: .respectTerminal)
            for column in 0..<columns {
                let mapped = remote.logicalColumn(forVisualColumn: column, row: row)
                #expect(mapped == (expected?.visualToLogicalCol[column] ?? column),
                        "row \(row) column \(column)")
                if mapped != column { reordered = true }
            }
            #expect(remote.baseDirection(row: row) == (expected?.baseDirection ?? .leftToRight))
        }
        #expect(reordered)
        #expect(remote.baseDirection(row: 0) == .rightToLeft)
        let different = differingPixels(localImage, remoteImage)
        if different > 0, let directory = ProcessInfo.processInfo.environment["RENDER_DIFF_DIR"] {
            try localImage.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory + "/bidi-local.png"))
            try remoteImage.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory + "/bidi-remote.png"))
        }
        #expect(different == 0, "\(different) pixels differ")

        // The legacy policy draws every row in logical order.
        remote.bidiHostPolicy = .legacyLeftToRight
        remote.frameTick()
        #expect(remote.logicalColumn(forVisualColumn: 0, row: 0) == 0)
        #expect(remote.baseDirection(row: 0) == .leftToRight)
    }

    /// Sixel slices and Kitty placements on external rows draw as in a local
    /// terminal.
    @Test func imagesMatchTerminalView() throws {
        let columns = 20
        let rows = 6
        let local = TerminalView(frame: .zero)
        local.font = font
        local.nativeBackgroundColor = .black
        local.nativeForegroundColor = .white
        local.setFrameSize(NSSize(width: local.cellDimension.width * CGFloat(columns),
                                  height: local.cellDimension.height * CGFloat(rows)))
        // A red 20 × 18 Sixel image, then a green 2 × 2 Kitty image (RGB).
        let sixel = "\u{1b}Pq#0;2;100;0;0#0!20~-!20~-!20~\u{1b}\\"
        let green = Data([0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0]).base64EncodedString()
        let kitty = "\u{1b}_Gf=24,s=2,v=2,a=T,c=3,r=1;\(green)\u{1b}\\"
        local.feed(text: "\u{1b}[?25lA" + sixel + "\r\nB" + kitty)
        local.frameTick()
        let localImage = try bitmap(local)

        let terminal: Terminal = local.terminal
        let source = mirrorAll(local, columns: columns, rows: rows)
        var slices = 0
        for index in 0..<terminal.buffer.lines.count {
            let images = (terminal.buffer.lines[index].images ?? []).compactMap { $0 as? TerminalView.AppleImage }
            guard !images.isEmpty else { continue }
            slices += images.count
            source.frame.images[index] = images.map {
                TerminalExternalImage(image: $0.image, column: $0.col, width: $0.pixelWidth, height: $0.pixelHeight)
            }
        }
        let kittySnapshot = terminal.terminalLock.withLock { terminal.kittyGraphicsRenderSnapshot() }
        #expect(slices > 0)
        #expect(!kittySnapshot.placements.isEmpty)
        source.frame.kitty = kittySnapshot

        let remote = TerminalRenderView(frame: .zero, font: font)
        remote.nativeBackgroundColor = .black
        remote.nativeForegroundColor = .white
        remote.setFrameSize(local.frame.size)
        remote.frameSource = source
        remote.frameTick()
        let remoteImage = try bitmap(remote)

        let red = count(remoteImage) { $0.redComponent > 0.8 && $0.greenComponent < 0.2 && $0.blueComponent < 0.2 }
        let greenPixels = count(remoteImage) { $0.greenComponent > 0.8 && $0.redComponent < 0.2 && $0.blueComponent < 0.2 }
        #expect(red > 0)
        #expect(greenPixels > 0)
        let different = differingPixels(localImage, remoteImage)
        if different > 0, let directory = ProcessInfo.processInfo.environment["RENDER_DIFF_DIR"] {
            try localImage.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory + "/images-local.png"))
            try remoteImage.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory + "/images-remote.png"))
        }
        #expect(different == 0, "\(different) pixels differ")

#if canImport(MetalKit)
        // The Metal renderer draws the same images from the same snapshot.
        if MetalTerminalRenderer.shaderLibraryIsAvailable {
            let width = Int(local.frame.width)
            let height = Int(local.frame.height)
            let localPixels = try #require(metalPixels(width: width, height: height) {
                local.renderSnapshotForMetal(renderer: $0, target: $1)
            })
            let remotePixels = try #require(metalPixels(width: width, height: height) {
                remote.renderSnapshotForMetal(renderer: $0, target: $1)
            })
            var metalDifferent = 0
            for index in stride(from: 0, to: min(localPixels.count, remotePixels.count), by: 4) where
                localPixels[index] != remotePixels[index] || localPixels[index + 1] != remotePixels[index + 1] ||
                localPixels[index + 2] != remotePixels[index + 2] {
                metalDifferent += 1
            }
            #expect(metalDifferent == 0, "\(metalDifferent) Metal pixels differ")
        }
#endif

        // Removing the Kitty placement repaints the frame.
        source.frame.kitty = nil
        let owner = try #require(Mirror(reflecting: remote).descendant("owner") as? ExternalRenderOwner)
        let viewState = try #require(remote.captureFrameViewState())
        let prepared = try #require(owner.prepare(source: source, viewState: viewState))
        #expect(prepared.damage == .all)
    }

    @Test func onlyChangedRowsAreRepainted() throws {
        let source = FixedFrameSource(columns: 10, rows: 3, topLine: 0)
        source.setLine(0, "one")
        source.setLine(1, "two")
        let view = TerminalRenderView(frame: .zero, font: font)
        view.setFrameSize(NSSize(width: view.cellSize.width * 10, height: view.cellSize.height * 3))
        view.frameSource = source
        view.frameTick()
        // Change one line in place.
        source.store.setCell(source.lines[1]!, column: 0, text: "T", width: 1, attribute: .empty)
        let owner = try #require(Mirror(reflecting: view).descendant("owner") as? ExternalRenderOwner)
        let viewState = try #require(view.captureFrameViewState())
        let prepared = try #require(owner.prepare(source: source, viewState: viewState))
        #expect(prepared.damage == .rows(IndexSet(integer: 1)))
    }

    /// A new row store gives its first style the same ID as the old store
    /// gave a different style. The view must draw the new style.
    @Test func aNewRowStoreDrawsItsOwnStyles() throws {
        let red = Attribute(foreground: .defaultColor, background: .trueColor(red: 220, green: 0, blue: 0), style: [])
        let green = Attribute(foreground: .defaultColor, background: .trueColor(red: 0, green: 200, blue: 0), style: [])
        let first = FixedFrameSource(columns: 10, rows: 1, topLine: 0)
        first.setLine(0, "MMMM", attribute: red)
        let view = TerminalRenderView(frame: .zero, font: font)
        view.nativeBackgroundColor = .black
        view.setFrameSize(NSSize(width: view.cellSize.width * 10, height: view.cellSize.height))
        view.frameSource = first
        view.frameTick()
        _ = try bitmap(view)

        let second = FixedFrameSource(columns: 10, rows: 1, topLine: 0)
        second.setLine(0, "MMMM", attribute: green)
        view.frameSource = second
        view.frameTick()
        let image = try bitmap(view)
        let reddish = count(image) { $0.redComponent > 0.6 && $0.greenComponent < 0.3 }
        let greenish = count(image) { $0.greenComponent > 0.6 && $0.redComponent < 0.3 }
        #expect(reddish == 0)
        #expect(greenish > 0)
    }

    @Test func progressBarShowsAndGoesAway() throws {
        let view = TerminalRenderView(frame: .zero, font: font)
        view.setFrameSize(NSSize(width: view.cellSize.width * 10, height: view.cellSize.height * 3))
        #expect(view.progressReport == nil)

        view.showProgress(Terminal.ProgressReport(state: .set, progress: 40))
        #expect(view.progressReport == Terminal.ProgressReport(state: .set, progress: 40))
        let bar = try #require(view.subviews.last as? TerminalProgressBarView)
        #expect(!bar.isHidden)
        #expect(bar.frame.maxY == view.bounds.maxY)
        #expect(bar.frame.width == view.bounds.width)

        // The bar follows the view's width.
        view.setFrameSize(NSSize(width: view.cellSize.width * 20, height: view.cellSize.height * 3))
        #expect(bar.frame.width == view.bounds.width)

        view.showProgress(Terminal.ProgressReport(state: .remove, progress: nil))
        #expect(view.progressReport == nil)
        #expect(bar.isHidden)

        // A report with no time left shows nothing; a short one goes away
        // when its time ends.
        view.showProgress(Terminal.ProgressReport(state: .set, progress: 10), duration: 0)
        #expect(view.progressReport == nil)
        view.showProgress(Terminal.ProgressReport(state: .set, progress: 10), duration: 0.05)
        #expect(view.progressReport != nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        #expect(view.progressReport == nil)
    }
}
#endif
