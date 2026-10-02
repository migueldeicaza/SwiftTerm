import XCTest
import MetalKit
@testable import SwiftTerm

#if canImport(UIKit)
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
}
#endif
