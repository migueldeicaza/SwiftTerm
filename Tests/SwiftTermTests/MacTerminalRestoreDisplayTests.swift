#if os(macOS)
import XCTest

@testable import SwiftTerm

final class MacTerminalRestoreDisplayTests: XCTestCase {
    private final class RecordingTerminalView: TerminalView {
        var invalidRects: [CGRect] = []

        override func setNeedsDisplay(_ invalidRect: NSRect) {
            invalidRects.append(invalidRect)
            super.setNeedsDisplay(invalidRect)
        }
    }

    func testResyncDisplayAfterViewRestoreClearsUserScrollingAndSnapsViewportToCaret() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 240, height: 160))

        for index in 0..<120 {
            view.terminal.feed(text: "line \(index)\n")
        }

        let bufferBeforeRestore = view.terminal.displayBuffer
        XCTAssertGreaterThan(bufferBeforeRestore.yBase, 0)

        view.scrollTo(row: 0, notifyAccessibility: false)
        view.terminal.userScrolling = true

        XCTAssertLessThan(view.terminal.displayBuffer.yDisp, view.terminal.displayBuffer.yBase)
        XCTAssertTrue(view.terminal.userScrolling)

        view.resyncDisplayAfterViewRestore()

        XCTAssertEqual(view.terminal.displayBuffer.yDisp, view.terminal.displayBuffer.yBase)
        XCTAssertFalse(view.terminal.userScrolling)
    }

    func testResyncDisplayAfterViewRestoreInvalidatesFullViewport() {
        let view = RecordingTerminalView(frame: CGRect(x: 0, y: 0, width: 240, height: 160))

        for index in 0..<40 {
            view.terminal.feed(text: "line \(index)\n")
        }

        view.invalidRects.removeAll()
        view.resyncDisplayAfterViewRestore()

        XCTAssertFalse(view.pendingDisplay)
        XCTAssertEqual(view.invalidRects.last?.integral, view.bounds.integral)
    }
}
#endif
