#if os(iOS)
import UIKit
import Testing

@testable import SwiftTerm

@Suite(.serialized)
@MainActor
struct IOSProgramScrollGestureTests {
    private func drainCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func mouseTrackingView() async -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        view.feed(text: "\u{1b}[?1000h")
        await drainCallbacks()
        return view
    }

    @Test func mouseTrackingCapturesOneFingerDragsByDefault() async {
        let view = await mouseTrackingView()

        #expect(view.panMouseGesture != nil)
        #expect(view.panGestureRecognizer.minimumNumberOfTouches == 2)
    }

    @Test func hostCanKeepOneFingerDragsForItself() async {
        let view = await mouseTrackingView()

        view.allowProgramScrollGesture = false
        #expect(view.panMouseGesture == nil)
        #expect(view.panGestureRecognizer.minimumNumberOfTouches == 1)

        view.feed(text: "\u{1b}[?1049h")
        await drainCallbacks()
        #expect(view.panMouseGesture == nil)

        view.allowProgramScrollGesture = true
        #expect(view.panMouseGesture != nil)
        #expect(view.panGestureRecognizer.minimumNumberOfTouches == 2)
    }

    @Test func turningTheGestureOffLeavesMouseReportingOn() async {
        let view = await mouseTrackingView()

        view.allowProgramScrollGesture = false
        #expect(view.allowMouseReporting)
        #expect(view.terminalInputStateSnapshot()?.mouseMode != .off)
    }
}
#endif
