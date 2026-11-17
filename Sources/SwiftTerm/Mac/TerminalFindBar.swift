//
//  TerminalFindBar.swift
//  SwiftTerm
//
//  The contract between TerminalView and its find bar, so that an
//  application can replace the built-in bar with one of its own.
//

#if !SWIFTTERM_EMBEDDED
#if os(macOS)
import AppKit

/// What the find bar should tell the user about the current search.
public enum TerminalFindStatus: Equatable {
    /// There is no search: the query is empty.
    case none
    /// A match is selected and its position is not known: the bar does not
    /// ask for a count (``TerminalFindBar/showsMatchCount``), or the count
    /// follows shortly in a ``matches(current:total:capped:)``.
    case found
    /// The query matches. `current` is the 1-based position of the selected
    /// match and `total` the number of matches. When `capped` is true the
    /// count stopped at `total` and there are more. `current` is 0 when the
    /// selected match is one of those, and when no match is selected: after
    /// the view was resized, or when output brought the first matches of a
    /// query that had none. Show the total alone then.
    case matches(current: Int, total: Int, capped: Bool)
    /// The query does not match anything.
    case notFound
    /// A message for the user, for example an invalid regular expression.
    case message(String)
}

/// A view that collects a search query and its options for a ``TerminalView``.
///
/// Set ``TerminalView/findBarProvider`` to have the terminal use your own
/// view instead of the built-in find bar. The terminal adds the view as a
/// subview, pins it to its top trailing corner and becomes its
/// ``findBarDelegate``; the view decides its own size and appearance and
/// reports what the user does to the delegate.
///
/// The terminal positions the view with Auto Layout, and for that turns off
/// its `translatesAutoresizingMaskIntoConstraints` while it shows it. Give
/// the view its size with constraints or an intrinsic content size; a view
/// that only has a frame keeps that frame's size.
@MainActor
public protocol TerminalFindBar: NSView {
    /// The terminal sets this; hold it weakly.
    var findBarDelegate: TerminalFindBarDelegate? { get set }
    /// The query. The terminal sets it when the bar is shown, to the selected
    /// text or the contents of the find pasteboard. Setting it must not call
    /// the delegate.
    var searchText: String { get set }
    /// The options the user chose.
    var options: SearchOptions { get }
    /// Moves the keyboard focus to the field that holds the query.
    func focusSearchField()
    /// Whether the bar shows how many matches there are. Counting reads the
    /// whole scrollback, so the terminal only does it for a bar that asks.
    /// The default is `false`.
    var showsMatchCount: Bool { get }
    /// Called with the outcome of a search. While the user types, the count
    /// arrives a moment after the match is selected, and it is sent again
    /// when new output changes it. The default does nothing.
    func setFindStatus(_ status: TerminalFindStatus)
}

extension TerminalFindBar {
    public var showsMatchCount: Bool {
        false
    }

    public func setFindStatus(_ status: TerminalFindStatus) {
    }
}

/// What a ``TerminalFindBar`` reports to the terminal that shows it.
@MainActor
public protocol TerminalFindBarDelegate: AnyObject {
    /// The user edited the query.
    func findBarSearchTextChanged(_ bar: TerminalFindBar)
    /// The user changed one of the options.
    func findBarOptionsChanged(_ bar: TerminalFindBar)
    /// The user asked for the next match (`forward`) or the previous one.
    func findBar(_ bar: TerminalFindBar, findNext forward: Bool)
    /// The user dismissed the bar.
    func findBarClose(_ bar: TerminalFindBar)
}
#endif

#endif // !SWIFTTERM_EMBEDDED
