#if os(iOS)
import UIKit
import Testing

@testable import SwiftTerm

@Suite(.serialized)
@MainActor
struct IOSPointerInputTests {
    private final class Delegate: TerminalViewDelegate {
        var writes: [[UInt8]] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // The callback must run after the terminal lock is released.
            _ = source.terminalStateSnapshot()
            writes.append(Array(data))
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    }

    private final class PointerPan: UIPanGestureRecognizer {
        var point = CGPoint(x: 10, y: 10)
        var keys: UIKeyModifierFlags = []
        var testTranslation = CGPoint.zero
        var testState: UIGestureRecognizer.State = .changed
        override var state: UIGestureRecognizer.State {
            get { testState }
            set { testState = newValue }
        }
        override var modifierFlags: UIKeyModifierFlags { keys }
        override func location(in view: UIView?) -> CGPoint { point }
        override func translation(in view: UIView?) -> CGPoint { testTranslation }
        override func setTranslation(_ translation: CGPoint, in view: UIView?) {
            testTranslation = translation
        }
    }

    private func fixture(_ modes: String = "\u{1b}[?1000h\u{1b}[?1006h") async -> (TerminalView, Delegate, PointerPan) {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let delegate = Delegate()
        view.terminalDelegate = delegate
        view.feed(text: modes)
        let gesture = PointerPan()
        gesture.allowedScrollTypesMask = .continuous
        view.addGestureRecognizer(gesture)
        await drainCallbacks()
        return (view, delegate, gesture)
    }

    private func drainCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func strings(_ delegate: Delegate) -> [String] {
        delegate.writes.map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func pointerRecognizerAcceptsScrollWithoutTouches() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let pointerPans = (view.gestureRecognizers ?? []).compactMap { $0 as? UIPanGestureRecognizer }
            .filter { $0 !== view.panGestureRecognizer && !$0.allowedScrollTypesMask.isEmpty }
        #expect(pointerPans.count == 2)
        #expect(pointerPans.filter { $0.allowedScrollTypesMask == .continuous }.count == 1)
        #expect(pointerPans.filter { $0.allowedScrollTypesMask == .discrete }.count == 1)
        #expect(pointerPans.allSatisfy { $0.allowedTouchTypes.isEmpty })
    }

    @Test func wheelDirectionAndFractionalTravel() async {
        let (view, delegate, gesture) = await fixture()
        let height = view.cellDimension.height
        #expect(height > 0)
        view.forwardPointerScroll(distance: height * 0.75, gestureRecognizer: gesture)
        await drainCallbacks()
        #expect(delegate.writes.isEmpty)
        view.forwardPointerScroll(distance: height * 0.5, gestureRecognizer: gesture)
        await drainCallbacks()
        #expect(strings(delegate).count == 1)
        #expect(strings(delegate).first?.hasPrefix("\u{1b}[<64;") == true)
        delegate.writes = []
        gesture.testState = .ended
        view.handlePointerScroll(gesture)
        gesture.testState = .changed
        view.forwardPointerScroll(distance: -height * 2, gestureRecognizer: gesture)
        await drainCallbacks()
        #expect(strings(delegate).count == 2)
        #expect(strings(delegate).allSatisfy { $0.hasPrefix("\u{1b}[<65;") })
    }

    @Test func scrollHandlerConsumesEachVerticalDeltaOnce() async {
        let (view, delegate, gesture) = await fixture()
        gesture.setTranslation(CGPoint(x: 100, y: view.cellDimension.height), in: view)
        view.handlePointerScroll(gesture)
        #expect(gesture.translation(in: view) == .zero)
        view.handlePointerScroll(gesture)
        await drainCallbacks()
        #expect(delegate.writes.count == 1)
        #expect(strings(delegate).first?.hasPrefix("\u{1b}[<64;") == true)
        delegate.writes = []
        gesture.setTranslation(CGPoint(x: 100, y: 0), in: view)
        view.handlePointerScroll(gesture)
        await drainCallbacks()
        #expect(delegate.writes.isEmpty)
    }

    @Test func inactiveAndDisabledRoutesDoNotCapture() async {
        let (view, delegate, gesture) = await fixture("")
        #expect(!view.shouldCapturePointerScroll(gesture))
        view.forwardPointerScroll(distance: view.cellDimension.height * 2, gestureRecognizer: gesture)
        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        #expect(view.shouldCapturePointerScroll(gesture))
        view.allowMouseReporting = false
        #expect(!view.shouldCapturePointerScroll(gesture))
        view.forwardPointerScroll(distance: view.cellDimension.height * 2, gestureRecognizer: gesture)
        await drainCallbacks()
        #expect(delegate.writes.isEmpty)
    }

