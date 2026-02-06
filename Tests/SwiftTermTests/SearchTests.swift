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
