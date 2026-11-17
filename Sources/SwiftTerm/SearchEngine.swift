//
//  SearchEngine.swift
//  SwiftTerm
//
//  Ported from xterm.js search addon infrastructure.
//

#if !SWIFTTERM_EMBEDDED
import Foundation

struct SearchResult: Equatable {
    let term: String
    let col: Int
    let row: Int
    let size: Int
}

struct SearchSelection {
    let start: Position
    let end: Position
}

final class SearchEngine {
    private let terminal: Terminal
    private let lineCache: SearchLineCache
    private let nonWordCharacters: Set<Character> = Set(" ~!@#$%^&*()+`-=[]{}|\\;:\"',./<>?")
    private var compiledRegex: (pattern: String, caseSensitive: Bool, regex: NSRegularExpression?)?
#if DEBUG
    /// Search entry and wrapped-parent row visits. Access under the terminal lock.
    private(set) var testingRowVisits = 0
    /// Rows that `visibleMatches` translated. Access under the terminal lock.
    private(set) var testingVisibleRowsTranslated = 0
#endif

    /// Rows that `visibleMatches` reads above and below the visible rows.
    static let visibleMatchMargin = 64
    /// The most time that one `visibleMatches` call can use, in nanoseconds.
    /// The search runs with the terminal lock held when a frame is prepared,
    /// so its cost has a limit. A search that uses more time gives no result.
    ///
    /// An optimized build needs 0.2 ms (80x24) to 2.2 ms (200x50, all cells
    /// match) for one search. A debug build needs four to five times more,
    /// so its limit is higher.
#if DEBUG
    var visibleMatchTimeLimit: UInt64 = 20_000_000
#else
    var visibleMatchTimeLimit: UInt64 = 4_000_000
#endif

    /// The most time that one regex find (`find`, `findAll`, find next,
    /// find previous) can use, in nanoseconds. A find runs with the
    /// terminal lock held, and a regex can backtrack without end. A regex
    /// find that uses more time stops: it gives no match, and `findAll`
    /// gives the matches that it has.
    ///
    /// A plain-text find has no limit. Its time is linear in the size of
    /// the buffer, and a limit could report "not found" for a term that
    /// is in a large scrollback.
    var findTimeLimit: UInt64 = 1_000_000_000
    /// The time (uptime nanoseconds) at which the find in progress stops.
    private var findDeadline: UInt64?

    /// The stop time for a find with these options: only a regex find
    /// has one.
    private func findDeadline (for options: SearchOptions?) -> UInt64? {
        guard options?.regex == true else { return nil }
        return DispatchTime.now().uptimeNanoseconds &+ findTimeLimit
    }

    /// True when the find in progress is past its time limit.
    private func findIsLate () -> Bool {
        guard let findDeadline else { return false }
        return DispatchTime.now().uptimeNanoseconds >= findDeadline
    }

    init (terminal: Terminal, lineCache: SearchLineCache) {
        self.terminal = terminal
        self.lineCache = lineCache
    }

