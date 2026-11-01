#if os(macOS)
import AppKit
import CoreGraphics
import Testing
@testable import SwiftTerm

/// Regression tests: `CaretView.drawCursor` saved the graphics
/// state but the early-return branches (unfocused caret, non-block cursor
/// styles) never restored it, leaking the clip-to-bounds into whatever the
/// caller drew next. CGContext exposes no gState depth, so balance is probed
/// behaviorally: after drawing the caret, a fill that covers the whole bitmap
/// must also paint pixels *outside* the caret bounds — a leaked clip would
/// confine that fill to the caret rect.
@MainActor
final class CaretViewGStateTests {
    private let contextSize = CGSize(width: 32, height: 32)
    private let caretBounds = CGRect(x: 0, y: 0, width: 8, height: 16)

    private func makeCaret(style: CursorStyle, powerlineCodePoint: UInt32? = nil) throws -> (view: TerminalView, caret: CaretView) {
        let font = try #require(NSFont(name: "Menlo", size: 12))
        let view = TerminalView(frame: .zero, font: font)
        let caret = CaretView(frame: caretBounds, cursorStyle: style, terminal: view)
        caret.ctline = CTLineCreateWithAttributedString(
            NSAttributedString(string: "A", attributes: [.font: font]))
        caret.powerlineCodePoint = powerlineCodePoint
        return (view, caret)
    }

    private func makeContext() throws -> CGContext {
        let width = Int(contextSize.width)
        let height = Int(contextSize.height)
        return try #require(CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    }

    /// Paints the whole context red, draws the caret, fills the whole context
    /// with green, then returns the pixel well outside the caret bounds. A
    /// balanced save/restore leaves the clip popped, so that pixel must be
    /// green; a leaked gState keeps the clip to the caret bounds active and
    /// the pixel stays red.
    private func probePixelOutsideCaretBounds(caret: CaretView, hasFocus: Bool) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let context = try makeContext()
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: contextSize))

        caret.drawCursor(in: context, hasFocus: hasFocus)

        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: contextSize))

        let data = try #require(context.data).bindMemory(to: UInt8.self, capacity: context.bytesPerRow * context.height)
        let offset = (context.height - 1) * context.bytesPerRow + (context.width - 1) * 4
        return (r: data[offset], g: data[offset + 1], b: data[offset + 2])
    }

    private func expectClipRestored(caret fixture: (view: TerminalView, caret: CaretView),
                                    hasFocus: Bool, _ label: String) throws {
        // CaretView keeps a weak terminal reference. Keep the view alive so
        // drawCursor reaches the graphics-state changes instead of returning
        // from its initial nil-terminal guard.
        let pixel = try withExtendedLifetime(fixture.view) {
            try #require(fixture.caret.terminal === fixture.view)
            return try probePixelOutsideCaretBounds(caret: fixture.caret, hasFocus: hasFocus)
        }
        // Green reads back as 249 rather than 255 due to color-space
        // conversion, so assert dominance rather than exact components.
        #expect(pixel.g > 200 && pixel.r < 30 && pixel.b < 30,
                "\(label): gState leaked, fill outside the caret bounds was clipped (got r=\(pixel.r) g=\(pixel.g) b=\(pixel.b))")
    }

    @Test func unfocusedCaretRestoresGraphicsState() throws {
        // The `!hasFocus` branch used to return without restoreGState().
        for style: CursorStyle in [.steadyBlock, .blinkBlock, .steadyBar, .blinkBar, .steadyUnderline, .blinkUnderline] {
            try expectClipRestored(caret: makeCaret(style: style), hasFocus: false, "unfocused \(style)")
        }
    }

    @Test func nonBlockCaretRestoresGraphicsState() throws {
        // Bar and underline styles hit the `guard style == .steadyBlock ...`
        // early return, which used to skip restoreGState().
        for style: CursorStyle in [.steadyBar, .blinkBar, .steadyUnderline, .blinkUnderline] {
            try expectClipRestored(caret: makeCaret(style: style), hasFocus: true, "focused \(style)")
        }
    }

    @Test func blockCaretRestoresGraphicsState() throws {
        // The glyph-drawing block path already restored; keep it covered.
        for style: CursorStyle in [.steadyBlock, .blinkBlock] {
            try expectClipRestored(caret: makeCaret(style: style), hasFocus: true, "focused \(style)")
        }
    }

    @Test func powerlineBlockCaretRestoresGraphicsState() throws {
        // The powerline branch had its own explicit restore before returning.
        for style: CursorStyle in [.steadyBlock, .blinkBlock] {
            try expectClipRestored(caret: makeCaret(style: style, powerlineCodePoint: 0xE0B0),
                                   hasFocus: true, "focused powerline \(style)")
        }
    }
}
#endif
