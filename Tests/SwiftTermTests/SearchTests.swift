import Foundation
import Testing

@testable import SwiftTerm

final class SearchTests {
    private func makeTerminal(cols: Int = 80, rows: Int = 24) -> Terminal {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: cols, rows: rows)
        return terminal
    }

    // MARK: - SearchLineCache

    @Test func testSearchLineCacheStartsEmpty() {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)

        #expect(cache.getLineFromCache(row: 0) == nil)
    }

    @Test func testSearchLineCacheInitAndSetGet() {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)

        cache.setLineInCache(row: 0, entry: ("test", [0]))
        #expect(cache.getLineFromCache(row: 0) == nil)

        cache.initLinesCache()
        cache.setLineInCache(row: 0, entry: ("test", [0]))
        #expect(cache.getLineFromCache(row: 0)?.lineAsString == "test")
    }

    @Test func testSearchLineCacheInitDoesNotDropEntries() {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)

        cache.initLinesCache()
        cache.setLineInCache(row: 0, entry: ("test", [0]))
        cache.initLinesCache()

        #expect(cache.getLineFromCache(row: 0)?.lineAsString == "test")
    }

    @Test func testTranslateBufferLineToStringWithWrapBasic() {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)

        terminal.feed(text: "Hello World")
        let result = cache.translateBufferLineToStringWithWrap(lineIndex: 0, trimRight: true)

        #expect(result.lineAsString == "Hello World")
        #expect(result.lineOffsets == [0])
    }

    @Test func testTranslateBufferLineToStringWithWrapTrimRight() {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)

        terminal.feed(text: "Hello World   ")
        let trimmed = cache.translateBufferLineToStringWithWrap(lineIndex: 0, trimRight: true)
        let untrimmed = cache.translateBufferLineToStringWithWrap(lineIndex: 0, trimRight: false)

        #expect(trimmed.lineAsString.hasPrefix("Hello World"))
        #expect(untrimmed.lineAsString.count >= trimmed.lineAsString.count)
    }

    @Test func testTranslateBufferLineToStringWithWrapWrapped() {
        let terminal = makeTerminal(cols: 80, rows: 24)
        let cache = SearchLineCache(terminal: terminal)

        let longText = String(repeating: "A", count: 200)
        terminal.feed(text: longText)

        let result = cache.translateBufferLineToStringWithWrap(lineIndex: 0, trimRight: true)
        #expect(result.lineAsString == longText)
        #expect(result.lineOffsets.count > 1)
        #expect(result.lineOffsets.first == 0)
    }

    @Test func testTranslateBufferLineToStringWithWrapWideCharacters() {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)

        terminal.feed(text: "Hello 世界")
        let result = cache.translateBufferLineToStringWithWrap(lineIndex: 0, trimRight: true)

        #expect(result.lineAsString == "Hello 世界")
        #expect(result.lineOffsets == [0])
    }

    @Test func testTranslateBufferLineToStringWithWrapOutOfRange() {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)

        let result = cache.translateBufferLineToStringWithWrap(lineIndex: 1000, trimRight: true)
        #expect(result.lineAsString == "")
        #expect(result.lineOffsets == [0])
    }

    // MARK: - SearchEngine

    @Test func testSearchEngineFindBasic() {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)
        let engine = SearchEngine(terminal: terminal, lineCache: cache)

        terminal.feed(text: "Hello World")

        #expect(engine.find(term: "", startRow: 0, startCol: 0) == nil)
        #expect(engine.find(term: "World", startRow: 0, startCol: 0) == SearchResult(term: "World", col: 6, row: 0, size: 5))
    }

    @Test func testSearchEngineFindFromPosition() {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)
        let engine = SearchEngine(terminal: terminal, lineCache: cache)

        terminal.feed(text: "Hello Hello Hello")

        #expect(engine.find(term: "Hello", startRow: 0, startCol: 7) == SearchResult(term: "Hello", col: 12, row: 0, size: 5))
    }

    @Test func testSearchEngineFindAcrossRows() {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)
        let engine = SearchEngine(terminal: terminal, lineCache: cache)

        terminal.feed(text: "Line 1\r\nLine 2 target\r\nLine 3")

        #expect(engine.find(term: "target", startRow: 0, startCol: 0) == SearchResult(term: "target", col: 7, row: 1, size: 6))
    }

    @Test func testSearchEngineFindNotFoundAndInvalidCol() {
        let terminal = makeTerminal(cols: 80, rows: 24)
        let cache = SearchLineCache(terminal: terminal)
        let engine = SearchEngine(terminal: terminal, lineCache: cache)

        terminal.feed(text: "Hello World")

        #expect(engine.find(term: "NotFound", startRow: 0, startCol: 0) == nil)
        #expect(engine.find(term: "Hello", startRow: 0, startCol: 100) == nil)
        #expect(engine.find(term: "Hello", startRow: 0, startCol: 79) == nil)
    }

    @Test func testSearchEngineFindFromMiddleDoesNotMatchBeforeOffset() {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)
        let engine = SearchEngine(terminal: terminal, lineCache: cache)

        terminal.feed(text: "Hello World")

        #expect(engine.find(term: "llo", startRow: 0, startCol: 3) == nil)
    }

    @Test func testSearchEngineCaseSensitivity() {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)
        let engine = SearchEngine(terminal: terminal, lineCache: cache)

        terminal.feed(text: "Hello WORLD")

        #expect(engine.find(term: "world", startRow: 0, startCol: 0) == SearchResult(term: "world", col: 6, row: 0, size: 5))
        #expect(engine.find(term: "WORLD", startRow: 0, startCol: 0, searchOptions: SearchOptions(caseSensitive: true)) == SearchResult(term: "WORLD", col: 6, row: 0, size: 5))
        #expect(engine.find(term: "world", startRow: 0, startCol: 0, searchOptions: SearchOptions(caseSensitive: true)) == nil)
    }

    @Test func testSearchEngineWholeWord() {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)
        let engine = SearchEngine(terminal: terminal, lineCache: cache)

        terminal.feed(text: "Hello world wonderful")

        #expect(engine.find(term: "world", startRow: 0, startCol: 0, searchOptions: SearchOptions(wholeWord: true)) == SearchResult(term: "world", col: 6, row: 0, size: 5))
        #expect(engine.find(term: "wonder", startRow: 0, startCol: 0, searchOptions: SearchOptions(wholeWord: true)) == nil)
    }

    @Test func testSearchEngineWholeWordBoundaries() {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)
        let engine = SearchEngine(terminal: terminal, lineCache: cache)

        terminal.feed(text: "hello,world!test")

        #expect(engine.find(term: "world", startRow: 0, startCol: 0, searchOptions: SearchOptions(wholeWord: true)) == SearchResult(term: "world", col: 6, row: 0, size: 5))
    }

    @Test func testSearchEngineRegex() {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)
        let engine = SearchEngine(terminal: terminal, lineCache: cache)

        terminal.feed(text: "Hello 123 World")

        #expect(engine.find(term: "[0-9]+", startRow: 0, startCol: 0, searchOptions: SearchOptions(regex: true)) == SearchResult(term: "123", col: 6, row: 0, size: 3))
        #expect(engine.find(term: "[invalid", startRow: 0, startCol: 0, searchOptions: SearchOptions(regex: true)) == nil)
        #expect(engine.find(term: ".*?", startRow: 0, startCol: 0, searchOptions: SearchOptions(regex: true)) == nil)
    }

    @Test func testSearchEngineCombinedOptions() {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)
        let engine = SearchEngine(terminal: terminal, lineCache: cache)

        terminal.feed(text: "Hello WORLD world")

        #expect(engine.find(term: "[A-Z]+", startRow: 0, startCol: 0, searchOptions: SearchOptions(caseSensitive: true, regex: true)) == SearchResult(term: "H", col: 0, row: 0, size: 1))
        #expect(engine.find(term: "WORLD", startRow: 0, startCol: 0, searchOptions: SearchOptions(caseSensitive: true, wholeWord: true)) == SearchResult(term: "WORLD", col: 6, row: 0, size: 5))
    }

    @Test func testSearchEngineWrappedLines() {
        let terminal = makeTerminal(cols: 80, rows: 24)
        let cache = SearchLineCache(terminal: terminal)
        let engine = SearchEngine(terminal: terminal, lineCache: cache)

        let longText = String(repeating: "A", count: 100) + "target" + String(repeating: "B", count: 50)
        terminal.feed(text: longText)

        #expect(engine.find(term: "target", startRow: 0, startCol: 0) == SearchResult(term: "target", col: 20, row: 1, size: 6))
    }

    @Test func testSearchEngineUnicode() {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)
        let engine = SearchEngine(terminal: terminal, lineCache: cache)

        terminal.feed(text: "Hello 世界 World")

        #expect(engine.find(term: "世界", startRow: 0, startCol: 0) == SearchResult(term: "世界", col: 6, row: 0, size: 4))
    }

    @Test func testSearchMapsMultiCharacterCellToItsFullColumnSpan() throws {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)
        let engine = SearchEngine(terminal: terminal, lineCache: cache)
        let cluster = "\u{A98F}\u{A9C0}\u{A994}\u{A9B8}"
        let suffix = String(try #require(cluster.last))

        terminal.feed(text: "a\(cluster)b")

        #expect(cluster.count > 1)
        #expect(terminal.getCharData(col: 1, row: 0)?.getText() == cluster)
        #expect(terminal.getCharData(col: 1, row: 0)?.width == 2)
        #expect(engine.find(term: cluster, startRow: 0, startCol: 0) ==
            SearchResult(term: cluster, col: 1, row: 0, size: 2))
        #expect(engine.find(term: suffix, startRow: 0, startCol: 0) ==
            SearchResult(term: suffix, col: 1, row: 0, size: 2))
        #expect(engine.find(term: "b", startRow: 0, startCol: 3) ==
            SearchResult(term: "b", col: 3, row: 0, size: 1))
    }

    @Test func testSearchEngineBufferBoundaries() {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)
        let engine = SearchEngine(terminal: terminal, lineCache: cache)

        #expect(engine.find(term: "anything", startRow: 0, startCol: 0) == nil)
        #expect(engine.find(term: "test", startRow: 1000, startCol: 0) == nil)
    }

    // MARK: - SearchEngine selection helpers

    @Test func testSearchEngineFindNextWithSelection() {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)
        let engine = SearchEngine(terminal: terminal, lineCache: cache)

        terminal.feed(text: "Hello World Hello")

        #expect(engine.findNextWithSelection(term: "", cachedSearchTerm: nil, previousSelection: nil) == nil)
        #expect(engine.findNextWithSelection(term: "Hello", cachedSearchTerm: nil, previousSelection: nil) == SearchResult(term: "Hello", col: 0, row: 0, size: 5))

        let selection = SearchSelection(start: Position(col: 0, row: 0), end: Position(col: 5, row: 0))
        #expect(engine.findNextWithSelection(term: "Hello", cachedSearchTerm: "Hello", previousSelection: selection) == SearchResult(term: "Hello", col: 12, row: 0, size: 5))

        let selectionAtEnd = SearchSelection(start: Position(col: 12, row: 0), end: Position(col: 17, row: 0))
        #expect(engine.findNextWithSelection(term: "Hello", cachedSearchTerm: "Hello", previousSelection: selectionAtEnd) == SearchResult(term: "Hello", col: 0, row: 0, size: 5))
    }

    @Test func testSearchEngineFindPreviousWithSelection() {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)
        let engine = SearchEngine(terminal: terminal, lineCache: cache)

        terminal.feed(text: "Hello World Hello")

        #expect(engine.findPreviousWithSelection(term: "", cachedSearchTerm: nil, previousSelection: nil) == nil)
        #expect(engine.findPreviousWithSelection(term: "Hello", cachedSearchTerm: nil, previousSelection: nil) == SearchResult(term: "Hello", col: 12, row: 0, size: 5))

        let selectionAtEnd = SearchSelection(start: Position(col: 12, row: 0), end: Position(col: 17, row: 0))
        let previous = engine.findPreviousWithSelection(term: "Hello", cachedSearchTerm: "Hello", previousSelection: selectionAtEnd)
        #expect(previous != nil)
        #expect(previous?.row == 0)
    }

    /// A whole-word search passes over a match inside a longer word to the
    /// next one, either way.
    @Test func testSearchEngineWholeWordLooksPastPartWords() {
        let terminal = makeTerminal()
        let cache = SearchLineCache(terminal: terminal)
        let engine = SearchEngine(terminal: terminal, lineCache: cache)

        terminal.feed(text: "abc ab abd")

        let wholeWord = SearchOptions(wholeWord: true)
        #expect(engine.find(term: "ab", startRow: 0, startCol: 0, searchOptions: wholeWord) == SearchResult(term: "ab", col: 4, row: 0, size: 2))
        #expect(engine.findPreviousWithSelection(term: "ab", searchOptions: wholeWord, cachedSearchTerm: nil, previousSelection: nil) == SearchResult(term: "ab", col: 4, row: 0, size: 2))
    }

    // MARK: - SearchService

    @Test func testSearchServiceFindAllAndLimit() {
        let terminal = makeTerminal()
        let service = SearchService(terminal: terminal)

        terminal.feed(text: "Hello Hello Hello")

        let results = service.findAll(term: "Hello")
        #expect(results.count == 3)
        #expect(results[0].col == 0)
        #expect(results[1].col == 6)
        #expect(results[2].col == 12)

        let limited = service.findAll(term: "Hello", limit: 2)
        #expect(limited.count == 2)
    }

    /// The summary tells exactly `limit` matches from more than `limit`, and
    /// only numbers a current match that is among the counted ones.
    @Test func testSearchServiceMatchSummaryCapsAndLocates() {
        let terminal = makeTerminal()
        let service = SearchService(terminal: terminal)

        terminal.feed(text: "Hello Hello Hello")

        let second = Position(col: 6, row: 0)
        let third = Position(col: 12, row: 0)
        let exact = service.matchSummary(term: "Hello", options: SearchOptions(), limit: 3, current: second)
        #expect(exact.index == 2)
        #expect(exact.total == 3)
        #expect(!exact.capped)

        let capped = service.matchSummary(term: "Hello", options: SearchOptions(), limit: 2, current: third)
        #expect(capped.index == 0)
        #expect(capped.total == 2)
        #expect(capped.capped)

        // New content is counted again.
        let before = service.generation
        service.invalidate()
        terminal.feed(text: " Hello")
        #expect(service.generation != before)
        #expect(service.matchSummary(term: "Hello", options: SearchOptions(), limit: 10, current: nil).total == 4)
    }

    /// Every match of a line counts past a wide character that wrapped to
    /// the next row and left the row before it a cell short.
    @Test func testSearchServiceFindAllCountsEveryMatchPastAWrappedWideCharacter() {
        let terminal = makeTerminal(cols: 5, rows: 6)
        let service = SearchService(terminal: terminal)

        terminal.feed(text: "世ab世ab世ab")

        #expect(service.findAll(term: "ab").map(\.row) == [0, 1, 2])
    }

    /// A line wrapped over a thousand rows is searched once, in a loop. Each
    /// row searched the rest of its line again after recursing up to the
    /// line's start, so a miss took seconds, counting matches restarted that
    /// walk at each one, and a long line overflowed a thread's stack.
    @Test func testSearchOfALongWrappedLineIsOnePass() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24, scrollback: 10_000)
        let service = SearchService(terminal: terminal)
        let rows = 1_000

        terminal.feed(text: String(repeating: "needle" + String(repeating: "x", count: 74), count: rows) + "\r\n$ ")

        terminal.terminalLock.withLock {
#if DEBUG
            let logicalLines = (0..<terminal.displayBuffer.lines.count).filter {
                !terminal.displayBuffer.lines[$0].isWrapped
            }.count
            let visitsBefore = service.testingSearchRowVisits
#endif
            let matches = service.findAll(term: "needle")
            #expect(matches.count == rows)
            #expect(matches.last == SearchResult(term: "needle", col: 0, row: rows - 1, size: 6))
#if DEBUG
            let visitsAfterMatches = service.testingSearchRowVisits
            #expect(visitsAfterMatches - visitsBefore <= logicalLines)
#endif
            let miss = service.findNext(term: "haystack")
            #expect(miss == nil)
#if DEBUG
            let missVisits = service.testingSearchRowVisits - visitsAfterMatches
            #expect(missVisits > 0)
            #expect(missVisits <= logicalLines)
#endif
        }
    }

    // MARK: - Visible matches (highlight all matches)

    private func visible (_ terminal: Terminal, _ term: String, options: SearchOptions = SearchOptions(),
                          firstRow: Int = 0, rowCount: Int? = nil) -> [[Range<Int>]] {
        let service = SearchService(terminal: terminal)
        // No time limit: these tests are about the ranges.
        service.visibleMatchTimeLimit = 60_000_000_000
        return terminal.terminalLock.withLock {
            service.visibleMatches(term: term, options: options, firstRow: firstRow,
                                   rowCount: rowCount ?? terminal.rows) ?? []
        }
    }

    @Test func testVisibleMatchesFindsAllMatchesOnARow() {
        let terminal = makeTerminal(cols: 20, rows: 3)
        terminal.feed(text: "foo bar foo\r\nbaz foo")

        let rows = visible(terminal, "foo")
        #expect(rows.count == 3)
        #expect(rows[0] == [0..<3, 8..<11])
        #expect(rows[1] == [4..<7])
        #expect(rows[2] == [])
    }

    @Test func testVisibleMatchesMergesAdjacentRanges() {
        let terminal = makeTerminal(cols: 20, rows: 2)
        terminal.feed(text: "aaaa b aa")

        #expect(visible(terminal, "a")[0] == [0..<4, 7..<9])
        #expect(visible(terminal, "aa")[0] == [0..<4, 7..<9])
    }

    @Test func testVisibleMatchesSplitsAMatchAcrossAWrappedRow() {
        let terminal = makeTerminal(cols: 10, rows: 4)
        terminal.feed(text: "0123456hello")

        let rows = visible(terminal, "hello")
        #expect(rows[0] == [7..<10])
        #expect(rows[1] == [0..<2])
    }

    @Test func testVisibleMatchesReadsALogicalLineThatStartsAboveTheRows() {
        let terminal = makeTerminal(cols: 10, rows: 4)
        terminal.feed(text: "abcdefghijKLMNOPQRSTuvwxy")

        #expect(visible(terminal, "jK", options: SearchOptions(caseSensitive: true),
                        firstRow: 1, rowCount: 1) == [[0..<1]])
        #expect(visible(terminal, "Tuv", options: SearchOptions(caseSensitive: true),
                        firstRow: 1, rowCount: 1) == [[9..<10]])
        // A match that is fully on other rows gives no range.
        #expect(visible(terminal, "abc", firstRow: 1, rowCount: 1) == [[]])
        #expect(visible(terminal, "wxy", firstRow: 1, rowCount: 1) == [[]])
    }

    @Test func testVisibleMatchesUsesCellColumnsForWideCharacters() {
        let terminal = makeTerminal(cols: 20, rows: 2)
        terminal.feed(text: "世界 ok 世界")

        #expect(visible(terminal, "世界")[0] == [0..<4, 8..<12])
        #expect(visible(terminal, "ok")[0] == [5..<7])
    }

    @Test func testVisibleMatchesObeysTheOptions() {
        let terminal = makeTerminal(cols: 30, rows: 2)
        terminal.feed(text: "cat Cat concat 42 7")

        #expect(visible(terminal, "cat")[0] == [0..<3, 4..<7, 11..<14])
        #expect(visible(terminal, "cat", options: SearchOptions(caseSensitive: true))[0] == [0..<3, 11..<14])
        #expect(visible(terminal, "cat", options: SearchOptions(wholeWord: true))[0] == [0..<3, 4..<7])
        #expect(visible(terminal, "[0-9]+", options: SearchOptions(regex: true))[0] == [15..<17, 18..<19])
        #expect(visible(terminal, "[", options: SearchOptions(regex: true))[0] == [])
    }

    @Test func testVisibleMatchesHandlesRowsOutOfTheBuffer() {
        let terminal = makeTerminal(cols: 10, rows: 3)
        terminal.feed(text: "foo")

        #expect(visible(terminal, "foo", firstRow: 50, rowCount: 3) == [])
        #expect(visible(terminal, "", firstRow: 0, rowCount: 3) == [])
        #expect(visible(terminal, "foo", firstRow: 0, rowCount: 0) == [])
        // Rows after the end of the buffer are not in the result.
        #expect(visible(terminal, "foo", firstRow: 2, rowCount: 10) == [[]])
    }

    /// A logical line of 300 rows: "y", then only "x", then "y". The search
    /// reads only the rows near the visible rows. A regex anchor thus matches
    /// at a clip edge, where a search of the full line finds no match.
    @Test func testVisibleMatchesClipsALongLogicalLine() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 4, scrollback: 1_000)
        let service = SearchService(terminal: terminal)
        terminal.feed(text: "y" + String(repeating: "x", count: 2_998) + "y")
        let firstRow = 150
        let margin = SearchEngine.visibleMatchMargin
        let regex = SearchOptions(caseSensitive: true, regex: true)

        terminal.terminalLock.withLock {
            #expect(terminal.displayBuffer.lines.count == 300)
            let full = [0..<10]
#if DEBUG
            let before = service.testingVisibleRowsTranslated
#endif
            // Top clip edge: "^" matches at the first row of the window.
            #expect(service.findAll(term: "^x+", options: regex).isEmpty)
            #expect(service.visibleMatches(term: "^x+", options: regex, firstRow: firstRow, rowCount: 4)
                    == [full, full, full, full])
