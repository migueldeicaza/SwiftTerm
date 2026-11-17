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
        var showsMatchCount = true
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

    @MainActor
    private func wait(_ condition: () -> Bool, within seconds: TimeInterval = 3) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }

    /// A view with three "needle" lines parsed. It has a find pasteboard of
    /// its own, so the tests neither read nor change the user's.
    @MainActor
    private func makeView() throws -> TerminalView {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 640, height: 320)))
        view.findPasteboard = NSPasteboard.withUniqueName()
        view.feed(text: "needle one\r\nNeedle two\r\nhay\r\nneedle three")
        // The view parses a feed on its I/O thread.
        try #require(wait { view.visibleRowsText(3..<4) == ["needle three"] })
        return view
    }

    @MainActor
    private func showFind(_ view: TerminalView) {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.performTextFinderAction(item)
    }

    @MainActor
    private func makeView(with bar: FakeFindBar) throws -> TerminalView {
        let view = try makeView()
        view.findBarProvider = { bar }
        showFind(view)
        return view
    }

    @MainActor
    @Test func theProvidedBarIsShownAndDrivesTheSearch() throws {
        let bar = FakeFindBar()
        let view = try makeView(with: bar)
        defer { view.findPasteboard.releaseGlobally() }
        #expect(bar.superview === view)
        #expect(!bar.isHidden)
        #expect(bar.focused == 1)
        #expect(bar.findBarDelegate === view)
        #expect(bar.statuses.isEmpty)

        // The match is selected at once; the count follows when typing pauses.
        bar.type("needle")
        #expect(bar.statuses == [.found])
        #expect(view.getSelection() == "needle")
        #expect(view.findPasteboard.string(forType: .string) == "needle")
        try #require(wait { bar.statuses.last == .matches(current: 1, total: 3, capped: false) })

        // Going to another match reports its position immediately.
        bar.findBarDelegate?.findBar(bar, findNext: true)
        #expect(bar.statuses.last == .matches(current: 2, total: 3, capped: false))
        bar.findBarDelegate?.findBar(bar, findNext: false)
        #expect(bar.statuses.last == .matches(current: 1, total: 3, capped: false))

        bar.options = SearchOptions(caseSensitive: true)
        bar.findBarDelegate?.findBarOptionsChanged(bar)
        #expect(bar.statuses.last == .matches(current: 2, total: 2, capped: false))

        bar.type("no-such-word")
        #expect(bar.statuses.last == .notFound)
        bar.type("")
        #expect(bar.statuses.last == TerminalFindStatus.none)

        bar.findBarDelegate?.findBarClose(bar)
        #expect(bar.isHidden)
    }

    /// Counting reads the whole scrollback, so a bar that shows no count
    /// costs none.
    @MainActor
    @Test func aBarThatShowsNoCountIsNotCountedFor() throws {
        let bar = FakeFindBar()
        bar.showsMatchCount = false
        let view = try makeView(with: bar)
        defer { view.findPasteboard.releaseGlobally() }
        bar.type("needle")
        bar.findBarDelegate?.findBar(bar, findNext: true)
        _ = wait({ false }, within: TerminalView.findCountDelay * 3)
        #expect(bar.statuses == [.found, .found])
    }

    /// Typing and stepping both read the bar's options, also when the bar
    /// never said they changed.
    @MainActor
    @Test func optionsTheBarStartsWithApplyToTyping() throws {
        let bar = FakeFindBar()
        bar.options = SearchOptions(caseSensitive: true)
        let view = try makeView(with: bar)
        defer { view.findPasteboard.releaseGlobally() }
        bar.type("needle")
        try #require(wait { bar.statuses.last == .matches(current: 1, total: 2, capped: false) })
        bar.findBarDelegate?.findBar(bar, findNext: true)
        #expect(bar.statuses.last == .matches(current: 2, total: 2, capped: false))
    }

    @MainActor
    @Test func anInvalidPatternIsReportedAsAMessage() throws {
        let bar = FakeFindBar()
        bar.options = SearchOptions(regex: true)
        let view = try makeView(with: bar)
        defer { view.findPasteboard.releaseGlobally() }
        bar.type("needle (")
        #expect(bar.statuses.last == .message("Invalid regular expression"))
        bar.type("needle (one|three)")
        try #require(wait { bar.statuses.last == .matches(current: 1, total: 2, capped: false) })
    }

    @MainActor
    @Test func newOutputUpdatesTheCount() throws {
        let bar = FakeFindBar()
        let view = try makeView(with: bar)
        defer { view.findPasteboard.releaseGlobally() }
        bar.type("needle")
        try #require(wait { bar.statuses.last == .matches(current: 1, total: 3, capped: false) })
        view.feed(text: "\r\nneedle four")
        try #require(wait { bar.statuses.last == .matches(current: 1, total: 4, capped: false) })
    }

    /// A new provider replaces a showing bar: the old view goes back to the
    /// application as it came, and no longer drives the search.
    @MainActor
    @Test func changingTheProviderReplacesAShowingBar() throws {
        let old = FakeFindBar()
        old.options = SearchOptions(caseSensitive: true)
        let view = try makeView(with: old)
        defer { view.findPasteboard.releaseGlobally() }
        #expect(!old.translatesAutoresizingMaskIntoConstraints)
        old.type("needle")
        try #require(wait { old.statuses.last == .matches(current: 1, total: 2, capped: false) })

        let new = FakeFindBar()
        view.findBarProvider = { new }
        #expect(old.superview == nil)
        #expect(old.findBarDelegate == nil)
        #expect(old.translatesAutoresizingMaskIntoConstraints)
        #expect(!old.isHidden)
        #expect(new.superview === view)
        #expect(!new.isHidden)
        #expect(new.searchText == "needle")
        // The focus was not in the old bar, so nothing takes it.
        #expect(new.focused == 0)
        // The search starts over with the new bar's options.
        try #require(wait { new.statuses.last == .matches(current: 1, total: 3, capped: false) })

        let seen = old.statuses
        view.findBar(old, findNext: true)
        view.findBarClose(old)
        #expect(old.statuses == seen)
        #expect(!new.isHidden)
        #expect(new.statuses.last == .matches(current: 1, total: 3, capped: false))
    }

    @MainActor
    @Test func aHiddenBarIsDiscardedWithoutAReplacement() throws {
        let bar = FakeFindBar()
        let view = try makeView(with: bar)
        defer { view.findPasteboard.releaseGlobally() }
        bar.findBarDelegate?.findBarClose(bar)
        view.findBarProvider = nil
        #expect(bar.superview == nil)
        #expect(!view.subviews.contains { $0 is TerminalFindBarView })
        showFind(view)
        #expect(view.subviews.contains { $0 is TerminalFindBarView })
    }

    /// A bar that only has a frame keeps that size; one wider than the view
    /// keeps its width.
    @MainActor
    @Test func aFrameSizedBarKeepsItsSize() throws {
        let bar = FakeFindBar(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        let view = try makeView(with: bar)
        defer { view.findPasteboard.releaseGlobally() }
        // In a window the view's width is fixed; without one, say so.
        view.widthAnchor.constraint(equalToConstant: view.frame.width).isActive = true
        view.layoutSubtreeIfNeeded()
        #expect(bar.frame.size == NSSize(width: 300, height: 30))
        #expect(bar.frame.maxX == view.bounds.maxX - 8)

        let wide = FakeFindBar()
        wide.translatesAutoresizingMaskIntoConstraints = false
        wide.widthAnchor.constraint(equalToConstant: 900).isActive = true
        wide.heightAnchor.constraint(equalToConstant: 30).isActive = true
        view.findBarProvider = { wide }
        view.layoutSubtreeIfNeeded()
        #expect(wide.frame.width == 900)
        #expect(wide.frame.maxX == view.bounds.maxX - 8)
    }
}
#endif
