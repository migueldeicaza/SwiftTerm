import Testing
@testable import SwiftTerm

#if os(macOS)
import AppKit

/// Records the rects `updateDisplay` asks AppKit to repaint.
private final class InvalidationCapturingTerminalView: TerminalView {
    var invalidated: [NSRect] = []

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        invalidated.append(invalidRect)
        super.setNeedsDisplay(invalidRect)
    }
}

struct ScrollbackRepaintTests {
    private let esc = "\u{1b}"

    /// The update range is recorded in `buffer.y` space (relative to `yBase`),
    /// but the draw maps screen rects back to buffer rows through `yDisp`. When
    /// the viewport is scrolled back the two disagree by `yBase - yDisp`, so a
    /// partial invalidation lands on the wrong screen rows and the cells that
    /// changed keep stale content.
    ///
    /// Scrolling output hides this, since `scroll()` dirties both `scrollTop`
    /// and `scrollBottom` and the whole view gets invalidated anyway. The case
    /// that stays exposed is an in-place repaint, so the write below neither
    /// scrolls nor moves the cursor between rows.
    @Test func inPlaceRepaintWhileScrolledBackInvalidatesRenderedRow() {
        let view = InvalidationCapturingTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        let terminal: Terminal = view.terminal
        let cellHeight = view.cellDimension.height

        for i in 0..<(terminal.rows * 3) {
            terminal.feed(text: "line \(i)\r\n")
        }
        view.updateDisplay()

        let scrolledBackBy = 3
        let maxScrollback = max(0, terminal.buffer.lines.count - terminal.buffer.rows)
        view.scrollTo(row: maxScrollback - scrolledBackBy)
        #expect(terminal.buffer.yBase - terminal.buffer.yDisp == scrolledBackBy)

        // Park the cursor on the target row and flush, so the repaint below
        // dirties only that row instead of also dirtying the row it came from.
        let targetRow = 2
        terminal.feed(text: "\(esc)[\(targetRow + 1);1H")
        view.updateDisplay()
        terminal.clearUpdateRange()
        view.invalidated.removeAll()

        terminal.feed(text: "XXXX")
        let updateRange = terminal.getUpdateRange()
        #expect(updateRange?.startY == targetRow)
        #expect(updateRange?.endY == targetRow)
        view.updateDisplay()

        // The change is on buffer row `targetRow` of the live screen, which is
        // drawn `yBase - yDisp` rows further down the viewport.
        let renderedRow = targetRow + (terminal.buffer.yBase - terminal.buffer.yDisp)
        let rowBottom = view.frame.height - CGFloat(renderedRow + 1) * cellHeight
        let rowTop = rowBottom + cellHeight
        let repainted = view.invalidated.contains { $0.minY <= rowBottom && $0.maxY >= rowTop }
        #expect(repainted, "invalidated \(view.invalidated), change renders at [\(rowBottom), \(rowTop)]")
    }
}
#endif
