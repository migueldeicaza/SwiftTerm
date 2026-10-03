#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

/// The cell grid is snapped to the pixel density of the screen the view was on
/// when the font was set. These tests cover re-snapping it when that density
/// changes, which `viewDidChangeBackingProperties` reports.
@MainActor
struct BackingScaleCellDimensionTests {
    private let frame = CGRect(x: 0, y: 0, width: 400, height: 200)

    private func makeView() throws -> TerminalView {
        let font = try #require(NSFont(name: "Monaco", size: 12))
        return TerminalView(frame: frame, font: font)
    }

    /// Hosts views under a plain content view, so a test can detach and
    /// reattach one without tearing the window down.
    private let window: NSWindow

    init() {
        window = NSWindow(contentRect: frame, styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.contentView = NSView(frame: frame)
    }

    private func host(_ view: TerminalView) {
        window.contentView?.addSubview(view)
    }

    /// Stands in for a grid measured, and a terminal sized, on a screen of
    /// another density: cell sizes that do not sit on this screen's pixel
    /// grid, recorded for a scale no screen has (so it differs from both the
    /// main screen and the test window).
    private func pretendMeasuredOnAnotherScreen(_ view: TerminalView) {
        let current = view.cellDimension!
        view.cellDimension = TerminalView.CellDimension(width: current.width + 0.3,
                                                        height: current.height + 0.3)
        view.cellDimensionBackingScale = 0.5
        view.processSizeChange(newSize: frame.size)
    }

    @Test func cellDimensionRecordsTheScaleItWasMeasuredAt() throws {
        let view = try makeView()
        #expect(view.cellDimensionBackingScale == view.backingScaleFactor())
    }

    @Test func backingChangeAtTheSameScaleKeepsTheGrid() throws {
        let view = try makeView()
        host(view)
        let before = view.cellDimension!
        let cols = view.withTerminal { $0.cols }

        #expect(view.remeasureCellDimensionIfBackingScaleChanged() == false)
        view.viewDidChangeBackingProperties()

        #expect(view.cellDimension.width == before.width)
        #expect(view.cellDimension.height == before.height)
        #expect(view.withTerminal { $0.cols } == cols)
    }

    @Test func backingChangeToAnotherScaleResnapsTheGrid() throws {
        let view = try makeView()
        host(view)
        let expected = view.computeFontDimensions()
        pretendMeasuredOnAnotherScreen(view)

        view.viewDidChangeBackingProperties()

        #expect(view.cellDimension.width == expected.width)
        #expect(view.cellDimension.height == expected.height)
        #expect(view.cellDimensionBackingScale == view.backingScaleFactor())
        let expectedCols = Int(view.getEffectiveWidth(size: frame.size) / expected.width)
        #expect(view.withTerminal { $0.cols } == expectedCols)
    }

    /// `resize(cols:rows:)` soft-resets the terminal; a screen move must not
    /// clear modes the running program set.
    @Test func backingChangeKeepsApplicationCursorMode() throws {
        let view = try makeView()
        host(view)
        view.feed(text: "\u{1b}[?1h")
        #expect(view.withTerminal { $0.applicationCursor })
        pretendMeasuredOnAnotherScreen(view)
        let cols = view.withTerminal { $0.cols }

        view.viewDidChangeBackingProperties()

        // The column count changed, so this went through a terminal resize.
        #expect(view.withTerminal { $0.cols } != cols)
        #expect(view.withTerminal { $0.applicationCursor })
    }

    @Test func detachingDoesNotResizeTheTerminal() throws {
        let view = try makeView()
        host(view)
        pretendMeasuredOnAnotherScreen(view)
        let before = view.cellDimension!
        let cols = view.withTerminal { $0.cols }
        let delegate = SizeChangeCountingDelegate()
        view.terminalDelegate = delegate

        view.removeFromSuperview()
        view.viewDidChangeBackingProperties()

        #expect(view.cellDimension.width == before.width)
        #expect(view.cellDimension.height == before.height)
        #expect(view.withTerminal { $0.cols } == cols)
        #expect(delegate.sizeChanges == 0)
    }

    @Test func attachingToAWindowAtAnotherScaleMeasuresOnce() throws {
        let view = try makeView()
        pretendMeasuredOnAnotherScreen(view)
        let delegate = SizeChangeCountingDelegate()
        view.terminalDelegate = delegate

        host(view)

        #expect(view.cellDimensionBackingScale == window.backingScaleFactor)
        #expect(delegate.sizeChanges == 1)
        let measured = view.cellDimension!

        // Later backing callbacks at the same scale leave the grid alone.
        #expect(view.remeasureCellDimensionIfBackingScaleChanged() == false)
        view.viewDidChangeBackingProperties()
        #expect(delegate.sizeChanges == 1)
        let expected = view.computeFontDimensions()
        #expect(measured.width == expected.width)
        #expect(measured.height == expected.height)
    }
}

private final class SizeChangeCountingDelegate: TerminalViewDelegate {
    var sizeChanges = 0

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { sizeChanges += 1 }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
#endif
