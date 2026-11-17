//
//  SearchService.swift
//  SwiftTerm
//
//  Ported and adapted from the xterm.js search addon infrastructure.
//

#if !SWIFTTERM_EMBEDDED
import Foundation

/// Who made a "highlight all matches" pattern active.
enum SearchHighlightOwner {
    /// The host application, through the public find functions.
    case host
    /// The view's built-in find bar.
    case findBar
}

/// Search state is guarded by `terminal.terminalLock`; callers must hold it.
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
    /// Goes up whenever the buffer's content or size may have changed, so a
    /// caller can tell that a count it took earlier is out of date. The
    /// frame path compares it when a visible match can depend on rows that
    /// are not visible.
    private(set) var generation = 0
    /// The matches of the last count, kept until the content changes: going
    /// from one match to the next then costs no further pass over the buffer.
    private var countedMatches: (term: String, options: SearchOptions, limit: Int, results: [SearchResult])?
    /// The highlight pattern of each owner. A find sets only its owner's
    /// pattern, so the find bar does not remove the highlights of the host.
    private var highlightPatterns: [SearchHighlightOwner: (term: String, options: SearchOptions)] = [:]
#if DEBUG
    var testingSearchRowVisits: Int { engine.testingRowVisits }
    var testingVisibleRowsTranslated: Int { engine.testingVisibleRowsTranslated }
#endif

    /// The pattern that "highlight all matches" paints: the find bar's
    /// pattern while it has one, or else the host's. `invalidate()` keeps
    /// it. `reset()` and `clearHighlightPattern()` remove it.
    var activePattern: (term: String, options: SearchOptions)? {
        highlightPatterns[.findBar] ?? highlightPatterns[.host]
    }

    /// Removes the highlight pattern of `owner`, or of all owners for nil.
    /// The find state stays, so the next `findNext` continues from the
    /// current match.
    func clearHighlightPattern (owner: SearchHighlightOwner? = nil) {
        if let owner {
            highlightPatterns[owner] = nil
        } else {
            highlightPatterns.removeAll()
        }
    }

    /// See `SearchEngine.findTimeLimit`.
    var findTimeLimit: UInt64 {
        get { engine.findTimeLimit }
        set { engine.findTimeLimit = newValue }
    }

    /// See `SearchEngine.visibleMatchTimeLimit`.
    var visibleMatchTimeLimit: UInt64 {
        get { engine.visibleMatchTimeLimit }
        set { engine.visibleMatchTimeLimit = newValue }
    }

    /// The match columns of the rows `firstRow ..< firstRow + rowCount`, or
    /// nil for a search that used too much time. See
    /// `SearchEngine.visibleMatches` for the limits of this search.
    func visibleMatches (term: String, options: SearchOptions, firstRow: Int, rowCount: Int) -> [[Range<Int>]]? {
        engine.visibleMatches(term: term, searchOptions: options, firstRow: firstRow, rowCount: rowCount)
    }

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
        generation &+= 1
        countedMatches = nil
        lastResult = nil
        lastSelection = nil
    }

    /// - Parameter keepingHostHighlights: true removes only the find bar's
    ///   highlight pattern.
    func reset (keepingHostHighlights: Bool = false) {
        clearHighlightPattern(owner: keepingHostHighlights ? .findBar : nil)
        lineCache.invalidate()
        generation &+= 1
        countedMatches = nil
        state.reset()
        lastResult = nil
        lastSelection = nil
    }

    func updateLastSelection (_ selection: SearchSelection?) {
        lastSelection = selection
    }

    /// - Parameter highlights: the owner whose highlight pattern becomes
    ///   this term. Nil changes no highlight pattern.
    @discardableResult
    func findNext (term: String, options: SearchOptions = SearchOptions(),
                   highlights: SearchHighlightOwner? = .host) -> SearchResult? {
        guard state.isValidSearchTerm(term) else {
            lastResult = nil
            lastSelection = nil
            state.reset()
            if let highlights {
                highlightPatterns[highlights] = nil
            }
            return nil
        }

        if let highlights {
            highlightPatterns[highlights] = (term, options)
        }
        state.lastSearchOptions = options
        let result = engine.findNextWithSelection(term: term, searchOptions: options, cachedSearchTerm: state.cachedSearchTerm, previousSelection: lastSelection)
        state.cachedSearchTerm = term

        lastResult = result
        lastSelection = result.map { selection(for: $0) }
        return result
    }

    @discardableResult
    func findPrevious (term: String, options: SearchOptions = SearchOptions(),
                       highlights: SearchHighlightOwner? = .host) -> SearchResult? {
        guard state.isValidSearchTerm(term) else {
            lastResult = nil
            lastSelection = nil
            state.reset()
            if let highlights {
                highlightPatterns[highlights] = nil
            }
            return nil
        }

        if let highlights {
            highlightPatterns[highlights] = (term, options)
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

        return engine.findAll(term: term, searchOptions: options, limit: limit)
    }

    /// Counts the matches for `term`, up to `limit`, and locates the match
    /// that starts at `current` among them.
    /// - Returns: `index` is the 1-based position of that match, or 0 when
    ///   `current` is nil or is not one of the first `limit` matches.
    ///   `capped` is true when there are more than `limit` matches.
    func matchSummary (term: String, options: SearchOptions, limit: Int, current: Position?) -> (index: Int, total: Int, capped: Bool) {
        guard state.isValidSearchTerm(term), limit > 0 else {
            return (0, 0, false)
        }
        let results: [SearchResult]
        if let countedMatches, countedMatches.term == term, countedMatches.options == options, countedMatches.limit == limit {
            results = countedMatches.results
        } else {
            // One more than the limit tells "exactly the limit" from "more".
            results = engine.findAll(term: term, searchOptions: options, limit: limit + 1)
            countedMatches = (term, options, limit, results)
        }
        let total = min(results.count, limit)
        var index = 0
        if let current, let found = results.prefix(total).firstIndex(where: { $0.row == current.row && $0.col == current.col }) {
            index = found + 1
        }
        return (index, total, results.count > limit)
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

#endif // !SWIFTTERM_EMBEDDED
