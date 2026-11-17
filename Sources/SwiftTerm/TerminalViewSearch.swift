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
        if let resultRow {
            if scrollToResult {
                scrollToReveal(row: resultRow)
            }
            return true
        }
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
        if let resultRow {
            if scrollToResult {
                scrollToReveal(row: resultRow)
            }
            return true
        }
        return false
    }


    /// Position of the current match among all matches for `term`: a 1-based
    /// `index` (0 when there is no current match, or it is past `limit`) and
    /// the `total` match count (capped at `limit`). Drives a "2/14" style
    /// counter in a search UI.
    public func searchMatchSummary (_ term: String, options: SearchOptions = SearchOptions(), limit: Int = 1000) -> (index: Int, total: Int) {
        let summary = searchMatchCount(term, options: options, limit: limit)
        return (summary.index, summary.total)
    }

    /// What a search UI needs for its counter, read under one hold of the lock.
    struct SearchMatchCount: Equatable {
        /// 1-based position of the selected match; 0 if it is not among the counted ones.
        var index: Int
        /// The number of matches, at most the limit.
        var total: Int
        /// There are more matches than the limit.
        var capped: Bool
        /// ``SearchService/generation`` when the count was taken.
        var generation: Int
    }

    /// Counts the matches for `term` and locates the selected one among them.
    func searchMatchCount (_ term: String, options: SearchOptions, limit: Int) -> SearchMatchCount {
        withTerminal { _ in
            searchMatchCountLocked(term, options: options, limit: limit)
        }
    }

    private func searchMatchCountLocked (_ term: String, options: SearchOptions, limit: Int) -> SearchMatchCount {
        terminal.terminalLock.preconditionLocked()
        guard let search else {
            return SearchMatchCount(index: 0, total: 0, capped: false, generation: 0)
        }
        // Output invalidates the last result but leaves the match selected.
        var current = search.lastResult.map { Position(col: $0.col, row: $0.row) }
        if current == nil, let selection {
            current = currentSearchSelection(selection)?.start
        }
        let summary = search.matchSummary(term: term, options: options, limit: limit, current: current)
        return SearchMatchCount(index: summary.index, total: summary.total, capped: summary.capped,
                                generation: search.generation)
    }

    /// Finds the next (or previous) match and, when `countLimit` is given,
    /// counts the matches under the same hold of the lock, so that output
    /// arriving in between cannot make the count disagree with the selection.
    func find (_ term: String, options: SearchOptions, forward: Bool, countLimit: Int?) -> (found: Bool, count: SearchMatchCount?) {
        let outcome: (row: Int?, count: SearchMatchCount?) = withTerminal { _ in
            guard let search = search, let selection = selection else {
                return (nil, nil)
            }
            search.updateLastSelection(currentSearchSelection(selection))
            let result = forward ? search.findNext(term: term, options: options)
                : search.findPrevious(term: term, options: options)
            guard let result else {
                selection.selectNone()
                return (nil, nil)
            }
            let row = applySearchResultLocked(result, selection: selection)
            return (row, countLimit.map { searchMatchCountLocked(term, options: options, limit: $0) })
        }
        if let row = outcome.row {
            scrollToReveal(row: row)
        }
        return (outcome.row != nil, outcome.count)
    }

    /// The search generation: it changes when the content may have changed.
    func searchGeneration () -> Int {
        withTerminal { _ in
            search?.generation ?? 0
        }
    }

    /// Clears the current search state and selection.
    public func clearSearch () {
        withTerminal { _ in
            search?.reset()
            selection?.selectNone()
        }
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
