//
//  SearchEngine.swift
//  SwiftTerm
//
//  Ported from xterm.js search addon infrastructure.
//

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
        let row = searchPosition.startRow
        let col = searchPosition.startCol
        let buffer = terminal.displayBuffer

        guard row >= 0 && row < buffer.lines.count else {
            return nil
        }

        let firstLine = buffer.lines[row]
        if firstLine.isWrapped {
            if isReverseSearch {
                searchPosition.startCol += terminal.cols
                return nil
            }
            searchPosition.startRow -= 1
            searchPosition.startCol += terminal.cols
            return findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: isReverseSearch)
        }

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
        let offset = bufferColsToStringOffset(startRow: row, cols: col)
        let options = searchOptions ?? SearchOptions()

        var resultIndex: Int?
        var matchTerm = term

        if options.regex {
            let regexOptions: NSRegularExpression.Options = options.caseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: term, options: regexOptions) else {
                return nil
            }
            let clampedOffset = min(offset, stringLine.count)
            let offsetIndex = stringLine.index(stringLine.startIndex, offsetBy: clampedOffset)

            if isReverseSearch {
                let searchRange = NSRange(stringLine.startIndex..<offsetIndex, in: stringLine)
                let matches = regex.matches(in: stringLine, options: [], range: searchRange)
                if let match = matches.last, match.range.length > 0, let matchRange = Range(match.range, in: stringLine) {
                    resultIndex = stringLine.distance(from: stringLine.startIndex, to: matchRange.lowerBound)
                    matchTerm = String(stringLine[matchRange])
                }
            } else {
                let searchRange = NSRange(offsetIndex..<stringLine.endIndex, in: stringLine)
                if let match = regex.firstMatch(in: stringLine, options: [], range: searchRange), match.range.length > 0,
                   let matchRange = Range(match.range, in: stringLine) {
                    resultIndex = stringLine.distance(from: stringLine.startIndex, to: matchRange.lowerBound)
                    matchTerm = String(stringLine[matchRange])
                }
            }
        } else {
            let searchOptions: String.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
            let clampedOffset = min(offset, stringLine.count)
            let offsetIndex = stringLine.index(stringLine.startIndex, offsetBy: clampedOffset)

            if isReverseSearch {
                if clampedOffset - matchTerm.count >= 0 {
                    let range = stringLine.startIndex..<offsetIndex
                    if let foundRange = stringLine.range(of: matchTerm, options: searchOptions.union(.backwards), range: range) {
                        resultIndex = stringLine.distance(from: stringLine.startIndex, to: foundRange.lowerBound)
                    }
                }
            } else {
                let range = offsetIndex..<stringLine.endIndex
                if let foundRange = stringLine.range(of: matchTerm, options: searchOptions, range: range) {
                    resultIndex = stringLine.distance(from: stringLine.startIndex, to: foundRange.lowerBound)
                }
            }
        }

        guard let foundIndex = resultIndex else {
            return nil
        }

        if options.wholeWord && !isWholeWord(searchIndex: foundIndex, line: stringLine, term: matchTerm) {
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
        let startColIndex = stringLengthToBufferSize(row: row + startRowOffset, offset: startColOffset)
        let endColIndex = stringLengthToBufferSize(row: row + endRowOffset, offset: endColOffset)
        let size = endColIndex - startColIndex + terminal.cols * (endRowOffset - startRowOffset)

        return SearchResult(term: matchTerm, col: startColIndex, row: row + startRowOffset, size: size)
    }

    private func stringLengthToBufferSize (row: Int, offset: Int) -> Int {
        let buffer = terminal.displayBuffer
        guard row >= 0 && row < buffer.lines.count else {
            return 0
        }
        if offset == 0 {
            return 0
        }

        let line = buffer.lines[row]
        var adjustedOffset = offset
        var i = 0
        while i < adjustedOffset && i < line.count {
            let cell = line[i]
            if cell.width == 2 {
                let nextIndex = i + 1
                if nextIndex < line.count {
                    let nextCell = line[nextIndex]
                    if nextCell.width == 0 {
                        adjustedOffset += 1
                    }
                }
            }
            i += 1
        }

        return adjustedOffset
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
                for i in 0..<limit {
                    let cell = line[i]
                    if cell.width > 0 {
                        offset += 1
                    }
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
