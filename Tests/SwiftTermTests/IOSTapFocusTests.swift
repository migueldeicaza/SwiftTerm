#if os(iOS)
import UIKit
import Testing

@testable import SwiftTerm

/// A tap that only focuses the terminal must not wait for the double-tap timeout,
/// while taps that select text or reach the application still wait.
@Suite(.serialized)
@MainActor
struct IOSTapFocusTests {
    private struct Taps {
        let single: UITapGestureRecognizer
        let double: UITapGestureRecognizer
        let triple: UITapGestureRecognizer
    }

    private func taps(_ view: TerminalView) throws -> Taps {
        let all = (view.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
            .filter { $0.numberOfTouchesRequired == 1 }
        func one(_ count: Int) throws -> UITapGestureRecognizer {
            let matches = all.filter { $0.numberOfTapsRequired == count }
            #expect(matches.count == 1)
            return try #require(matches.first)
        }
        return Taps(single: try one(1), double: try one(2), triple: try one(3))
    }

    /// Stands in for the touch UIKit passes to the delegate: a real recognizer's location
    /// and modifier flags cannot be set outside a touch sequence.
    private final class TapAt: UITapGestureRecognizer {
        var point = CGPoint.zero
        var keys: UIKeyModifierFlags = []
        override func location(in view: UIView?) -> CGPoint { point }
        override var modifierFlags: UIKeyModifierFlags { keys }
    }

    /// What UIKit asks before it lets a single tap end: must the double tap fail first?
    private func waitsForDoubleTap(_ taps: Taps) -> Bool? {
        taps.single.delegate?.gestureRecognizer?(taps.single, shouldRequireFailureOf: taps.double)
    }

    @Test func unfocusedTapFocusesWithoutWaitingForDoubleTap() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        #expect(!view.isFirstResponder)
        #expect(waitsForDoubleTap(try taps(view)) == false)
    }

    @Test func unfocusedTapForwardedToApplicationStillWaits() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        view.feed(text: "\u{1b}[?1000h")
        #expect(waitsForDoubleTap(try taps(view)) == true)
    }

    @Test func unfocusedTapInMouseReportingApplicationWaitsWithSelectionOrShift() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        view.feed(text: "\u{1b}[?1000h")
        let taps = try taps(view)
        // Shift bypasses mouse reporting for the click, yet the tap must still wait so that
        // an unfocused double tap reaches doubleTap(_:) before the view is first responder.
        let shifted = TapAt()
        shifted.keys = .shift
        #expect(taps.single.delegate?.gestureRecognizer?(shifted, shouldRequireFailureOf: taps.double) == true)
        view.selectAll(nil)
        #expect(waitsForDoubleTap(taps) == true)
    }

    @Test func unfocusedTapOnLinkStillWaits() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        // With .always a touch opens an OSC 8 link; the default .hover needs a pointer.
        view.linkHighlightMode = .always
        view.feed(text: "\u{1b}]8;;https://example.com/\u{1b}\\link\u{1b}]8;;\u{1b}\\")
        let taps = try taps(view)
        let cell = view.cellDimension
        let tap = TapAt()
        tap.point = CGPoint(x: cell.width * 1.5, y: cell.height * 0.5)
        #expect(taps.single.delegate?.gestureRecognizer?(tap, shouldRequireFailureOf: taps.double) == true)
        tap.point = CGPoint(x: cell.width * 1.5, y: cell.height * 2.5)
        #expect(taps.single.delegate?.gestureRecognizer?(tap, shouldRequireFailureOf: taps.double) == false)
    }

    @Test func focusedTapStillWaits() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let view = TerminalView(frame: window.bounds)
        window.addSubview(view)
        window.isHidden = false
        try #require(view.becomeFirstResponder())
        defer { _ = view.resignFirstResponder() }
        #expect(waitsForDoubleTap(try taps(view)) == true)
    }
}
#endif