    @Test func shiftBypassAndHardwareModifiers() async {
        let (view, delegate, gesture) = await fixture()
        gesture.keys = [.shift, .alternate, .control]
        #expect(!view.shouldCapturePointerScroll(gesture))
        view.forwardPointerScroll(distance: view.cellDimension.height, gestureRecognizer: gesture)
        await drainCallbacks()
        #expect(delegate.writes.isEmpty)
        view.feed(text: "\u{1b}[>1s")
        #expect(view.shouldCapturePointerScroll(gesture))
        view.forwardPointerScroll(distance: view.cellDimension.height, gestureRecognizer: gesture)
        await drainCallbacks()
        #expect(strings(delegate).count == 1)
        #expect(strings(delegate).first?.hasPrefix("\u{1b}[<92;") == true)
    }

    @Test func reportedScrollDoesNotMoveScrollback() async {
        let (view, delegate, gesture) = await fixture()
        for index in 0..<40 { view.feed(text: "line \(index)\r\n") }
        await drainCallbacks()
        view.updateScroller()
        let offset = view.contentOffset
        let displayRow = view.withTerminal { $0.displayBuffer.yDisp }
        gesture.point = CGPoint(x: 10, y: CGFloat(displayRow) * view.cellDimension.height + view.cellDimension.height / 2)
        #expect(view.bounds.contains(gesture.point))
        view.forwardPointerScroll(distance: view.cellDimension.height * 2, gestureRecognizer: gesture)
        await drainCallbacks()
        #expect(delegate.writes.count == 2)
        #expect(view.contentOffset == offset)
        #expect(view.withTerminal { $0.displayBuffer.yDisp } == displayRow)
    }

    @Test func alternateScrollUsesCursorKeysAndCapturesWhen1007IsOff() async {
        let (view, delegate, gesture) = await fixture("\u{1b}[?1049h")
        #expect(view.shouldCapturePointerScroll(gesture))
        view.forwardPointerScroll(distance: view.cellDimension.height, gestureRecognizer: gesture)
        view.forwardPointerScroll(distance: -view.cellDimension.height, gestureRecognizer: gesture)
        await drainCallbacks()
        #expect(delegate.writes == [Array(EscapeSequences.moveUpNormal), Array(EscapeSequences.moveDownNormal)])
        delegate.writes = []
        view.feed(text: "\u{1b}[?1007l")
        #expect(view.shouldCapturePointerScroll(gesture))
        view.forwardPointerScroll(distance: view.cellDimension.height * 3, gestureRecognizer: gesture)
        await drainCallbacks()
        #expect(delegate.writes.isEmpty)
    }

    @Test(arguments: [false, true])
    func largeScrollHasABoundedBurst(alternateScreen: Bool) async {
        let (view, delegate, gesture) = await fixture(alternateScreen ? "\u{1b}[?1049h" : "\u{1b}[?1000h\u{1b}[?1006h")
        view.forwardPointerScroll(distance: view.cellDimension.height * 200, gestureRecognizer: gesture)
        await drainCallbacks()
        #expect(delegate.writes.count == WheelReportBudget.burst)
    }

    @Test func discreteWheelSendsOneReportPerDelta() async {
        let (view, delegate, gesture) = await fixture()
        gesture.allowedScrollTypesMask = .discrete
        view.forwardPointerScroll(distance: view.cellDimension.height * 0.1, gestureRecognizer: gesture)
        await drainCallbacks()
        #expect(delegate.writes.count == 1)
        #expect(strings(delegate).first?.hasPrefix("\u{1b}[<64;") == true)
        delegate.writes = []
        view.forwardPointerScroll(distance: -view.cellDimension.height * 200, gestureRecognizer: gesture)
        await drainCallbacks()
        #expect(delegate.writes.count == 1)
        #expect(strings(delegate).first?.hasPrefix("\u{1b}[<65;") == true)
    }

    @Test func localAndAccessibilityScrollDoNotSendWheelReports() async {
        let (view, delegate, _) = await fixture()
        for index in 0..<40 { view.feed(text: "line \(index)\r\n") }
        await drainCallbacks()
        view.setContentOffset(CGPoint(x: 0, y: view.cellDimension.height * 2), animated: false)
        await drainCallbacks()
        #expect(delegate.writes.isEmpty)
        #expect(view.accessibilityScroll(.down))
        await drainCallbacks()
        #expect(delegate.writes.isEmpty)
    }

