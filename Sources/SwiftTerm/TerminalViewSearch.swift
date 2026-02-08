//
//  TerminalViewSearch.swift
//  SwiftTerm
//
//  Search integration for TerminalView.
//

#if os(macOS) || os(iOS) || os(visionOS)
import Foundation

extension TerminalView {
    /// Finds the next match for `term`, selects it, and optionally scrolls it into view.
    /// - Parameters:
    ///   - term: The search term.
    ///   - options: Search options (case sensitivity, regex, whole word).
    ///   - scrollToResult: Whether to scroll the result into view.
    /// - Returns: `true` if a match was found.
    @discardableResult
    public func findNext (_ term: String, options: SearchOptions = SearchOptions(), scrollToResult: Bool = true) -> Bool {
        guard let search = search, let selection = selection else {
            return false
        }

        search.updateLastSelection(currentSearchSelection(selection))
        if let result = search.findNext(term: term, options: options) {
            return applySearchResult(result, selection: selection, scrollToResult: scrollToResult)
        }

        selection.selectNone()
        return false
    }

    /// Finds the previous match for `term`, selects it, and optionally scrolls it into view.
    /// - Parameters:
    ///   - term: The search term.
    ///   - options: Search options (case sensitivity, regex, whole word).
    ///   - scrollToResult: Whether to scroll the result into view.
    /// - Returns: `true` if a match was found.
    @discardableResult
    public func findPrevious (_ term: String, options: SearchOptions = SearchOptions(), scrollToResult: Bool = true) -> Bool {
        guard let search = search, let selection = selection else {
            return false
        }

        search.updateLastSelection(currentSearchSelection(selection))
        if let result = search.findPrevious(term: term, options: options) {
            return applySearchResult(result, selection: selection, scrollToResult: scrollToResult)
        }

        selection.selectNone()
        return false
    }

    /// Clears the current search state and selection.
    public func clearSearch () {
        search?.reset()
        selection?.selectNone()
    }

    private func applySearchResult (_ result: SearchResult, selection: SelectionService, scrollToResult: Bool) -> Bool {
        let range = search?.selectionRange(for: result) ?? (start: Position(col: result.col, row: result.row),
                                                           end: Position(col: result.col, row: result.row))
        selection.setSelection(start: range.start, end: range.end)
        if scrollToResult {
            scrollToReveal(row: result.row)
        }
        return true
    }

    private func currentSearchSelection (_ selection: SelectionService) -> SearchSelection? {
        guard selection.active else {
            return nil
        }
        let start = selection.start
        let end = selection.end
        switch Position.compare(start, end) {
        case .before, .equal:
            return SearchSelection(start: start, end: end)
        case .after:
            return SearchSelection(start: end, end: start)
        }
    }

    private func scrollToReveal (row: Int) {
        let displayBuffer = terminal.displayBuffer
        let rows = displayBuffer.rows
        guard rows > 0 else {
            return
        }
        if terminal.isDisplayBufferAlternate {
            return
        }

        let upperVisible = displayBuffer.yDisp
        let lowerVisible = displayBuffer.yDisp + rows - 1
        if row >= upperVisible && row <= lowerVisible {
            return
        }

        let maxScrollback = max(0, displayBuffer.lines.count - rows)
        var target = row - rows / 2
        if target < 0 {
            target = 0
        }
        if target > maxScrollback {
            target = maxScrollback
        }
        scrollTo(row: target)
    }
}
#endif
