import XCTest
@testable import SwiftTerm

#if canImport(UIKit)
import MetalKit

/// Upstream migueldeicaza/SwiftTerm#731 review: an iOS viewport can
/// show a partial row above `buffer.yDisp`. A full redraw (a color
/// change drives `updateFullScreen`, whose `rowEnd == rows` fails the
/// in-range check and takes the fallback) must dirty that row too, so
/// the fallback uses `metalVisibleRange()`, not `yDisp ...`.
final class IOSMetalDirtyRangeTests: XCTestCase {

    /// Scrolled so a row's bottom sliver sits above the first fully
    /// visible row (yDisp = 23 while the viewport starts inside row
    /// 22): a full redraw must dirty 22...N, not 23...N.
    func testFullRedrawDirtiesPartialTopRow() throws {
        let rows = 8
        let view = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 200),
            options: TerminalOptions(cols: 40, rows: rows, scrollback: 80))
        // A bare MTKView is enough: the flagged branch keys on
        // `metalView != nil` and `requestMetalDisplay()` only calls
        // `setNeedsDisplay`. Going through `setUseMetal(true)` would
        // need the shader library, which is not staged for the test
        // runner — and is not what this test covers.
        view.metalView = MTKView(frame: view.bounds,
                                 device: MTLCreateSystemDefaultDevice())

        for i in 0..<60 {
            view.feed(text: "line \(i)\r\n")
        }
        view.terminal.clearUpdateRange()

        let cellH = view.cellDimension.height
        XCTAssertGreaterThan(cellH, 0)

        // yDisp one row below the viewport's top edge: row 22 is the
        // partially visible row above it. Setting contentOffset after
        // yDisp leaves the state the isTracking guard produces on a
        // real drag — no snap back to a whole row.
        view.terminal.setViewYDisp(23)
        view.contentOffset = CGPoint(x: 0, y: 22.5 * cellH)

        let visible = try XCTUnwrap(view.metalVisibleRange())
        XCTAssertEqual(visible.lowerBound, 22)
        XCTAssertEqual(view.terminal.displayBuffer.yDisp, 23)

        // The maintainer's case: a color change marks the full screen,
        // and refreshEnd == rows lands outside the in-range check.
        view.terminal.updateFullScreen()
        view.updateDisplay(notifyAccessibility: false)

        XCTAssertEqual(view.metalDirtyRange, visible,
                       "full redraw must cover the partial top row")
    }

    /// Feeds 60 lines with row `blinkRow` in SGR 5, then scrolls so row 22
    /// is the partial row above yDisp = 23.
    private func makeScrolledView(blinkRow: Int? = nil) throws -> TerminalView {
        let view = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 200),
            options: TerminalOptions(cols: 40, rows: 8, scrollback: 80))
        view.metalView = MTKView(frame: view.bounds,
                                 device: MTLCreateSystemDefaultDevice())
        for i in 0..<60 {
            view.feed(text: i == blinkRow ? "\u{1b}[5mline \(i)\u{1b}[0m\r\n" : "line \(i)\r\n")
        }
        view.terminal.clearUpdateRange()
        view.terminal.setViewYDisp(23)
        view.contentOffset = CGPoint(x: 0, y: 22.5 * view.cellDimension.height)
        view.metalDirtyRange = nil
        XCTAssertEqual(try XCTUnwrap(view.metalVisibleRange()).lowerBound, 22)
        return view
    }

    /// Review round 2: a blink phase change must redraw blinking text in
    /// the partial top row, which a yDisp-relative scan never reaches.
    func testBlinkChangeDirtiesPartialTopRow() throws {
        let view = try makeScrolledView(blinkRow: 22)
        XCTAssertEqual(view.visibleBlinkRows(), [22])

        view.setTextBlinkVisibleForTesting(false)
        view.updateDisplay(notifyAccessibility: false)

        XCTAssertTrue(view.metalDirtyRange?.contains(22) ?? false,
                      "blink change must dirty the partial top row")
    }

    /// Same class: a link highlight on the partial top row.
    func testLinkHighlightDirtiesPartialTopRow() throws {
        let view = try makeScrolledView()
        view.invalidateLinkHighlightRow(22)
        XCTAssertTrue(view.metalDirtyRange?.contains(22) ?? false,
                      "link highlight must dirty the partial top row")
    }
}
#endif
