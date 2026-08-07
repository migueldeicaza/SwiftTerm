//
//  SearchService.swift
//  SwiftTerm
//
//  Ported and adapted from the xterm.js search addon infrastructure.
//

import Foundation

final class SearchService {
    private enum Constants {
        static let defaultHighlightLimit = 1000
    }

    private let terminal: Terminal
    private let state = SearchState()
    private let lineCache: SearchLineCache
    private let engine: SearchEngine
    private var lastSelection: SearchSelection?

    private(set) var lastResult: SearchResult?

    init (terminal: Terminal) {
        self.terminal = terminal
        let cache = SearchLineCache(terminal: terminal)
        self.lineCache = cache
        self.engine = SearchEngine(terminal: terminal, lineCache: cache)
    }

    /**
     * Invalidates the current search snapshot due to content or size changes.
     * The cache should be invalidated when either the content of the buffer or the buffer dimensions change
     * because the snapshot has direct mappings to buffer line and locations.
    */
    func invalidate () {
        lineCache.invalidate()
        lastResult = nil
        lastSelection = nil
    }

    func reset () {
        lineCache.invalidate()
        state.reset()
        lastResult = nil
        lastSelection = nil
    }

    func updateLastSelection (_ selection: SearchSelection?) {
        lastSelection = selection
    }

    @discardableResult
    func findNext (term: String, options: SearchOptions = SearchOptions()) -> SearchResult? {
        guard state.isValidSearchTerm(term) else {
            lastResult = nil
            lastSelection = nil
            state.reset()
            return nil
        }

        state.lastSearchOptions = options
        let result = engine.findNextWithSelection(term: term, searchOptions: options, cachedSearchTerm: state.cachedSearchTerm, previousSelection: lastSelection)
        state.cachedSearchTerm = term

        lastResult = result
        lastSelection = result.map { selection(for: $0) }
        return result
    }

    @discardableResult
    func findPrevious (term: String, options: SearchOptions = SearchOptions()) -> SearchResult? {
        guard state.isValidSearchTerm(term) else {
            lastResult = nil
            lastSelection = nil
            state.reset()
            return nil
        }

        state.lastSearchOptions = options
        let result = engine.findPreviousWithSelection(term: term, searchOptions: options, cachedSearchTerm: state.cachedSearchTerm, previousSelection: lastSelection)
        state.cachedSearchTerm = term

        lastResult = result
        lastSelection = result.map { selection(for: $0) }
        return result
    }

    func findAll (term: String, options: SearchOptions = SearchOptions(), limit: Int = Constants.defaultHighlightLimit) -> [SearchResult] {
        guard state.isValidSearchTerm(term) else {
            return []
        }

        lineCache.initLinesCache()

        var results: [SearchResult] = []
        var prevResult: SearchResult?
        var result = engine.find(term: term, startRow: 0, startCol: 0, searchOptions: options)

        while let match = result {
            if results.count >= limit {
                break
            }
            if let prevResult, prevResult.row == match.row && prevResult.col == match.col {
                break
            }
            results.append(match)
            prevResult = match

            let nextPosition = advancePosition(from: Position(col: match.col, row: match.row), by: max(match.size, 1))
            result = engine.find(term: term, startRow: nextPosition.row, startCol: nextPosition.col, searchOptions: options)
        }

        return results
    }

    func selectionRange (for result: SearchResult) -> (start: Position, end: Position) {
        let start = Position(col: result.col, row: result.row)
        let end = advancePosition(from: start, by: max(result.size, 0))
        return (start, end)
    }

    private func selection (for result: SearchResult) -> SearchSelection {
        let range = selectionRange(for: result)
        return SearchSelection(start: range.start, end: range.end)
    }

    private func advancePosition (from position: Position, by cells: Int) -> Position {
        guard cells > 0 else {
            return position
        }
        let cols = max(terminal.cols, 1)
        let linearStart = position.row * cols + position.col
        let linearEnd = linearStart + cells
        let newRow = linearEnd / cols
        let newCol = linearEnd % cols
        return Position(col: newCol, row: newRow)
    }
}