    func find (term: String, startRow: Int, startCol: Int, searchOptions: SearchOptions? = nil) -> SearchResult? {
        if term.isEmpty {
            return nil
        }
        if startCol > terminal.cols {
            return nil
        }
        findDeadline = findDeadline(for: searchOptions)
        defer { findDeadline = nil }

        lineCache.initLinesCache()

        var searchPosition = SearchPosition(startCol: startCol, startRow: startRow)

        var result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: false)
        if result == nil {
            let buffer = terminal.displayBuffer
            let maxRow = buffer.lines.count
            if startRow + 1 < maxRow {
                // A wrapped row's matches were searched for with the row its
                // line starts on.
                for y in (startRow + 1)..<maxRow where !buffer.lines[y].isWrapped {
                    searchPosition.startRow = y
                    searchPosition.startCol = 0
                    result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: false)
                    if result != nil {
                        break
                    }
                }
            }
        }
        return result
    }

    /// The first `limit` matches, top to bottom, each starting past the end
    /// of the one before. One pass over each logical line: searching again
    /// from each match's end walked the line from its start every time.
    func findAll (term: String, searchOptions: SearchOptions? = nil, limit: Int) -> [SearchResult] {
        guard !term.isEmpty, limit > 0 else {
            return []
        }
        findDeadline = findDeadline(for: searchOptions)
        defer { findDeadline = nil }

        lineCache.initLinesCache()

        let buffer = terminal.displayBuffer
        let options = searchOptions ?? SearchOptions()
        var results: [SearchResult] = []
        for row in 0..<buffer.lines.count where !buffer.lines[row].isWrapped {
            let entry = logicalLine(at: row)
            let line = entry.lineAsString
            let finished = forEachMatch(of: term, in: line, options: options, deadline: findDeadline) { found, offset in
                results.append(result(term: options.regex ? String(line[found]) : term, at: offset, row: row,
                                      offsets: entry.lineOffsets))
                return results.count < limit
            }
            if results.count == limit || !finished {
                break
            }
        }
        return results
    }

    /// The columns of all matches on the rows `firstRow ..< firstRow + rowCount`.
    ///
    /// The result index is the row minus `firstRow`. The ranges of a row are
    /// in ascending order, and adjacent ranges are merged.
    ///
    /// This is the frame path. It reads only the window
    /// `firstRow - visibleMatchMargin ..< firstRow + rowCount + visibleMatchMargin`
    /// and it does not use the lines cache. When a logical line is longer
    /// than the window, the search sees only the part in the window. At such
    /// a clip edge the result can be different from `findNext`, which
    /// searches the full logical line:
    /// - a regex anchor (`^`, `$`) or a lookaround can match at the edge;
    /// - the whole-word test sees the edge as a word boundary;
    /// - a match that crosses the edge is absent or shorter.
    /// A different result is visible only if it extends across the margin.
    ///
    /// The result is nil when the search used more than
    /// `visibleMatchTimeLimit`. There is no partial result: highlights on
    /// only the top rows of the view would look like a wrong search. The
    /// time limit also stops a regex that backtracks without end.
    func visibleMatches (term: String, searchOptions: SearchOptions? = nil,
                         firstRow: Int, rowCount: Int) -> [[Range<Int>]]? {
        let buffer = terminal.displayBuffer
        let cols = terminal.cols
        let lineCount = buffer.lines.count
        guard !term.isEmpty, rowCount > 0, cols > 0, firstRow >= 0, firstRow < lineCount else {
            return []
        }
        let endRow = min(firstRow + rowCount, lineCount)
        let windowTop = max(0, firstRow - Self.visibleMatchMargin)
        let windowLast = min(lineCount, endRow + Self.visibleMatchMargin) - 1
        let options = searchOptions ?? SearchOptions()
        var rows = [[Range<Int>]](repeating: [], count: endRow - firstRow)
        let deadline = DispatchTime.now().uptimeNanoseconds &+ visibleMatchTimeLimit

        var row = firstRow
        while row > windowTop && buffer.lines[row].isWrapped {
            row -= 1
        }
        while row < endRow {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                return nil
            }
            let entry = lineCache.translateBufferLineToStringWithWrap(
                lineIndex: row, trimRight: true, lastRow: windowLast)
#if DEBUG
            testingVisibleRowsTranslated &+= entry.lineOffsets.count
#endif
            let line = entry.lineAsString
            let offsets = entry.lineOffsets
            let termLength = term.count
            // Matches come in ascending order, so the row of a match is
            // found from the row of the match before it, and each row's
            // column table is built one time.
            var tables = [ColumnTable?](repeating: nil, count: offsets.count)
            var startRowOffset = 0
            let finished = forEachMatch(of: term, in: line, options: options, deadline: deadline) { found, offset in
                let end = offset + (options.regex ? line.distance(from: found.lowerBound, to: found.upperBound)
                                                  : termLength)
                while startRowOffset < offsets.count - 1 && offset >= offsets[startRowOffset + 1] {
                    startRowOffset += 1
                }
                var endRowOffset = startRowOffset
                while endRowOffset < offsets.count - 1 && end >= offsets[endRowOffset + 1] {
                    endRowOffset += 1
                }
                if row + startRowOffset >= endRow {
                    return false
                }
                if row + endRowOffset < firstRow {
                    return true
                }
                if tables[startRowOffset] == nil {
                    tables[startRowOffset] = columnTable(row: row + startRowOffset)
                }
                if tables[endRowOffset] == nil {
                    tables[endRowOffset] = columnTable(row: row + endRowOffset)
                }
                var col = tables[startRowOffset]!.startColumn(offset - offsets[startRowOffset])
                let endCol = tables[endRowOffset]!.endColumn(end - offsets[endRowOffset])
                var remaining = endCol - col + cols * (endRowOffset - startRowOffset)
                var matchRow = row + startRowOffset
                while remaining > 0 && matchRow < endRow {
                    let count = min(remaining, cols - col)
                    guard count > 0 else {
                        break
                    }
                    if matchRow >= firstRow {
                        let index = matchRow - firstRow
                        if let last = rows[index].last, last.upperBound >= col {
                            rows[index][rows[index].count - 1] = last.lowerBound..<max(last.upperBound, col + count)
                        } else {
                            rows[index].append(col..<(col + count))
                        }
                    }
                    remaining -= count
                    matchRow += 1
                    col = 0
                }
                return true
            }
            if !finished {
                return nil
            }
            row += offsets.count
        }
        return rows
    }

    /// Calls `body` for each match in `line` that the options accept, with
    /// the match and its character offset in the line. The matches are in
    /// ascending order and do not overlap. `body` returns false to stop.
    ///
    /// With a `deadline` (uptime nanoseconds), the search stops when the
    /// time is past it, also in the middle of one regex match attempt. The
    /// result is false only for a search that the deadline stopped.
    ///
    /// A regex gets one pass on the full line, so `^`, `$`, `\b` and
    /// lookarounds see the real text around each match. A search that starts
    /// again at the end of each match takes that position as a line start.
    @discardableResult
    private func forEachMatch (of term: String, in line: String, options: SearchOptions,
                               deadline: UInt64? = nil,
                               _ body: (_ found: Range<String.Index>, _ offset: Int) -> Bool) -> Bool {
        var matchCount = 0
        // The clock is read one time for each 64 matches.
        func isLate () -> Bool {
            guard let deadline else { return false }
            matchCount &+= 1
            return matchCount & 63 == 0 && DispatchTime.now().uptimeNanoseconds >= deadline
        }
        var lower = line.startIndex
        var lowerOffset = 0
        // The offset of `found`, counted from the end of the match before it.
        func offset (of found: Range<String.Index>) -> Int {
            let offset = lowerOffset + line.distance(from: lower, to: found.lowerBound)
            lowerOffset = offset + line.distance(from: found.lowerBound, to: found.upperBound)
            lower = found.upperBound
            return offset
        }
        if options.regex {
            guard let regex = regex(for: term, caseSensitive: options.caseSensitive) else {
                return true
            }
            var late = false
            // `reportProgress` calls the block with no match during a long
            // match attempt, which is the only place to stop such an attempt.
            regex.enumerateMatches(in: line, options: deadline == nil ? [] : [.reportProgress],
                                   range: NSRange(lower..<line.endIndex, in: line)) { match, flags, stop in
                if let deadline, flags.contains(.progress) || match == nil {
                    if DispatchTime.now().uptimeNanoseconds >= deadline {
                        late = true
                        stop.pointee = true
                    }
                    return
                }
                if isLate() {
                    late = true
                    stop.pointee = true
                    return
                }
                // A match that is not on character boundaries, or that
                // overlaps the match before it, has no place in the line.
                guard let match, match.range.length > 0, let found = Range(match.range, in: line),
                      found.lowerBound >= lower,
                      !options.wholeWord || isWholeWord(found, in: line) else {
                    return
                }
                if !body(found, offset(of: found)) {
                    stop.pointee = true
                }
            }
            return !late
        }
        while let found = match(of: term, in: line, from: lower, options: options, isReverseSearch: false) {
            if isLate() {
                return false
            }
            if !body(found, offset(of: found)) {
                return true
            }
        }
        return true
    }

    /// For one buffer row, the column of each character offset in its text.
    /// This holds the results of `stringLengthToBufferSize` for all offsets.
    private struct ColumnTable {
        var start: [Int] = [0]
        var end: [Int] = [0]
        var lastColumn = 0

        func startColumn (_ offset: Int) -> Int {
            offset < start.count ? start[max(offset, 0)] : lastColumn
        }

        func endColumn (_ offset: Int) -> Int {
            offset < end.count ? end[max(offset, 0)] : lastColumn
        }
    }

    private func columnTable (row: Int) -> ColumnTable {
        var table = ColumnTable()
        let buffer = terminal.displayBuffer
        guard row >= 0 && row < buffer.lines.count else {
            return table
        }
        let line = buffer.lines[row]
        table.start.reserveCapacity(line.count + 1)
        table.end.reserveCapacity(line.count + 1)
        var column = 0
        while column < line.count {
            let cell = line.packedView(at: column)
            let width = max(1, Int(cell.width))
            let count = cell.getText().count
            if count > 0 {
                // An offset in the middle of a cell's text.
                for _ in 1..<count {
                    table.start.append(column)
                    table.end.append(column + width)
                }
                table.start.append(column + width)
                table.end.append(column + width)
            }
            column += width
        }
        table.lastColumn = column
        return table
    }

    func findNextWithSelection (term: String, searchOptions: SearchOptions? = nil, cachedSearchTerm: String?, previousSelection: SearchSelection?) -> SearchResult? {
        if term.isEmpty {
            return nil
        }
        findDeadline = findDeadline(for: searchOptions)
        defer { findDeadline = nil }

        lineCache.initLinesCache()

        var startCol = 0
        var startRow = 0
        if let previousSelection {
            if cachedSearchTerm == term {
                startCol = previousSelection.end.col
                startRow = previousSelection.end.row
            } else {
                startCol = previousSelection.start.col
                startRow = previousSelection.start.row
            }
        }

        var searchPosition = SearchPosition(startCol: startCol, startRow: startRow)
        var result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: false)

        let buffer = terminal.displayBuffer
        if result == nil {
            let maxRow = buffer.lines.count
            if startRow + 1 < maxRow {
                for y in (startRow + 1)..<maxRow where !buffer.lines[y].isWrapped {
                    searchPosition.startRow = y
                    searchPosition.startCol = 0
                    result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: false)
                    if result != nil {
                        break
                    }
                }
            }
        }

        if result == nil && startRow != 0 {
            for y in 0..<startRow where !buffer.lines[y].isWrapped {
                searchPosition.startRow = y
                searchPosition.startCol = 0
                result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: false)
                if result != nil {
                    break
                }
            }
        }

        if result == nil, let previousSelection {
            searchPosition.startRow = previousSelection.start.row
            searchPosition.startCol = 0
            result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: false)
        }

        return result
    }

    func findPreviousWithSelection (term: String, searchOptions: SearchOptions? = nil, cachedSearchTerm: String?, previousSelection: SearchSelection?) -> SearchResult? {
        if term.isEmpty {
            return nil
        }
        findDeadline = findDeadline(for: searchOptions)
        defer { findDeadline = nil }

        lineCache.initLinesCache()

        let maxRow = terminal.displayBuffer.lines.count - 1
        var startRow = maxRow
        var startCol = terminal.cols
        let isReverseSearch = true

        var searchPosition = SearchPosition(startCol: startCol, startRow: startRow)
        var result: SearchResult?

        if let previousSelection {
            startRow = previousSelection.start.row
            startCol = previousSelection.start.col
            searchPosition.startRow = startRow
            searchPosition.startCol = startCol
            if cachedSearchTerm != term {
                result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: false)
                if result == nil {
                    startRow = previousSelection.end.row
                    startCol = previousSelection.end.col
                    searchPosition.startRow = startRow
                    searchPosition.startCol = startCol
                }
            }
        }

        if result == nil {
            result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: isReverseSearch)
        }

        if result == nil {
            searchPosition.startCol = max(searchPosition.startCol, terminal.cols)
            if startRow - 1 >= 0 {
                for y in stride(from: startRow - 1, through: 0, by: -1) {
                    searchPosition.startRow = y
                    result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: isReverseSearch)
                    if result != nil {
                        break
                    }
                }
            }
        }

        if result == nil && startRow != maxRow {
            for y in stride(from: maxRow, through: startRow, by: -1) {
                searchPosition.startRow = y
                result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: isReverseSearch)
                if result != nil {
                    break
                }
            }
        }

        return result
    }

    /// Whether the match at `range` stands alone: the characters beside it,
    /// if any, are non-word characters.
    private func isWholeWord (_ range: Range<String.Index>, in line: String) -> Bool {
        let before = range.lowerBound > line.startIndex ? line[line.index(before: range.lowerBound)] : " "
        let after = range.upperBound < line.endIndex ? line[range.upperBound] : " "
        return nonWordCharacters.contains(before) && nonWordCharacters.contains(after)
    }

    /// The compiled pattern, kept for the next row and the next search.
    private func regex (for pattern: String, caseSensitive: Bool) -> NSRegularExpression? {
        if let compiledRegex, compiledRegex.pattern == pattern, compiledRegex.caseSensitive == caseSensitive {
            return compiledRegex.regex
        }
        let regex = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
        compiledRegex = (pattern, caseSensitive, regex)
        return regex
    }

    private func findInLine (term: String, searchPosition: inout SearchPosition, searchOptions: SearchOptions? = nil, isReverseSearch: Bool = false) -> SearchResult? {
#if DEBUG
        testingRowVisits &+= 1
#endif
        let buffer = terminal.displayBuffer

        guard searchPosition.startRow >= 0 && searchPosition.startRow < buffer.lines.count,
              !findIsLate() else {
            return nil
        }

        if buffer.lines[searchPosition.startRow].isWrapped {
            if isReverseSearch {
                searchPosition.startCol += terminal.cols
                return nil
            }
            // Search the logical line from this row's place in it. A loop,
            // so a line wrapped over thousands of rows can't overflow the stack.
            repeat {
#if DEBUG
                testingRowVisits &+= 1
#endif
                searchPosition.startRow -= 1
                searchPosition.startCol += terminal.cols
            } while searchPosition.startRow >= 0 && buffer.lines[searchPosition.startRow].isWrapped
            guard searchPosition.startRow >= 0 else {
                return nil
            }
        }
        let row = searchPosition.startRow
        let col = searchPosition.startCol

        let cacheEntry = logicalLine(at: row)
        let stringLine = cacheEntry.lineAsString
        let offsets = cacheEntry.lineOffsets
        let offset = bufferColsToStringOffset(startRow: row, cols: col)
        let options = searchOptions ?? SearchOptions()
        let clampedOffset = min(offset, stringLine.count)
        let offsetIndex = stringLine.index(stringLine.startIndex, offsetBy: clampedOffset)

        if isReverseSearch && !options.regex && clampedOffset - term.count < 0 {
            return nil
        }
        guard let found = match(of: term, in: stringLine, from: offsetIndex, options: options,
                                isReverseSearch: isReverseSearch) else {
            return nil
        }
        let foundIndex = stringLine.distance(from: stringLine.startIndex, to: found.lowerBound)
        return result(term: options.regex ? String(stringLine[found]) : term, at: foundIndex, row: row, offsets: offsets)
    }

    /// The text of the logical line that starts at `row`, from the cache.
    private func logicalLine (at row: Int) -> LineCacheEntry {
        if let cached = lineCache.getLineFromCache(row: row) {
            return cached
        }
        let translated = lineCache.translateBufferLineToStringWithWrap(lineIndex: row, trimRight: true)
        lineCache.setLineInCache(row: row, entry: translated)
        return translated
    }

    /// The nearest match the options accept in `line`, from `index` in the
    /// search's direction. A rejected match doesn't end the search, so one
    /// search of a logical line finds what its later rows would.
    private func match (of term: String, in line: String, from index: String.Index, options: SearchOptions,
                        isReverseSearch: Bool) -> Range<String.Index>? {
        if options.regex {
            guard let regex = regex(for: term, caseSensitive: options.caseSensitive) else {
                return nil
            }
            let range = isReverseSearch ? line.startIndex..<index : index..<line.endIndex
            // The search starts in the middle of the line. These options
            // let `^`, `$`, `\b` and lookarounds see the text outside the
            // range, so the start position is not taken as a line start.
            // `reportProgress` calls the block with no match during a long
            // match attempt, so that a find past its time limit can stop.
            let bounds: NSRegularExpression.MatchingOptions = findDeadline == nil
                ? [.withoutAnchoringBounds, .withTransparentBounds]
                : [.withoutAnchoringBounds, .withTransparentBounds, .reportProgress]
            let accepted = { (match: NSTextCheckingResult) -> Range<String.Index>? in
                guard match.range.length > 0, let range = Range(match.range, in: line),
                      !options.wholeWord || self.isWholeWord(range, in: line) else {
                    return nil
                }
                return range
            }
            var found: Range<String.Index>?
            regex.enumerateMatches(in: line, options: bounds, range: NSRange(range, in: line)) { match, _, stop in
                guard let match else {
                    if self.findIsLate() {
                        found = nil
                        stop.pointee = true
                    }
                    return
                }
                if let range = accepted(match) {
                    // The first match forward, the last match in reverse.
                    found = range
                    if !isReverseSearch {
                        stop.pointee = true
                    }
                }
            }
            return found
        }
        let compareOptions: String.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
        if isReverseSearch {
            var upper = index
            while let match = line.range(of: term, options: compareOptions.union(.backwards), range: line.startIndex..<upper) {
                if !options.wholeWord || isWholeWord(match, in: line) {
                    return match
                }
                upper = line.index(before: match.upperBound)
            }
            return nil
        }
        var lower = index
        while lower < line.endIndex, let match = line.range(of: term, options: compareOptions, range: lower..<line.endIndex) {
            if !options.wholeWord || isWholeWord(match, in: line) {
                return match
            }
            lower = line.index(after: match.lowerBound)
        }
        return nil
    }

    /// The result for `matchTerm` found `foundIndex` characters into the
    /// logical line that starts at `row`, whose rows start at `offsets`.
    private func result (term matchTerm: String, at foundIndex: Int, row: Int, offsets: [Int]) -> SearchResult {
        var startRowOffset = 0
        while startRowOffset < offsets.count - 1 && foundIndex >= offsets[startRowOffset + 1] {
            startRowOffset += 1
        }

        var endRowOffset = startRowOffset
        while endRowOffset < offsets.count - 1 && (foundIndex + matchTerm.count) >= offsets[endRowOffset + 1] {
            endRowOffset += 1
        }

        let startColOffset = foundIndex - offsets[startRowOffset]
        let endColOffset = foundIndex + matchTerm.count - offsets[endRowOffset]
        let startColIndex = stringLengthToBufferSize(
            row: row + startRowOffset, offset: startColOffset, roundUp: false)
        let endColIndex = stringLengthToBufferSize(
            row: row + endRowOffset, offset: endColOffset, roundUp: true)
        let size = endColIndex - startColIndex + terminal.cols * (endRowOffset - startRowOffset)

        return SearchResult(term: matchTerm, col: startColIndex, row: row + startRowOffset, size: size)
    }

    private func stringLengthToBufferSize(row: Int, offset: Int,
                                          roundUp: Bool) -> Int {
        let buffer = terminal.displayBuffer
        guard row >= 0 && row < buffer.lines.count else {
            return 0
        }
        if offset == 0 {
            return 0
        }

        let line = buffer.lines[row]
        var stringOffset = 0
        var column = 0
        while column < line.count {
            let cell = line.packedView(at: column)
            let width = max(1, Int(cell.width))
            let nextStringOffset = stringOffset + cell.getText().count
            if offset < nextStringOffset {
                return roundUp ? column + width : column
            }
            if offset == nextStringOffset {
                return column + width
            }
            stringOffset = nextStringOffset
            column += width
        }
        return column
    }

    private func bufferColsToStringOffset (startRow: Int, cols: Int) -> Int {
        let buffer = terminal.displayBuffer
        var lineIndex = startRow
        var offset = 0
        var remainingCols = cols

        while remainingCols > 0 && lineIndex < buffer.lines.count {
            let line = buffer.lines[lineIndex]
            let limit = min(remainingCols, terminal.cols)
            if limit > 0 {
                var column = 0
                while column < limit {
                    let cell = line.packedView(at: column)
                    let width = max(1, Int(cell.width))
                    offset += cell.getText().count
                    column += width
                }
            }
            lineIndex += 1
            if lineIndex >= buffer.lines.count {
                break
            }
            let nextLine = buffer.lines[lineIndex]
            if !nextLine.isWrapped {
                break
            }
            remainingCols -= terminal.cols
        }

        return offset
    }
}

private struct SearchPosition {
    var startCol: Int
    var startRow: Int
}

#endif // !SWIFTTERM_EMBEDDED
