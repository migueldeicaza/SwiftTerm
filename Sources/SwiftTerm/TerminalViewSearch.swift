//
//  TerminalViewSearch.swift
//  SwiftTerm
//
//  Search integration for TerminalView.
//

#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation

extension TerminalView {
    /// Search and selection state are guarded by `terminal.terminalLock`;
    /// public entry points acquire it before touching that state.
    /// Finds the next match for `term`, selects it, and optionally scrolls it into view.
    /// With ``highlightAllSearchMatches`` on, every other match is highlighted too.
    /// - Parameters:
    ///   - term: The search term.
    ///   - options: Search options (case sensitivity, regex, whole word).
    ///   - scrollToResult: Whether to scroll the result into view.
    /// - Returns: `true` if a match was found.
    @discardableResult
    public func findNext (_ term: String, options: SearchOptions = SearchOptions(), scrollToResult: Bool = true) -> Bool {
        let resultRow: Int? = withTerminal { _ in
            guard let search = search, let selection = selection else {
                return nil
            }

            search.updateLastSelection(currentSearchSelection(selection))
            if let result = search.findNext(term: term, options: options) {
                return applySearchResultLocked(result, selection: selection)
            }

            selection.selectNone()
            return nil
        }
        updateSearchHighlights(term: term, options: options)
        if let resultRow {
            if scrollToResult {
                scrollToReveal(row: resultRow)
            }
            return true
        }
        return false
    }

    /// Finds the previous match for `term`, selects it, and optionally scrolls it into view.
    /// With ``highlightAllSearchMatches`` on, every other match is highlighted too.
    /// - Parameters:
    ///   - term: The search term.
    ///   - options: Search options (case sensitivity, regex, whole word).
    ///   - scrollToResult: Whether to scroll the result into view.
    /// - Returns: `true` if a match was found.
    @discardableResult
    public func findPrevious (_ term: String, options: SearchOptions = SearchOptions(), scrollToResult: Bool = true) -> Bool {
        let resultRow: Int? = withTerminal { _ in
            guard let search = search, let selection = selection else {
                return nil
            }

            search.updateLastSelection(currentSearchSelection(selection))
            if let result = search.findPrevious(term: term, options: options) {
                return applySearchResultLocked(result, selection: selection)
            }

            selection.selectNone()
            return nil
        }
        updateSearchHighlights(term: term, options: options)
        if let resultRow {
            if scrollToResult {
                scrollToReveal(row: resultRow)
            }
            return true
        }
        return false
    }


    /// Position of the current match among all matches for `term`: a 1-based
    /// `index` (0 when there is no current match) and the `total` match count
    /// (capped at `limit`). Drives a "2/14" style counter in a search UI.
    /// With ``highlightAllSearchMatches`` on, the highlights follow the same
    /// list, so a host that recounts after new output re-highlights with it.
    public func searchMatchSummary (_ term: String, options: SearchOptions = SearchOptions(), limit: Int = 1000) -> (index: Int, total: Int) {
        let summary: (index: Int, total: Int) = withTerminal { _ in
            guard let search = search else {
                return (0, 0)
            }
            let all = search.findAll(term: term, options: options, limit: limit)
            guard let last = search.lastResult,
                  let i = all.firstIndex(where: { $0.row == last.row && $0.col == last.col }) else {
                return (0, all.count)
            }
            return (i + 1, all.count)
        }
        updateSearchHighlights(term: term, options: options, limit: limit)
        return summary
    }

    /// Every match for `term`, top to bottom, capped at `limit` — the same
    /// list ``searchMatchSummary(_:options:limit:)`` counts — with the number
    /// of lines the buffer holds, scrollback included. A host draws one mark
    /// per match beside the scrollbar from it: a match's `row` out of `lines`
    /// is its place in the scrollback (0 the oldest line).
    public func searchMatchPositions (_ term: String, options: SearchOptions = SearchOptions(), limit: Int = 1000) -> (matches: [SearchMatchPosition], lines: Int) {
        withTerminal { terminal in
            let matches = search?.findAll(term: term, options: options, limit: limit).map(SearchMatchPosition.init) ?? []
            return (matches, terminal.displayBuffer.lines.count)
        }
    }

    /// Clears the current search state, selection and match highlights.
    public func clearSearch () {
        withTerminal { _ in
            search?.reset()
            selection?.selectNone()
        }
        setSearchHighlights(.none)
    }

    /// Recomputes the highlights for the last search after
    /// ``highlightAllSearchMatches`` changes: on, the matches of the term the
    /// last `findNext`/`findPrevious` used; off, none.
    func refreshSearchHighlights () {
        let last: (term: String, options: SearchOptions)? = withTerminal { _ in
            guard let search, let term = search.currentTerm else {
                return nil
            }
            return (term, search.currentOptions ?? SearchOptions())
        }
        guard let last else {
            setSearchHighlights(.none)
            return
        }
        updateSearchHighlights(term: last.term, options: last.options)
    }

    private func updateSearchHighlights (term: String, options: SearchOptions, limit: Int = 1000) {
        guard highlightAllSearchMatches else {
            setSearchHighlights(.none)
            return
        }
        let highlights: SearchHighlights = withTerminal { terminal in
            guard let search else {
                return .none
            }
            return SearchHighlights(results: search.findAll(term: term, options: options, limit: limit),
                                    cols: terminal.cols)
        }
        setSearchHighlights(highlights)
    }

    private func setSearchHighlights (_ highlights: SearchHighlights) {
        guard highlights != searchHighlights else {
            return
        }
        searchHighlights = highlights
        invalidateTerminalContents()
    }

    private func applySearchResultLocked (_ result: SearchResult, selection: SelectionService) -> Int {
        terminal.terminalLock.preconditionLocked()
        let range = search?.selectionRange(for: result) ?? (start: Position(col: result.col, row: result.row),
                                                           end: Position(col: result.col, row: result.row))
        selection.setSelection(start: range.start, end: range.end)
        return result.row
    }

    private func currentSearchSelection (_ selection: SelectionService) -> SearchSelection? {
        terminal.terminalLock.preconditionLocked()
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
        let target: Int? = withTerminal { terminal in
            let displayBuffer = terminal.displayBuffer
            let rows = displayBuffer.rows
            guard rows > 0 else {
                return nil
            }
            if terminal.isDisplayBufferAlternate {
                return nil
            }

            let upperVisible = displayBuffer.yDisp
            let lowerVisible = displayBuffer.yDisp + rows - 1
            if row >= upperVisible && row <= lowerVisible {
                return nil
            }

            let maxScrollback = max(0, displayBuffer.lines.count - rows)
            var target = row - rows / 2
            if target < 0 {
                target = 0
            }
            if target > maxScrollback {
                target = maxScrollback
            }
            return target
        }
        if let target {
            scrollTo(row: target)
        }
    }
}
#endif

#endif // !SWIFTTERM_EMBEDDED