#if DEBUG
            #expect(service.testingVisibleRowsTranslated - before == 4 + 2 * margin)
#endif
            // Bottom clip edge: "$" matches at the last row of the window.
            #expect(service.findAll(term: "x+$", options: regex).isEmpty)
            #expect(service.visibleMatches(term: "x+$", options: regex, firstRow: firstRow, rowCount: 4)
                    == [full, full, full, full])
            // A match that crosses the two edges is shorter, but the visible
            // rows are the same as for the full match.
            #expect(service.visibleMatches(term: "x+", options: regex, firstRow: firstRow, rowCount: 4)
                    == [full, full, full, full])
            // Near the top of the buffer the window stops at the line start.
            #expect(service.visibleMatches(term: "^x+", options: regex, firstRow: 0, rowCount: 4)
                    == [[], [], [], []])
            #expect(service.visibleMatches(term: "^yx+", options: regex, firstRow: 0, rowCount: 2)
                    == [full, full])
        }
    }

    /// One pass on the line: the end of a match is not a line start or a
    /// word boundary for the next match.
    @Test func testRegexAnchorsSeeTheFullLine() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 4, scrollback: 10)
        let service = SearchService(terminal: terminal)
        terminal.feed(text: "foofoo foo")
        let regex = SearchOptions(caseSensitive: true, regex: true)

        terminal.terminalLock.withLock {
            #expect(service.visibleMatches(term: "^foo", options: regex, firstRow: 0, rowCount: 1) == [[0..<3]])
            #expect(service.findAll(term: "^foo", options: regex).map(\.col) == [0])
            #expect(service.visibleMatches(term: "\\bfoo", options: regex, firstRow: 0, rowCount: 1)
                    == [[0..<3, 7..<10]])
            #expect(service.findAll(term: "\\bfoo", options: regex).map(\.col) == [0, 7])
            #expect(service.visibleMatches(term: "(?<!o)foo", options: regex, firstRow: 0, rowCount: 1)
                    == [[0..<3, 7..<10]])
            // Find Next agrees: from the end of the first match, "^foo"
            // has no second match and the search goes back to the first.
            #expect(service.findNext(term: "^foo", options: regex)?.col == 0)
            #expect(service.findNext(term: "^foo", options: regex)?.col == 0)
        }
    }

    /// A search that uses more than the time limit gives nil, not a part
    /// of the matches. The limit also stops one regex match attempt that
    /// backtracks without end.
    @Test(.timeLimit(.minutes(1))) func testVisibleMatchesStopsAtTheTimeLimit() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 200, rows: 50, scrollback: 0)
        let service = SearchService(terminal: terminal)
        let line = String(repeating: "the quick e", count: 18)
        terminal.feed(text: Array(repeating: line, count: 50).joined(separator: "\r\n"))
        let regex = SearchOptions(caseSensitive: true, regex: true)

        terminal.terminalLock.withLock {
            // All cells match, and all rows get their range.
            service.visibleMatchTimeLimit = 10_000_000_000
            let all = service.visibleMatches(term: ".", options: regex, firstRow: 0, rowCount: 50)
            #expect(all == [[Range<Int>]](repeating: [0..<198], count: 50))

            service.visibleMatchTimeLimit = 0
            #expect(service.visibleMatches(term: ".", options: regex, firstRow: 0, rowCount: 50) == nil)
            #expect(service.visibleMatches(term: "e", options: SearchOptions(), firstRow: 0, rowCount: 50) == nil)

            // No match, and the number of attempts has no practical end.
            service.visibleMatchTimeLimit = 4_000_000
            let start = DispatchTime.now().uptimeNanoseconds
            #expect(service.visibleMatches(term: "(.*)*z", options: regex, firstRow: 0, rowCount: 50) == nil)
            #expect(DispatchTime.now().uptimeNanoseconds - start < 1_000_000_000)
        }
    }

    /// A regex find has a time limit also. A regex that backtracks without end
    /// gives no match, in the two directions, and does not block.
    @Test(.timeLimit(.minutes(1))) func testFindStopsAtTheTimeLimit() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 200, rows: 4, scrollback: 10)
        let service = SearchService(terminal: terminal)
        terminal.feed(text: String(repeating: "the quick e", count: 18) + "\r\nfoo")
        let regex = SearchOptions(caseSensitive: true, regex: true)

        terminal.terminalLock.withLock {
            service.findTimeLimit = 50_000_000
            let start = DispatchTime.now().uptimeNanoseconds
            #expect(service.findNext(term: "(.*)*z", options: regex) == nil)
            #expect(service.findPrevious(term: "(.*)*z", options: regex) == nil)
            #expect(service.findAll(term: "(.*)*z", options: regex).isEmpty)
            #expect(DispatchTime.now().uptimeNanoseconds - start < 2_000_000_000)
            // A plain-text find has no limit: it cannot run without end,
            // and a limit could hide a match in a large scrollback.
            service.findTimeLimit = 0
            #expect(service.findNext(term: "fo+", options: regex) == nil)
            let plain = SearchOptions(caseSensitive: true)
            #expect(service.findNext(term: "foo", options: plain)?.row == 1)
            #expect(service.findPrevious(term: "quick", options: plain)?.col == 191)
            #expect(service.findAll(term: "quick", options: plain).count == 18)
            // A find that is in time is not changed.
            service.findTimeLimit = 60_000_000_000
            #expect(service.findNext(term: "fo+", options: regex)?.row == 1)
            // The last "quick" of the row: 17 * 11 + 4.
            #expect(service.findPrevious(term: "qu\\w+", options: regex)?.col == 191)
        }
    }

    /// The find bar and the host each have a highlight pattern. The bar's
    /// pattern has priority, and a find with no owner changes none.
    @Test func testHighlightPatternsHaveOwners() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 4, scrollback: 10)
        let service = SearchService(terminal: terminal)
        terminal.feed(text: "foo bar foo")

        terminal.terminalLock.withLock {
            #expect(service.findNext(term: "foo", highlights: nil) != nil)
            #expect(service.activePattern == nil)
            #expect(service.findNext(term: "foo") != nil)
            #expect(service.activePattern?.term == "foo")
            // Find Next with no find bar: the host's term stays.
            #expect(service.findPrevious(term: "bar", highlights: nil) != nil)
            #expect(service.activePattern?.term == "foo")
            // The bar after the host: the bar's term shows, and when the bar
            // goes away the host's term shows again.
            #expect(service.findNext(term: "bar", highlights: .findBar) != nil)
            #expect(service.activePattern?.term == "bar")
            service.clearHighlightPattern(owner: .findBar)
            #expect(service.activePattern?.term == "foo")
            #expect(service.findNext(term: "bar", highlights: .findBar) != nil)
            service.reset(keepingHostHighlights: true)
            #expect(service.activePattern?.term == "foo")
            service.clearHighlightPattern()
            #expect(service.activePattern == nil)
        }
    }

    @Test func testInvalidateKeepsTheHighlightPattern() {
        let terminal = makeTerminal(cols: 20, rows: 2)
        let service = SearchService(terminal: terminal)
        terminal.feed(text: "foo foo")

        terminal.terminalLock.withLock {
            #expect(service.activePattern == nil)
            service.findNext(term: "foo", options: SearchOptions(wholeWord: true))
            #expect(service.activePattern?.term == "foo")
            #expect(service.activePattern?.options == SearchOptions(wholeWord: true))

            let generation = service.generation
            service.invalidate()
            #expect(service.generation != generation)
            #expect(service.activePattern?.term == "foo")

            // `invalidate()` removed the find position; set it again.
            #expect(service.findNext(term: "foo")?.col == 0)
            service.clearHighlightPattern()
            #expect(service.activePattern == nil)
            // The find state stays: the next find continues to the second match.
            #expect(service.findNext(term: "foo")?.col == 4)
            #expect(service.activePattern?.term == "foo")

            service.reset()
            #expect(service.activePattern == nil)
            service.findPrevious(term: "foo")
            #expect(service.activePattern?.term == "foo")
            service.findNext(term: "")
            #expect(service.activePattern == nil)
        }
    }

    @Test func testSearchServiceSelectionRange() {
        let terminal = makeTerminal(cols: 10, rows: 2)
        let service = SearchService(terminal: terminal)

        let result = SearchResult(term: "Hello", col: 8, row: 0, size: 4)
        let range = service.selectionRange(for: result)

        #expect(range.start == Position(col: 8, row: 0))
        #expect(range.end == Position(col: 2, row: 1))
    }

    @Test func testSearchServiceFindNextUpdatesLastResult() {
        let terminal = makeTerminal()
        let service = SearchService(terminal: terminal)

        terminal.feed(text: "Hello World")

        #expect(service.lastResult == nil)
        let result = service.findNext(term: "World")
        #expect(result == SearchResult(term: "World", col: 6, row: 0, size: 5))
        #expect(service.lastResult == result)

        _ = service.findNext(term: "")
        #expect(service.lastResult == nil)
    }
}
