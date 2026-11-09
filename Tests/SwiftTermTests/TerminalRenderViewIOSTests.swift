#if os(iOS) || os(visionOS)
import UIKit
import Foundation
import Testing

@testable import SwiftTerm

/// An external source with fixed lines, for the iOS render view tests.
@MainActor
final class FixedFrameSourceIOS: TerminalExternalFrameSource {
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
        for (column, character) in text.enumerated() {
            store.setCell(line, column: column, text: String(character), width: 1, attribute: attribute)
        }
        lines[number] = line
    }

    func withFrame(_ body: (TerminalExternalFrame, TerminalRowStore, (Int) -> BufferLine?) -> Void) {
        body(frame, store) { self.lines[$0] }
    }
}

@MainActor
@Suite(.serialized)
struct TerminalRenderViewIOSTests {
    let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let red = Attribute(foreground: .defaultColor, background: .ansi256(code: 1), style: [])

    private func makeView(columns: Int, rows: Int) -> TerminalRenderView {
        let view = TerminalRenderView(frame: .zero, font: font)
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        view.frame = CGRect(x: 0, y: 0, width: view.cellSize.width * CGFloat(columns),
                            height: view.cellSize.height * CGFloat(rows))
        view.layoutIfNeeded()
        return view
    }

    /// Renders the view's layer tree (background, drawing and subviews).
    private func image(_ view: UIView) -> CGImage {
        view.setNeedsDisplay()
        view.layer.displayIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
        return renderer.image { context in
            view.layer.render(in: context.cgContext)
        }.cgImage!
    }

    /// Counts the pixels of each screen row (top first) that `predicate` matches.
    private func countByRow(_ image: CGImage, rows: Int,
                            _ predicate: (_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool) -> [Int] {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let rowHeight = height / rows
        var result = [Int](repeating: 0, count: rows)
        // CGContext memory starts at the top row of the image.
        for y in 0 ..< height {
            let row = min(rows - 1, y / rowHeight)
            // Skip the edge pixels of each row, which can blend.
            if y % rowHeight == 0 || y % rowHeight == rowHeight - 1 { continue }
            for x in 0 ..< width {
                let i = (y * width + x) * 4
                if predicate(data[i], data[i + 1], data[i + 2]) { result[row] += 1 }
            }
        }
        return result
    }

    private func isRed(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { r > 150 && g < 80 && b < 80 }
    private func isLit(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { Int(r) + Int(g) + Int(b) > 50 }

    @Test func drawsExternalRows() {
        let source = FixedFrameSourceIOS(columns: 10, rows: 3, topLine: 500)
        source.setLine(500, "RED", attribute: red)
        source.setLine(502, "RED", attribute: red)
        let view = makeView(columns: 10, rows: 3)
        view.frameSource = source
        view.frameTick()
        let counts = countByRow(image(view), rows: 3, isRed)
        #expect(counts[0] > 0)
        #expect(counts[1] == 0)
        #expect(counts[2] > 0)
        #expect(view.gridSize.columns == 10)
        #expect(view.gridSize.rows == 3)
    }

    @Test func negativeLineNumbersDraw() {
        let source = FixedFrameSourceIOS(columns: 10, rows: 5, topLine: -10)
        source.setLine(-10, "RED", attribute: red)
        source.setLine(-6, "RED", attribute: red)
        let view = makeView(columns: 10, rows: 5)
        view.frameSource = source
        view.frameTick()
        let counts = countByRow(image(view), rows: 5, isRed)
        #expect(counts[0] > 0)
        #expect(counts[2] == 0)
        #expect(counts[4] > 0)
    }

    /// The caret is placed from the top of the view, on the cursor row.
    @Test func caretFollowsTheCursor() {
        let source = FixedFrameSourceIOS(columns: 10, rows: 3, topLine: 40)
        source.frame.cursorVisible = true
        source.frame.cursorLine = 41
        source.frame.cursorColumn = 3
        let view = makeView(columns: 10, rows: 3)
        view.frameSource = source
        view.frameTick()
        #expect(view.caretFrame.origin.x == view.cellSize.width * 3)
        #expect(view.caretFrame.origin.y == view.cellSize.height)
        #expect(view.subviews.contains { $0 is CaretView })
        #expect(view.cell(at: CGPoint(x: view.cellSize.width * 3.5, y: view.cellSize.height * 1.5)) == (3, 1))
    }

    /// With no source, the view shows only the background, with no caret.
    @Test func lostSourceClearsTheView() {
        var source: FixedFrameSourceIOS? = FixedFrameSourceIOS(columns: 10, rows: 3, topLine: 0)
        source!.setLine(0, "RED", attribute: red)
        source!.frame.cursorVisible = true
        source!.frame.cursorLine = 1
        let view = makeView(columns: 10, rows: 3)
        view.frameSource = source
        view.frameTick()
        #expect(view.subviews.contains { $0 is CaretView })
        #expect(countByRow(image(view), rows: 3, isRed)[0] > 0)

        source = nil
        #expect(view.frameSource == nil)
        view.requestRedraw()
        view.frameTick()
        #expect(!view.subviews.contains { $0 is CaretView })
        #expect(countByRow(image(view), rows: 3, isLit).allSatisfy { $0 == 0 })

        let next = FixedFrameSourceIOS(columns: 10, rows: 3, topLine: 0)
        next.setLine(0, "RED", attribute: red)
        view.frameSource = next
        view.frameTick()
        #expect(countByRow(image(view), rows: 3, isRed)[0] > 0)
    }

    /// Only the changed rows are invalidated; text in them redraws.
    @Test func changedRowRedraws() {
        let source = FixedFrameSourceIOS(columns: 10, rows: 3, topLine: 0)
        let view = makeView(columns: 10, rows: 3)
        view.frameSource = source
        view.frameTick()
        #expect(countByRow(image(view), rows: 3, isRed).allSatisfy { $0 == 0 })
        source.setLine(1, "RED", attribute: red)
        view.requestRedraw()
        view.frameTick()
        let counts = countByRow(image(view), rows: 3, isRed)
        #expect(counts[0] == 0)
        #expect(counts[1] > 0)
        #expect(counts[2] == 0)
    }
}
#endif
