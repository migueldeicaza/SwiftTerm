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
#endif

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

        lineCache.initLinesCache()

        let buffer = terminal.displayBuffer
        let options = searchOptions ?? SearchOptions()
        var results: [SearchResult] = []
        for row in 0..<buffer.lines.count where !buffer.lines[row].isWrapped {
            let entry = logicalLine(at: row)
            let line = entry.lineAsString
            var lower = line.startIndex
            var lowerOffset = 0
            while let found = match(of: term, in: line, from: lower, options: options, isReverseSearch: false) {
                let foundIndex = lowerOffset + line.distance(from: lower, to: found.lowerBound)
                results.append(result(term: options.regex ? String(line[found]) : term, at: foundIndex, row: row,
                                      offsets: entry.lineOffsets))
                if results.count == limit {
                    return results
                }
                lowerOffset = foundIndex + line.distance(from: found.lowerBound, to: found.upperBound)
                lower = found.upperBound
            }
        }
        return results
    }

    func findNextWithSelection (term: String, searchOptions: SearchOptions? = nil, cachedSearchTerm: String?, previousSelection: SearchSelection?) -> SearchResult? {
        if term.isEmpty {
            return nil
        }

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

        guard searchPosition.startRow >= 0 && searchPosition.startRow < buffer.lines.count else {
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
            let accepted = { (match: NSTextCheckingResult) -> Range<String.Index>? in
                guard match.range.length > 0, let range = Range(match.range, in: line),
                      !options.wholeWord || self.isWholeWord(range, in: line) else {
                    return nil
                }
                return range
            }
            if isReverseSearch {
                return regex.matches(in: line, options: [], range: NSRange(range, in: line))
                    .reversed().lazy.compactMap(accepted).first
            }
            var found: Range<String.Index>?
            regex.enumerateMatches(in: line, options: [], range: NSRange(range, in: line)) { match, _, stop in
                if let match, let range = accepted(match) {
                    found = range
                    stop.pointee = true
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
