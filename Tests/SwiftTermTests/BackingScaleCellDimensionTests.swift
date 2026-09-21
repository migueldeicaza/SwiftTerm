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

    @Test func cellDimensionRecordsTheScaleItWasMeasuredAt() throws {
        let view = try makeView()
        #expect(view.cellDimensionBackingScale == view.backingScaleFactor())
    }

    @Test func backingChangeAtTheSameScaleKeepsTheGrid() throws {
        let view = try makeView()
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
        let expected = view.computeFontDimensions()

        // Stand in for a grid measured on a screen of another density: sizes
        // that do not sit on this screen's pixel grid, recorded for a scale
        // that is not this screen's.
        view.cellDimension = TerminalView.CellDimension(width: expected.width + 0.3,
                                                        height: expected.height + 0.3)
        view.cellDimensionBackingScale = view.backingScaleFactor() * 2

        view.viewDidChangeBackingProperties()

        #expect(view.cellDimension.width == expected.width)
        #expect(view.cellDimension.height == expected.height)
        #expect(view.cellDimensionBackingScale == view.backingScaleFactor())
        let expectedCols = Int(view.getEffectiveWidth(size: frame.size) / expected.width)
        #expect(view.withTerminal { $0.cols } == expectedCols)
    }
}
#endif
