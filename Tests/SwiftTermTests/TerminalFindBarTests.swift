#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

@Suite("TerminalView find bar")
struct TerminalFindBarTests {
    final class FakeFindBar: NSView, TerminalFindBar {
        weak var findBarDelegate: TerminalFindBarDelegate?
        var searchText = ""
        var options = SearchOptions()
        var statuses: [TerminalFindStatus] = []
        var focused = 0

        func focusSearchField() {
            focused += 1
        }

        func setFindStatus(_ status: TerminalFindStatus) {
            statuses.append(status)
        }

        func type(_ text: String) {
            searchText = text
            findBarDelegate?.findBarSearchTextChanged(self)
        }
    }

    /// A view with three "needle" lines parsed, and the find bar it made.
    @MainActor
    private func makeView() -> (TerminalView, FakeFindBar) {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 640, height: 320)))
        let bar = FakeFindBar()
        view.findBarProvider = { bar }
        view.feed(text: "needle one\r\nNeedle two\r\nhay\r\nneedle three")
        // The view parses a feed on its I/O thread.
        let deadline = Date(timeIntervalSinceNow: 2)
        while view.visibleRowsText(3..<4) != ["needle three"], Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.performTextFinderAction(item)
        return (view, bar)
    }

    @MainActor
    @Test func theProvidedBarIsShownAndDrivesTheSearch() {
        let (view, bar) = makeView()
        #expect(bar.superview === view)
        #expect(!bar.isHidden)
        #expect(bar.focused == 1)
        #expect(bar.findBarDelegate === view)

        bar.type("needle")
        #expect(bar.statuses.last == .matches(current: 1, total: 3, capped: false))
        #expect(view.getSelection() == "needle")

        bar.findBarDelegate?.findBar(bar, findNext: true)
        #expect(bar.statuses.last == .matches(current: 2, total: 3, capped: false))
        bar.findBarDelegate?.findBar(bar, findNext: false)
        #expect(bar.statuses.last == .matches(current: 1, total: 3, capped: false))

        bar.options = SearchOptions(caseSensitive: true)
        bar.findBarDelegate?.findBarOptionsChanged(bar)
        guard case .matches(_, let total, _)? = bar.statuses.last else {
            Issue.record("expected matches, got \(String(describing: bar.statuses.last))")
            return
        }
        #expect(total == 2)

        bar.type("no-such-word")
        #expect(bar.statuses.last == .notFound)
        bar.type("")
        #expect(bar.statuses.last == TerminalFindStatus.none)

        bar.findBarDelegate?.findBarClose(bar)
        #expect(bar.isHidden)
    }

    @MainActor
    @Test func changingTheProviderDiscardsTheBar() {
        let (view, bar) = makeView()
        view.findBarProvider = nil
        #expect(bar.superview == nil)
        #expect(bar.findBarDelegate == nil)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.performTextFinderAction(item)
        #expect(view.subviews.contains { $0 is TerminalFindBarView })
    }
}
#endif
