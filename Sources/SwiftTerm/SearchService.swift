//
//  SearchService.swift
//  SwiftTerm
//
//  Ported and adapted from the xterm.js search addon infrastructure.
//

#if !SWIFTTERM_EMBEDDED
import Foundation

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
    /// The last `findAll` answer, kept until the buffer changes: the match
    /// counter and the highlight set ask for the same list after every step.
    private var allMatches: (term: String, options: SearchOptions, limit: Int, results: [SearchResult])?

    private(set) var lastResult: SearchResult?
    /// The term and options of the last search, for a caller that wants to
    /// repeat it (a host turning highlights on) without holding them itself.
    var currentTerm: String? { state.cachedSearchTerm }
    var currentOptions: SearchOptions? { state.lastSearchOptions }
#if DEBUG
    var testingSearchRowVisits: Int { engine.testingRowVisits }
#endif

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
        allMatches = nil
        lastResult = nil
        lastSelection = nil
    }

    func reset () {
        lineCache.invalidate()
        state.reset()
        allMatches = nil
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
        if let cached = allMatches, cached.term == term, cached.options == options, cached.limit == limit {
            return cached.results
        }
        let results = engine.findAll(term: term, searchOptions: options, limit: limit)
        allMatches = (term, options, limit, results)
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

/// Where one search match sits in the buffer, for a host that marks matches
/// outside the text (a scrollbar tick per match, say).
public struct SearchMatchPosition: Equatable, Sendable {
    /// The buffer row the match starts in, scrollback included: 0 is the
    /// oldest line the terminal still holds.
    public let row: Int
    /// The column the match starts in.
    public let col: Int
    /// The number of cells the match covers; a match wider than the row
    /// continues on the next one.
    public let length: Int

    public init (row: Int, col: Int, length: Int) {
        self.row = row
        self.col = col
        self.length = length
    }

    init (_ result: SearchResult) {
        self.init(row: result.row, col: result.col, length: result.size)
    }
}

/// The cells every search match covers, by buffer row, as the renderer reads
/// them: a row's ranges are sorted by column and do not overlap. A match that
/// wraps contributes a range to each row it touches.
struct SearchHighlights: Equatable, Sendable {
    static let none = SearchHighlights(rows: [:])

    private let rows: [Int: [Range<Int>]]

    var isEmpty: Bool { rows.isEmpty }

    private init (rows: [Int: [Range<Int>]]) {
        self.rows = rows
    }

    init (results: [SearchResult], cols: Int) {
        let cols = max(cols, 1)
        var rows: [Int: [Range<Int>]] = [:]
        for result in results where result.size > 0 {
            var row = result.row
            var col = result.col
            var remaining = result.size
            while remaining > 0 {
                let span = min(remaining, cols - col)
                rows[row, default: []].append(col..<(col + span))
                remaining -= span
                row += 1
                col = 0
            }
        }
        self.rows = rows
    }

    /// The highlighted column ranges of `row`, or nil when it has none.
    func ranges (forRow row: Int) -> [Range<Int>]? {
        rows[row]
    }

    /// Whether any highlighted range covers the cells `[column, column + width)`.
    static func covers (_ ranges: [Range<Int>]?, column: Int, width: Int) -> Bool {
        guard let ranges else {
            return false
        }
        let endColumn = column + width
        for range in ranges {
            if range.lowerBound >= endColumn {
                return false
            }
            if column < range.upperBound {
                return true
            }
        }
        return false
    }
}

#endif // !SWIFTTERM_EMBEDDED
