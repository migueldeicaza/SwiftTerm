#if os(macOS) && !SWIFTTERM_EMBEDDED
import AppKit
import CoreGraphics
import Testing
@testable import SwiftTerm

@MainActor
struct PowerlineCaretBitmapTests {
    @Test func caretMatchesRowInEveryDECMode() throws {
        let view = TerminalView(frame: .zero, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        view.frameDriver.invalidate()
        let scale = view.backingScaleFactor()
        let thickness = max(max(1, Int(round(scale))),
                            Int(round(scale * view.fontSet.underlineThickness() * 1.35)))
        let modes: [BufferLine.RenderLineMode] = [.single, .doubleWidth, .doubledTop, .doubledDown]
        for mode in modes {
            let doubleWidth: CGFloat = mode == .single ? 1 : 2
            let doubleHeight: CGFloat = mode == .doubledTop || mode == .doubledDown ? 2 : 1
            let bounds = CGRect(x: 0, y: 0, width: 8 * doubleWidth, height: 12)
            for code: UInt32 in [0xE0B1, 0xE0B5, 0xE0B9, 0xE0C1, 0xE0D7] {
                let caret = CaretView(frame: bounds, cursorStyle: .steadyBlock, terminal: view)
                caret.powerlineRenderMode = mode
                caret.setText(CaretRenderData(
                    code: Int32(code), width: 1, cellAttribute: Attribute(fg: .defaultColor, bg: .defaultColor, style: .none),
                    character: Character(UnicodeScalar(code)!), attributes: [.font: view.fontSet.normal],
                    cursorColor: .clear, textColor: .white, textBlinkVisible: true,
                    customBlockGlyphs: true, normalFont: view.fontSet.normal))
                let actual = try bitmap(bounds: bounds, scale: scale) {
                    caret.drawCursor(in: $0, hasFocus: true)
                }
                let reference = try bitmap(bounds: bounds, scale: scale) { context in
                    context.clip(to: bounds)
                    if mode == .doubledTop { context.translateBy(x: 0, y: -bounds.height) }
                    context.scaleBy(x: doubleWidth, y: doubleHeight)
                    PowerlineRenderer.draw(codePoint: code, in: context,
                                           cellRect: CGRect(x: 0, y: 0, width: 8, height: 12),
                                           scaleX: scale * doubleWidth, scaleY: scale * doubleHeight,
                                           color: NSColor.white.cgColor,
                                           lineWidthPx: thickness * Int(doubleHeight),
                                           includeJoinOverdraw: false)
                }
                #expect(actual == reference, "Caret and row differ for U+\(String(code, radix: 16)), mode \(mode)")
            }
        }
        withExtendedLifetime(view) {}
    }

    private func bitmap(bounds: CGRect, scale: CGFloat, draw: (CGContext) -> Void) throws -> [UInt8] {
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        let context = try #require(CGContext(data: nil, width: width, height: height,
                                           bitsPerComponent: 8, bytesPerRow: width * 4,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        draw(context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: width * height * 4))
    }
}
#endif
