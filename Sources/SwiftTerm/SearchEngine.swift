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
            let maxRow = terminal.displayBuffer.lines.count
            if startRow + 1 < maxRow {
                for y in (startRow + 1)..<maxRow {
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

        if result == nil {
            let maxRow = terminal.displayBuffer.lines.count
            if startRow + 1 < maxRow {
                for y in (startRow + 1)..<maxRow {
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
            for y in 0..<startRow {
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

        // findInLine normalizes wrapped positions to the first physical row.
        // Continue before that logical line, rather than scanning its wrapped
        // rows again and counting their columns twice.
        let startingLogicalRow = searchPosition.startRow
        if result == nil {
            var row = startingLogicalRow - 1
            while row >= 0 {
                searchPosition = SearchPosition(startCol: terminal.cols, startRow: row)
                result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: isReverseSearch)
                if result != nil { break }
                row = searchPosition.startRow - 1
            }
        }

        if result == nil {
            var row = maxRow
            while row >= startingLogicalRow {
                searchPosition = SearchPosition(startCol: terminal.cols, startRow: row)
                result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: isReverseSearch)
                if result != nil { break }
                row = searchPosition.startRow - 1
            }
        }

        return result
    }

    private func isWholeWord (searchIndex: Int, line: String, term: String) -> Bool {
        let beforeIndex = searchIndex - 1
        let afterIndex = searchIndex + term.count

        let beforeIsBoundary: Bool
        if beforeIndex < 0 {
            beforeIsBoundary = true
        } else {
            beforeIsBoundary = nonWordCharacters.contains(character(at: beforeIndex, in: line) ?? " ")
        }

        let afterIsBoundary: Bool
        if afterIndex >= line.count {
            afterIsBoundary = true
        } else {
            afterIsBoundary = nonWordCharacters.contains(character(at: afterIndex, in: line) ?? " ")
        }

        return beforeIsBoundary && afterIsBoundary
    }

    private func character (at offset: Int, in line: String) -> Character? {
        guard offset >= 0 && offset < line.count else {
            return nil
        }
        let idx = line.index(line.startIndex, offsetBy: offset)
        return line[idx]
    }

    private func findInLine (term: String, searchPosition: inout SearchPosition, searchOptions: SearchOptions? = nil, isReverseSearch: Bool = false) -> SearchResult? {
        var row = searchPosition.startRow
        var col = searchPosition.startCol
        let buffer = terminal.displayBuffer

        guard row >= 0 && row < buffer.lines.count else {
            return nil
        }

        // A logical line can span the entire scrollback. Normalize iteratively
        // and stop at the first retained row if its beginning has been trimmed.
        while row > 0 && buffer.lines[row].isWrapped {
            row -= 1
            col += terminal.cols
        }
        searchPosition.startRow = row
        searchPosition.startCol = col

        var cache = lineCache.getLineFromCache(row: row)
        if cache == nil {
            let translated = lineCache.translateBufferLineToStringWithWrap(lineIndex: row, trimRight: true)
            lineCache.setLineInCache(row: row, entry: translated)
            cache = translated
        }

        guard let cacheEntry = cache else {
            return nil
        }

        let stringLine = cacheEntry.lineAsString
        let offsets = cacheEntry.lineOffsets
        let offset = bufferColsToStringOffset(startRow: row, cols: col, lineOffsets: offsets)
        let options = searchOptions ?? SearchOptions()

        var resultIndex: Int?
        var matchTerm = term

        // A rejected boundary or empty regex match must not hide later
        // selectable matches in the same logical (possibly wrapped) line.
        func accept(_ range: Range<String.Index>) -> Bool {
            guard !range.isEmpty else { return false }
            let index = stringLine.distance(from: stringLine.startIndex, to: range.lowerBound)
            let matched = String(stringLine[range])
            guard !options.wholeWord || isWholeWord(searchIndex: index, line: stringLine, term: matched) else {
                return false
            }
            resultIndex = index
            matchTerm = options.regex ? matched : term
            return true
        }

        let clampedOffset = min(offset, stringLine.count)
        let offsetIndex = stringLine.index(stringLine.startIndex, offsetBy: clampedOffset)
        if options.regex {
            let regexOptions: NSRegularExpression.Options = options.caseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: term, options: regexOptions) else {
                return nil
            }
            let range = isReverseSearch ? stringLine.startIndex..<offsetIndex : offsetIndex..<stringLine.endIndex
            let searchRange = NSRange(range, in: stringLine)
            if isReverseSearch {
                for match in regex.matches(in: stringLine, options: [], range: searchRange).reversed() {
                    if let range = Range(match.range, in: stringLine), accept(range) {
                        break
                    }
                }
            } else {
                regex.enumerateMatches(in: stringLine, options: [], range: searchRange) { match, _, stop in
                    if let match, let range = Range(match.range, in: stringLine), accept(range) {
                        stop.pointee = true
                    }
                }
            }
        } else {
            var compareOptions: String.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
            if isReverseSearch { compareOptions.insert(.backwards) }
            var range = isReverseSearch ? stringLine.startIndex..<offsetIndex : offsetIndex..<stringLine.endIndex
            while let found = stringLine.range(of: term, options: compareOptions, range: range) {
                if accept(found) { break }
                if isReverseSearch {
                    range = stringLine.startIndex..<stringLine.index(before: found.upperBound)
                } else {
                    range = stringLine.index(after: found.lowerBound)..<stringLine.endIndex
                }
            }
        }

        guard let foundIndex = resultIndex else {
            return nil
        }

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

    private func bufferColsToStringOffset (startRow: Int, cols: Int, lineOffsets: [Int]) -> Int {
        let buffer = terminal.displayBuffer
        // Full rows must use the cached text offsets, which omit the empty
        // last cell when a wide character wraps to the following row.
        let rowOffset = min(cols / terminal.cols, lineOffsets.count - 1)
        let line = buffer.lines[startRow + rowOffset]
        var offset = lineOffsets[rowOffset]
        let limit = min(cols - rowOffset * terminal.cols, terminal.cols)
        var column = 0
        while column < limit {
            let cell = line.packedView(at: column)
            offset += cell.getText().count
            column += max(1, Int(cell.width))
        }
        return offset
    }
}

private struct SearchPosition {
    var startCol: Int
    var startRow: Int
}

#endif // !SWIFTTERM_EMBEDDED
