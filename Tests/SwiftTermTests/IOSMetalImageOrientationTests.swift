#if os(iOS) && canImport(MetalKit)
import Metal
import MetalKit
import Testing
import UIKit

@testable import SwiftTerm

@Suite(.serialized)
@MainActor
struct IOSMetalImageOrientationTests {
    private static let width = 320
    private static let height = 120

    private func renderPixels(_ terminalView: TerminalView) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let mtkView = MTKView(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
                              device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = false
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        let target: any MetalRenderTarget = mtkView
        let scale = terminalView.backingScaleFactor()
        target.renderContentsScale = scale
        target.renderDrawableSize = CGSize(width: CGFloat(Self.width) * scale, height: CGFloat(Self.height) * scale)

        let renderer = try MetalTerminalRenderer(target: target)
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesRenderedTexture = true
        #expect(terminalView.renderSnapshotForMetal(renderer: renderer, target: target))
        let texture = try #require(renderer.lastRenderedTexture)

        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!,
                             bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                             mipmapLevel: 0)
        }
        return (bytes, texture.width, texture.height)
    }

    /// Average row of the pixels that match `predicate`, counted from the top.
    private func meanRow(_ frame: (bytes: [UInt8], width: Int, height: Int),
                         where predicate: (_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool) -> Double? {
        var total = 0
        var count = 0
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let i = (y * frame.width + x) * 4
                if predicate(frame.bytes[i + 2], frame.bytes[i + 1], frame.bytes[i]) {
                    total += y
                    count += 1
                }
            }
        }
        return count == 0 ? nil : Double(total) / Double(count)
    }

    @Test func sixelImageDrawsTopRowsAtTheTop() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        // 24x12 sixel: the first six-pixel band is red, the second is blue.
        view.feed(text: "\u{1b}Pq\"1;1;24;12#1;2;100;0;0#2;2;0;0;100#1!24~-#2!24~\u{1b}\\")

        let frame = try renderPixels(view)
        let red = try #require(meanRow(frame) { r, g, b in r > 200 && g < 60 && b < 60 })
        let blue = try #require(meanRow(frame) { r, g, b in b > 200 && r < 60 && g < 60 })
        #expect(red < blue, "red band drawn at row \(red), blue band at row \(blue)")
    }
}
#endif
