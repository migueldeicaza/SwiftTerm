#if os(iOS)
import UIKit
import Testing

@testable import SwiftTerm

@Suite(.serialized)
@MainActor
struct IOSLinkTapTests {
    private func makeView(_ text: String) -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 160))
        view.feed(text: text)
        return view
    }

    /// The center of a cell on the first row, in the view's coordinates.
    private func point(_ view: TerminalView, col: Int) -> CGPoint {
        CGPoint(x: (CGFloat(col) + 0.5) * view.cellDimension.width,
                y: 0.5 * view.cellDimension.height)
    }

    private let detected = "go https://example.com/a?r=https%3A%2F%2Fx#f ok"

    @Test func linkRequestFindsADetectedLinkWithoutHover() {
        let view = makeView(detected)
        #expect(view.linkHighlightMode == .hover)
        let request = view.linkRequest(at: point(view, col: 10))
        #expect(request?.link == "https://example.com/a?r=https%3A%2F%2Fx#f")
        #expect(request?.isExplicit == false)
        #expect(view.linkRequest(at: point(view, col: 0)) == nil)
    }

    @Test func linkRequestFindsAnOsc8Link() {
        let view = makeView("\u{1b}]8;id=a;https://osc.example/\u{1b}\\label\u{1b}]8;;\u{1b}\\")
        let request = view.linkRequest(at: point(view, col: 2))
        #expect(request?.link == "https://osc.example/")
        #expect(request?.params == ["id": "a"])
        #expect(request?.isExplicit == true)
    }

    @Test func aTouchTapActivatesADetectedLink() {
        let view = makeView(detected)
        let request = view.linkRequestForTap(at: point(view, col: 10), touchType: .direct)
        #expect(request?.link == "https://example.com/a?r=https%3A%2F%2Fx#f")
    }

    @Test func aPointerClickWithoutHoverDoesNotActivateALink() {
        let view = makeView(detected)
        #expect(view.linkRequestForTap(at: point(view, col: 10), touchType: .indirectPointer) == nil)
    }

    @Test func aTouchTapDoesNotActivateALinkWhenTheHostTurnsItOff() {
        let view = makeView(detected)
        view.touchLinkActivation = .none
        #expect(view.linkRequestForTap(at: point(view, col: 10), touchType: .direct) == nil)
        // The host can still find the link for its own menu.
        #expect(view.linkRequest(at: point(view, col: 10)) != nil)
    }
}
#endif
