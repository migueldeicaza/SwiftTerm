#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
struct BidiCursorDirectionTests {
    private func makeView(state: BidiPresentationState) -> TerminalView {
        TerminalView(frame: .zero, font: nil,
                     options: TerminalOptions(cols: 12, rows: 4,
                                              initialBidiState: state))
    }

    private func refresh(_ snapshot: TerminalSnapshot, from view: TerminalView,
                         deferred: Bool) {
        view.withTerminal { terminal in
            #expect(snapshot.refresh(
                terminal: terminal, viewState: FrameViewState(view: view),
                selection: SnapshotSelectionState(selection: view.selection),
                deferBidiTypesetting: deferred) == .refreshed)
        }
        if deferred { snapshot.completePendingBidi() }
    }

    @Test(arguments: [false, true])
    func explicitRtlUsesRightEdgeForTextAndErasedCells(deferred: Bool) throws {
        let view = makeView(state: BidiPresentationState(
            supportMode: .explicit, fallbackDirection: .rightToLeft))
        view.feed(text: "a界")
        let snapshot = TerminalSnapshot()

        for column in [0, 1, 2, 8] {
            view.withTerminal { $0.buffer.x = column }
            refresh(snapshot, from: view, deferred: deferred)
            let cursor = try #require(snapshot.cursor)
            #expect(cursor.renderData.direction == .rightToLeft)
            let bounds = CGRect(x: 0, y: 0, width: CGFloat(10 * cursor.columnWidth), height: 20)
            let bar = CursorGeometry.barRect(in: bounds,
                                            direction: cursor.renderData.direction, width: 2)
            #expect(bar.maxX == bounds.maxX)
            if column == 1 { #expect(cursor.columnWidth == 2) }
        }

        view.feed(text: "\u{1b}[2K")
        refresh(snapshot, from: view, deferred: deferred)
        #expect(snapshot.cursor?.renderData.direction == .rightToLeft)
    }

    @Test(arguments: [false, true])
    func implicitRtlUsesTheCellDirection(deferred: Bool) throws {
        let view = makeView(state: BidiPresentationState(
            autodetectDirection: false, fallbackDirection: .rightToLeft))
        view.feed(text: "אב 12")
        let snapshot = TerminalSnapshot()

        for (column, direction) in [(0, BidiDirection.rightToLeft),
                                    (1, .rightToLeft), (3, .leftToRight), (4, .leftToRight)] {
            view.withTerminal { $0.buffer.x = column }
            refresh(snapshot, from: view, deferred: deferred)
            let cursor = try #require(snapshot.cursor)
            #expect(cursor.renderData.direction == direction)
            let bar = CursorGeometry.barRect(
                in: CGRect(x: 0, y: 0, width: 10, height: 20),
                direction: cursor.renderData.direction, width: 2)
            #expect(bar.minX == (direction == .rightToLeft ? 8 : 0))
        }
    }

    @Test(arguments: [false, true])
    func legacyHostPolicyUsesLeftEdge(deferred: Bool) throws {
        let view = makeView(state: BidiPresentationState(
            supportMode: .explicit, fallbackDirection: .rightToLeft))
        view.bidiHostPolicy = .legacyLeftToRight
        view.feed(text: "אב")
        view.withTerminal { $0.buffer.x = 0 }
        let snapshot = TerminalSnapshot()
        refresh(snapshot, from: view, deferred: deferred)
        #expect(snapshot.cursor?.renderData.direction == .leftToRight)
        #expect(snapshot.cursor?.visualCol == 0)
    }

    @Test func deferredLtrLayoutResetsDirection() throws {
        let view = makeView(state: BidiPresentationState(
            autodetectDirection: true, fallbackDirection: .rightToLeft))
        let snapshot = TerminalSnapshot()
        view.feed(text: "אבג")
        view.withTerminal { $0.buffer.x = 0 }
        refresh(snapshot, from: view, deferred: true)
        #expect(snapshot.cursor?.renderData.direction == .rightToLeft)

        view.feed(text: "\u{1b}[2Kabc")
        view.withTerminal { $0.buffer.x = 0 }
        refresh(snapshot, from: view, deferred: true)
        #expect(snapshot.rows.first?.bidiLayout == nil)
        #expect(snapshot.cursor?.renderData.direction == .leftToRight)
        #expect(snapshot.cursor?.visualCol == 0)
    }

    @Test func barGeometryFitsNarrowBoundsAndMatchesScaledCoordinates() {
        for direction in [BidiDirection.leftToRight, .rightToLeft] {
            let narrow = CGRect(x: 5, y: 7, width: 1, height: 20)
            #expect(CursorGeometry.barRect(in: narrow, direction: direction, width: 2) == narrow)
            let bounds = CGRect(x: 5, y: 7, width: 20, height: 30)
            let points = CursorGeometry.barRect(in: bounds, direction: direction, width: 2)
            let pixels = CursorGeometry.barRect(
                in: CGRect(x: 10, y: 14, width: 40, height: 60),
                direction: direction, width: 4)
            #expect(pixels == CGRect(x: points.minX * 2, y: points.minY * 2,
                                     width: points.width * 2, height: points.height * 2))
        }
    }
}
#endif
