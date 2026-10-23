#if os(macOS) && canImport(MetalKit)
import AppKit
import Metal
import Testing
@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct PowerlineMetalGeometryTests {
    nonisolated static var metalIsUsable: Bool {
        MetalTerminalRenderer.shaderLibraryIsAvailable
    }

    @Test(.enabled(if: metalIsUsable))
    func fractionalRowOriginMatchesBackground() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let frame = CGRect(x: 0, y: 0, width: 320, height: 120.25)
        let view = TerminalView(frame: frame)
        view.frameDriver.invalidate()
        view.metalScaleFactorOverride = 2
        view.feed(text: "\u{1b}[41;32m \u{e0b0}\u{1b}[0m")
        let target = TerminalMetalLayerView(frame: frame)
        target.renderDevice = device
        target.renderContentsScale = 2
        target.renderDrawableSize = CGSize(width: frame.width * 2, height: frame.height * 2)
        let renderer = try MetalTerminalRenderer(target: target)
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesDrawData = true
        #expect(view.renderSnapshotForMetal(renderer: renderer, target: target))
        let drawData = try #require(renderer.lastDrawData)
        let row = try #require(drawData.rows.first { $0.glyphGrayCount > 0 })
        let glyphBuffer = try #require(row.glyphGrayBuffer)
        let backgroundBuffer = try #require(row.backgroundBuffer)
        let separator = glyphBuffer.contents().assumingMemoryBound(to: TextCell.self).pointee
        let backgrounds = UnsafeBufferPointer(
            start: backgroundBuffer.contents().assumingMemoryBound(to: ColorCell.self),
            count: row.backgroundCount)
        let background = try #require(backgrounds.first {
            $0.position.x <= separator.position.x && $0.position.x + $0.size.x > separator.position.x
        })
        // A fractional view height makes the row start land on half a device
        // pixel. Rounding only the separator creates a step at the joint.
        #expect(background.position.y.rounded() != background.position.y)
        #expect(separator.position.y == background.position.y)
        #expect(separator.position.y + separator.size.y == background.position.y + background.size.y)
    }
    @Test(.enabled(if: metalIsUsable), arguments: ["5", "6", "3", "4"])
    func thinSeparatorCursorUsesRowMask(decLineMode: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let frame = CGRect(x: 0, y: 0, width: 320, height: 120.25)
        let view = TerminalView(frame: frame)
        view.frameDriver.invalidate()
        view.metalScaleFactorOverride = 2
        view.caretViewTracksFocus = false
        view.feed(text: "\u{1b}#\(decLineMode)\u{e0b1}\u{1b}[1D\u{1b}[2 q")
        let target = TerminalMetalLayerView(frame: frame)
        target.renderDevice = device
        target.renderContentsScale = 2
        target.renderDrawableSize = CGSize(width: frame.width * 2, height: frame.height * 2)
        let renderer = try MetalTerminalRenderer(target: target)
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesDrawData = true
        #expect(view.renderSnapshotForMetal(renderer: renderer, target: target))
        let data = try #require(renderer.lastDrawData)
        let row = try #require(data.rows.first { $0.glyphGrayCount > 0 })
        let buffer = try #require(row.glyphGrayBuffer)
        let separator = buffer.contents().assumingMemoryBound(to: TextCell.self).pointee
        let cursor = data.cursorGlyphVerticesGray
        try #require(!cursor.isEmpty)
        // Identical atlas coordinates prove the cursor did not rasterize a
        // separate hairline mask. DEC modes must transform/clip that same mask.
        #expect(cursor.map(\.texCoord.x).min() == separator.texOrigin.x)
        #expect(cursor.map(\.texCoord.y).min() == separator.texOrigin.y)
        #expect(cursor.map(\.texCoord.x).max() == separator.texOrigin.x + separator.texSize.x)
        #expect(cursor.map(\.texCoord.y).max() == separator.texOrigin.y + separator.texSize.y)
        #expect(cursor.map(\.position.x).min() == separator.position.x)
        #expect(cursor.map(\.position.y).min() == separator.position.y)
        #expect(cursor.map(\.position.x).max() == separator.position.x + separator.size.x)
        #expect(cursor.map(\.position.y).max() == separator.position.y + separator.size.y)
    }

}
#endif
