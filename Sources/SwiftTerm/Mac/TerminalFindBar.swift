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
    /// The query matches. `current` is the 1-based position of the selected
    /// match (0 if it is not known) and `total` the number of matches. When
    /// `capped` is true the count stopped at `total` and there may be more.
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
    /// Called after every search with its outcome. The default does nothing.
    func setFindStatus(_ status: TerminalFindStatus)
}

extension TerminalFindBar {
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
