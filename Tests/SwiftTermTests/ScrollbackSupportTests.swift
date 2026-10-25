#if os(iOS)
import UIKit
import Testing
@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct ScrollbackSupportTests {
    private final class TrackingView: TerminalView {
        var simulatedTracking = false
        var simulatedDecelerating = false
        override var isDecelerating: Bool { simulatedDecelerating }
        override var isTracking: Bool { simulatedTracking }
    }

    @Test func outputRetainsHistoryAndTouchScrollShowsIt() throws {
        let view = TrackingView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        view.changeScrollback(500)
        view.feed(text: (0..<100).map { "row\($0)\r\n" }.joined())
        view.frameTick()
        let base = view.withTerminal { $0.buffer.yBase }
        #expect(base > 0)
        #expect(view.contentSize.height > view.bounds.height)
        view.simulatedTracking = true
        view.contentOffset = .zero
        #expect(view.withTerminal { $0.buffer.yDisp } == 0)
        let snapshot = try #require(view.terminalContentSnapshot(region: .viewport))
        #expect(snapshot.rows.first?.text == "row0")
    }

    @Test func accessibilityScrollShowsPreviousPage() {
        let view = TrackingView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        view.feed(text: (0..<100).map { "row\($0)\r\n" }.joined())
        view.frameTick()
        let previous = view.withTerminal { $0.buffer.yDisp }
        #expect(view.accessibilityScroll(.up))
        #expect(view.withTerminal { $0.buffer.yDisp } < previous)
    }

    @Test(arguments: [0.0, 0.25, 0.75])
    func accessibilityScrollToBottomResumesLiveOutput(partialRowFraction: Double) throws {
        let view = TrackingView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        defer { view.updateUiClosed() }
        let cellHeight = view.cellDimension.height
        view.frame.size.height = cellHeight * (15 + CGFloat(partialRowFraction))
        view.layoutIfNeeded()
        view.feed(text: (0..<100).map { "row\($0)\r\n" }.joined())
        view.frameTick()
        let maxRow = view.withTerminal { $0.buffer.lines.count - $0.buffer.rows }
        view.scrollTo(row: maxRow - 2)
        #expect(view.userScrolling)

        #expect(view.accessibilityScroll(.down))
        view.frameTick()
        let bottomRow = view.withTerminal { $0.buffer.yDisp }
        #expect(bottomRow == maxRow)
        #expect(!view.userScrolling)
        #expect(!view.withTerminal { $0.userScrolling })
        let state = try #require(view.captureFrameViewState())
        view.renderOwner.withSnapshotForDrawing(viewState: state) { snapshot, _ in
            #expect(snapshot.yDisp == maxRow)
        }

        view.feed(text: "new output\r\n")
        view.frameTick()
        let position = view.withTerminal { (displayed: $0.buffer.yDisp, base: $0.buffer.yBase) }
        #expect(position.displayed == position.base)
        #expect(position.base > maxRow)
    }

    @Test func touchScrollRefreshesRenderingSnapshot() async throws {
        let view = TrackingView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        view.setCursorStyle(.steadyBlock)
        view.feed(text: (0..<100).map { "row\($0)\r\n" }.joined())
        view.frameTick()
        let before = try #require(view.captureFrameViewState())
        view.renderOwner.withSnapshotForDrawing(viewState: before) { snapshot, _ in
            #expect(snapshot.yDisp > 0)
        }

        // Use a manual display tick so cursor blinking and startup frames
        // cannot refresh the snapshot and hide the missing scroll signal.
        view.frameDriver.shutdown()
        // Complete queued setup callbacks before installing the test driver.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        view.frameDriver = driver
        driver.onTick = { [weak view] in view?.frameTick() }
        defer { driver.shutdown() }

        view.simulatedTracking = true
        view.contentOffset = .zero
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        source.tick()

        let after = try #require(view.captureFrameViewState())
        view.renderOwner.withSnapshotForDrawing(viewState: after) { snapshot, _ in
            #expect(snapshot.yDisp == 0)
            #expect(snapshot.row(atAbsolute: 0) != nil)
        }
    }

    @Test func decelerationMovesThroughHistoryWithoutFreezingLiveOutput() {
        let view = TrackingView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        view.feed(text: (0..<100).map { "row\($0)\r\n" }.joined())
        view.frameTick()
        let cellHeight = view.cellDimension.height
        view.simulatedTracking = true
        view.contentOffset.y -= 10 * cellHeight
        let draggedRow = view.withTerminal { $0.buffer.yDisp }
        view.simulatedTracking = false
        view.simulatedDecelerating = true
        view.contentOffset.y -= 5 * cellHeight
        #expect(view.withTerminal { $0.buffer.yDisp } < draggedRow)
        #expect(view.userScrolling)
        view.contentOffset.y = view.contentSize.height - view.bounds.height
        #expect(!view.userScrolling)
        view.feed(text: "new output\r\n")
        view.contentOffset.y -= cellHeight
        #expect(!view.userScrolling)
    }

    @Test func touchScrollInvalidatesTheCopiedViewport() throws {
        let view = TrackingView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        view.feed(text: (0..<100).map { "row\($0)\r\n" }.joined())
        view.frameTick()
        view.simulatedTracking = true
        view.contentOffset = .zero
        let state = try #require(view.captureFrameViewState())
        let frame = try #require(view.prepareFrame(viewState: state))
        #expect(frame.region != nil)
    }
}
#endif
