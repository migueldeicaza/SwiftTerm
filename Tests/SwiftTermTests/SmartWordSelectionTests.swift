//
//  SmartWordSelectionTests.swift
//
//  What a double-click and a triple-click select: URLs, paths and quoted
//  strings whole, words as before, and whole soft-wrapped lines.
//

import Foundation
import Testing

@testable import SwiftTerm

final class SmartWordSelectionTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    /// The text a double-click at `col` of the first row of `text` selects.
    private func doubleClick(_ text: String, at col: Int, row: Int = 0, cols: Int = 60) -> String {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: text)
        selection.selectWordOrExpression(at: Position(col: col, row: row), in: terminal.buffer)
        return selection.getSelectedText()
    }

    /// The column of the first `needle` in `text`, plus `offset`.
    private func column(of needle: String, in text: String, offset: Int = 0) -> Int {
        text.distance(from: text.startIndex, to: text.range(of: needle)!.lowerBound) + offset
    }

    // MARK: URLs

    @Test(arguments: [
        ("see https://example.com/a?b=1&c=2#top for more", "https://example.com/a?b=1&c=2#top"),
        ("Visit https://example.com/path.", "https://example.com/path"),
        ("(see https://a.example/x)", "https://a.example/x"),
        ("https://en.wikipedia.org/wiki/Foo_(bar), then", "https://en.wikipedia.org/wiki/Foo_(bar)"),
        ("[docs](https://example.com/docs)", "https://example.com/docs"),
        ("go to www.example.com, now", "www.example.com"),
        ("ssh://git@github.com:22/org/repo.git;", "ssh://git@github.com:22/org/repo.git"),
        ("it said \"https://example.com/q\" twice", "https://example.com/q"),
        ("file:///Users/sam/notes.txt:", "file:///Users/sam/notes.txt"),
        ("https://example.com/redirect?next=https://other.example/path",
         "https://example.com/redirect?next=https://other.example/path"),
        ("https://a.test/?next=www.example.com.", "https://a.test/?next=www.example.com"),
    ])
    func doubleClickSelectsAWholeURL(text: String, url: String) {
        for offset in [0, 4, url.count / 2, url.count - 1] {
            #expect(doubleClick(text, at: column(of: url, in: text, offset: offset)) == url,
                    "offset \(offset)")
        }
    }

    @Test func aSentencePeriodIsNotPartOfTheURL() {
        let text = "Read https://example.com. Then go."
        #expect(doubleClick(text, at: column(of: "example", in: text)) == "https://example.com")
    }

    @Test func aURLAcrossASoftWrapSelectsWhole() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "open https://example.com/very/long/path now")
        #expect(terminal.buffer.lines[1].isWrapped)

        // Click on the part that wrapped onto the second row.
        selection.selectWordOrExpression(at: Position(col: 3, row: 1), in: terminal.buffer)

        #expect(selection.getSelectedText() == "https://example.com/very/long/path")
        #expect(selection.start == Position(col: 5, row: 0))
        #expect(selection.end.row == 1)
    }

    // MARK: Paths

    @Test(arguments: [
        ("open /usr/local/bin/swift now", "/usr/local/bin/swift"),
        ("cd ~/code/houston", "~/code/houston"),
        ("run ./scripts/build.sh --fast", "./scripts/build.sh"),
        ("ls ../SwiftTerm/Sources", "../SwiftTerm/Sources"),
        ("see Sources/SwiftTerm/Terminal.swift.", "Sources/SwiftTerm/Terminal.swift"),
        ("Sources/App/main.swift:120:5: error: oops", "Sources/App/main.swift:120:5"),
        ("at /tmp/x.log:42 (line)", "/tmp/x.log:42"),
        ("node_modules/@types/node/index.d.ts", "node_modules/@types/node/index.d.ts"),
        ("cd ../..", "../.."),
    ])
    func doubleClickSelectsAWholePath(text: String, path: String) {
        for offset in [0, path.count / 2, path.count - 1] {
            #expect(doubleClick(text, at: column(of: path, in: text, offset: offset)) == path,
                    "offset \(offset)")
        }
    }

    @Test func aPathAcrossASoftWrapSelectsWhole() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 16, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "edit Sources/SwiftTerm/SelectionService.swift:42 ok")

        selection.selectWordOrExpression(at: Position(col: 8, row: 2), in: terminal.buffer)

        #expect(selection.getSelectedText() == "Sources/SwiftTerm/SelectionService.swift:42")
    }

    // MARK: Quotes

    @Test func doubleClickOnAQuoteSelectsTheQuotedString() {
        let text = #"echo "hello world" 'it is' `uname -a` done"#
        let opening = column(of: "\"", in: text)
        let closing = column(of: "\" ", in: text)
        #expect(doubleClick(text, at: opening) == #""hello world""#)
        #expect(doubleClick(text, at: closing) == #""hello world""#)
        #expect(doubleClick(text, at: column(of: "'it", in: text)) == "'it is'")
        #expect(doubleClick(text, at: column(of: "' ", in: text)) == "'it is'")
        #expect(doubleClick(text, at: column(of: "`", in: text)) == "`uname -a`")
    }

    @Test func aSecondQuotedStringPairsItsOwnQuotes() {
        let text = #"a "one" b "two" c"#
        #expect(doubleClick(text, at: column(of: "\"two", in: text)) == #""two""#)
        #expect(doubleClick(text, at: column(of: "\" c", in: text)) == #""two""#)
    }

    @Test func escapedQuotesAndApostrophesDoNotDelimit() {
        let text = #"say "a \"b\" c" don't"#
        #expect(doubleClick(text, at: column(of: "\"a", in: text)) == #""a \"b\" c""#)
        // An apostrophe inside a word is not a quote.
        #expect(doubleClick(text, at: column(of: "'", in: text)) == "")
    }

    @Test(arguments: ["\"", "'", "`"])
    func evenBackslashesDoNotEscapeClosingQuotes(quote: String) {
        let quoted = quote + "a" + String(repeating: "\\", count: 2) + quote
        let text = "echo " + quoted + " next"
        for col in [5, 5 + quoted.count - 1] {
            #expect(doubleClick(text, at: col) == quoted)
        }
    }

    @Test(arguments: [1, 3])
    func oddBackslashesEscapeQuotes(backslashCount: Int) {
        let quoted = "\"a" + String(repeating: "\\", count: backslashCount) + "\"b\""
        let text = "echo " + quoted + " next"
        for col in [5, 5 + quoted.count - 1] {
            #expect(doubleClick(text, at: col) == quoted)
        }
    }

    @Test func aQuoteWithNoPartnerSelectsNothing() {
        #expect(doubleClick(#"say "unfinished"#, at: 4) == "")
    }

    @Test func aQuotedStringAcrossASoftWrapSelectsWhole() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: #"x = "a long string" ok"#)

        selection.selectWordOrExpression(at: Position(col: 4, row: 0), in: terminal.buffer)

        #expect(selection.getSelectedText() == #""a long string""#)
    }

    // MARK: Everything else keeps the word rules

    @Test(arguments: [
        ("hello world", 1, "hello"),
        ("foo.bar_baz-qux next", 2, "foo.bar_baz-qux"),
        ("say \"hello world\" now", 6, "hello"),
        ("at 12:30:45 today", 3, "12"),
        ("https is a word here", 2, "https"),
        ("version 1.2.3", 8, "1.2.3"),
        ("a   b", 2, "   "),
    ])
    func plainWordsStayWords(text: String, col: Int, expected: String) {
        #expect(doubleClick(text, at: col) == expected)
    }

    @Test func bracketsStillSelectBalancedExpressions() {
        #expect(doubleClick("call(a, [b, c]) end", at: 4) == "(a, [b, c])")
        #expect(doubleClick("call(a, [b, c]) end", at: 14) == "(a, [b, c])")
        #expect(doubleClick("x {a {b} c} y", at: 2) == "{a {b} c}")
    }

    @Test func aSlashAloneIsNotAPath() {
        #expect(doubleClick("cd / now", at: 3) == "")
    }

    @Test func doubleClickDragFromAURLExtendsByWords() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 60, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "go https://example.com/x now please")

        selection.selectWordOrExpression(at: Position(col: 10, row: 0), in: terminal.buffer)
        selection.dragExtend(bufferPosition: Position(col: 26, row: 0))

        #expect(selection.getSelectedText() == "https://example.com/x now")
    }

    // MARK: Triple-click

    @Test func tripleClickSelectsTheWholeSoftWrappedLine() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 6))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "first\r\nabcdefghijklmnopqrstuvwxy\r\nlast")

        // Rows 1, 2 and 3 hold the middle line.
        for row in 1...3 {
            selection.select(row: row)
            #expect(selection.start == Position(col: 0, row: 1), "row \(row)")
            #expect(selection.end == Position(col: 9, row: 3), "row \(row)")
            #expect(selection.getSelectedText() == "abcdefghijklmnopqrstuvwxy", "row \(row)")
        }

        selection.select(row: 0)
        #expect(selection.getSelectedText() == "first")
    }

    @Test func tripleClickCopiesAFullLastRow() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 5))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "0123456789abcdefghij\r\nnext")

        selection.select(row: 0)

        #expect(selection.getSelectedText() == "0123456789abcdefghij")
    }

    @Test func tripleClickDragSelectsWholeLogicalLines() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 8))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: "one\r\nabcdefghijklmno\r\ntwo\r\npqrstuvwxyz0123\r\nend")

        // Press on "one", drag onto the first row of the last wrapped line.
        selection.select(row: 0)
        selection.dragExtend(bufferPosition: Position(col: 2, row: 4))

        #expect(selection.start == Position(col: 0, row: 0))
        #expect(selection.end == Position(col: 9, row: 5))
        #expect(selection.getSelectedText() == "one\nabcdefghijklmno\ntwo\npqrstuvwxyz0123")

        // Back up into the first wrapped line: it is still whole.
        selection.dragExtend(bufferPosition: Position(col: 0, row: 2))
        #expect(selection.end == Position(col: 9, row: 2))
    }
}