    @Test func disabledRouteClearsFractionalTravel() async {
        let (view, delegate, gesture) = await fixture()
        let height = view.cellDimension.height
        view.forwardPointerScroll(distance: height * 0.75, gestureRecognizer: gesture)
        view.allowMouseReporting = false
        view.forwardPointerScroll(distance: height * 0.75, gestureRecognizer: gesture)
        view.allowMouseReporting = true
        view.forwardPointerScroll(distance: height * 0.5, gestureRecognizer: gesture)
        await drainCallbacks()
        #expect(delegate.writes.isEmpty)
        view.forwardPointerScroll(distance: height * 0.5, gestureRecognizer: gesture)
        await drainCallbacks()
        #expect(delegate.writes.count == 1)
    }

    @Test func endedGestureClearsFractionalTravel() async {
        let (view, delegate, gesture) = await fixture()
        view.forwardPointerScroll(distance: view.cellDimension.height * 0.75, gestureRecognizer: gesture)
        gesture.testState = .ended
        view.handlePointerScroll(gesture)
        view.forwardPointerScroll(distance: view.cellDimension.height * 0.5, gestureRecognizer: gesture)
        await drainCallbacks()
        #expect(delegate.writes.isEmpty)
    }

    @Test func hoverRequiresAnyEventTrackingAndPermission() async {
        let (view, delegate, _) = await fixture("\u{1b}[?1002h\u{1b}[?1006h")
        let point = CGPoint(x: 10, y: 10)
        view.forwardPointerHover(at: point, modifiers: [])
        await drainCallbacks()
        #expect(delegate.writes.isEmpty)
        view.feed(text: "\u{1b}[?1003h")
        view.forwardPointerHover(at: point, modifiers: [])
        await drainCallbacks()
        #expect(strings(delegate).first?.hasPrefix("\u{1b}[<35;") == true)
        delegate.writes = []
        view.allowMouseReporting = false
        view.forwardPointerHover(at: point, modifiers: [])
        await drainCallbacks()
        #expect(delegate.writes.isEmpty)
    }

    @Test func hoverKeepsControlLatchAndUsesHardwareModifiers() async {
        let (view, delegate, _) = await fixture("\u{1b}[?1003h\u{1b}[?1006h")
        view.controlModifier = true
        view.terminalAccessory?.controlModifier = true
        view.forwardPointerHover(at: CGPoint(x: 10, y: 10), modifiers: [.alternate, .control])
        await drainCallbacks()
        #expect(strings(delegate).first?.hasPrefix("\u{1b}[<59;") == true)
        #expect(view.controlModifier)
        #expect(view.terminalAccessory?.controlModifier == true)
        delegate.writes = []
        view.forwardPointerHover(at: CGPoint(x: 20, y: 10), modifiers: [.shift])
        await drainCallbacks()
        #expect(delegate.writes.isEmpty)
        view.feed(text: "\u{1b}[>1s")
        view.forwardPointerHover(at: CGPoint(x: 20, y: 10), modifiers: [.shift])
        await drainCallbacks()
        #expect(strings(delegate).first?.hasPrefix("\u{1b}[<39;") == true)
    }

    @Test func hoverOutsideBoundsDoesNotSend() async {
        let (view, delegate, _) = await fixture("\u{1b}[?1003h\u{1b}[?1006h")
        for point in [
            CGPoint(x: view.bounds.minX - 1, y: 10),
            CGPoint(x: 10, y: view.bounds.minY - 1),
            CGPoint(x: view.bounds.maxX + 1, y: 10),
            CGPoint(x: 10, y: view.bounds.maxY + 1)
        ] {
            view.forwardPointerHover(at: point, modifiers: [])
        }
        await drainCallbacks()
        #expect(delegate.writes.isEmpty)
    }

    @Test func hoverUsesDevicePixelsIn1016() async {
        let (view, delegate, _) = await fixture("\u{1b}[?1003h\u{1b}[?1016h")
        let point = CGPoint(x: 10.25, y: 12.75)
        let hit = view.calculateTapHit(point: point)
        view.forwardPointerHover(at: point, modifiers: [])
        await drainCallbacks()
        #expect(strings(delegate) == ["\u{1b}[<35;\(hit.pixels.col + 1);\(hit.pixels.row + 1)M"])
    }
}
#endif
