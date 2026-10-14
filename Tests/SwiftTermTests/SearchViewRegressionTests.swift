#if !SWIFTTERM_EMBEDDED && (os(macOS) || os(iOS) || os(visionOS))
import Foundation
import Testing
@testable import SwiftTerm

@Suite(.serialized)
@MainActor
struct SearchViewRegressionTests {
    @Test("whole-word search skips embedded candidates in both directions", arguments: [false, true])
    func wholeWordCandidates(regex: Bool) {
        let terminal = makeTerminal("terror error error terror\r\n")
        let options = SearchOptions(regex: regex, wholeWord: true)
        #expect(terminal.findNext("error", options: options))
        #expect(terminal.searchMatchSummary("error", options: options).total == 2)
        #expect(terminal.searchMatchSummary("error", options: options).index == 1)
        #expect(terminal.findNext("error", options: options))
        #expect(terminal.searchMatchSummary("error", options: options).index == 2)
        terminal.clearSearch()
        #expect(terminal.findPrevious("error", options: options))
        #expect(terminal.searchMatchSummary("error", options: options).index == 2)
        #expect(terminal.findPrevious("error", options: options))
        #expect(terminal.searchMatchSummary("error", options: options).index == 1)
    }

    @Test("zero-length regex candidates do not mask selectable matches")
    func zeroLengthRegex() {
        let options = SearchOptions(regex: true)
        let terminal = makeTerminal("start error abc123\r\n")
        #expect(terminal.findNext("^|error", options: options))
        #expect(terminal.getSelection() == "error")
        #expect(terminal.searchMatchSummary("^|error", options: options).total == 1)
        terminal.clearSearch()
        #expect(terminal.findNext("\\d*", options: options))
        #expect(terminal.getSelection() == "123")
        terminal.clearSearch()
        #expect(terminal.findPrevious("error|$", options: options))
        #expect(terminal.getSelection() == "error")
        terminal.clearSearch()
        #expect(!terminal.findNext("^|$", options: options))
        #expect(!terminal.findPrevious("^|$", options: options))
        #expect(terminal.searchMatchSummary("^|$", options: options).total == 0)
    }

    @Test("wide wrapped matches retain their normalized selection through feed")
    func wrappedSelectionIndex() {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        terminal.resize(cols: 8, rows: 8)
        terminal.feed(text: "ab界界error\r\nab界界error\r\n")
        #expect(terminal.findNext("界界error"))
        #expect(terminal.findNext("界界error"))
        #expect(terminal.searchMatchSummary("界界error").index == 2)
        terminal.feed(text: "quiet\r\n")
        #expect(terminal.searchMatchSummary("界界error").index == 2)
        #expect(terminal.searchMatchSummary("界界error").total == 2)
    }

    @Test("a match ending at the last buffer cell retains its full text and index")
    func lastCellSelection() {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        terminal.resize(cols: 7, rows: 2)
        terminal.feed(text: "first\r\nxxerror")
        #expect(terminal.findNext("error"))
        #expect(terminal.getSelection() == "error")
        #expect(terminal.searchMatchSummary("error").index == 1)
        terminal.feed(text: "\u{1B}[1;1Hquiet")
        #expect(terminal.getSelection() == "error")
        #expect(terminal.searchMatchSummary("error").index == 1)
    }

    @Test("wide-character wrap padding does not skip matches during navigation", arguments: [false, true])
    func wideWrapPadding(regex: Bool) {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        terminal.resize(cols: 5, rows: 8)
        terminal.feed(text: "abcd界界")
        let options = SearchOptions(regex: regex)
        #expect(terminal.findNext("界", options: options))
        #expect(terminal.searchMatchSummary("界", options: options).total == 2)
        #expect(terminal.searchMatchSummary("界", options: options).index == 1)
        #expect(terminal.findNext("界", options: options))
        #expect(terminal.searchMatchSummary("界", options: options).index == 2)
        #expect(terminal.getSelection() == "界")
        #expect(terminal.findNext("界", options: options))
        #expect(terminal.searchMatchSummary("界", options: options).index == 1)
        #expect(terminal.findPrevious("界", options: options))
        #expect(terminal.searchMatchSummary("界", options: options).index == 2)
        #expect(terminal.findPrevious("界", options: options))
        #expect(terminal.searchMatchSummary("界", options: options).index == 1)
        terminal.feed(text: "\r\nquiet\r\n")
        #expect(terminal.searchMatchSummary("界", options: options).total == 2)
        #expect(terminal.searchMatchSummary("界", options: options).index == 1)
    }

    @Test("a row-end match keeps its index when output grows the buffer", arguments: [false, true])
    func lastCellSelectionSurvivesBufferGrowth(regex: Bool) {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        terminal.resize(cols: 7, rows: 2)
        let options = SearchOptions(regex: regex)
        terminal.feed(text: "first\r\nxxerror")
        #expect(terminal.findNext("error", options: options))
        #expect(terminal.getSelection() == "error")
        #expect(terminal.searchMatchSummary("error", options: options).index == 1)

        terminal.feed(text: "\r\nquiet")

        #expect(terminal.getSelection() == "error")
        #expect(terminal.searchMatchSummary("error", options: options).index == 1)
        #expect(terminal.searchMatchSummary("error", options: options).total == 1)
        #expect(terminal.findNext("error", options: options))
        #expect(terminal.getSelection() == "error")
        #expect(terminal.findPrevious("error", options: options))
        #expect(terminal.searchMatchSummary("error", options: options).index == 1)
    }

    @Test("search preserves a literal space before a wide-character wrap")
    func literalSpaceBeforeWideWrap() {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        terminal.resize(cols: 5, rows: 8)
        terminal.feed(text: "abcd 界界")
        #expect(terminal.findNext(" 界"))
        #expect(terminal.getSelection() == " 界")
        #expect(terminal.searchMatchSummary(" 界").total == 1)
        #expect(terminal.findPrevious(" 界"))
        #expect(terminal.getSelection() == " 界")
    }

    @Test("previous search wraps when the first match is on the final buffer row", arguments: [false, true])
    func previousFromFinalWrappedRow(regex: Bool) {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        terminal.resize(cols: 5, rows: 2)
        terminal.feed(text: "abcd界界")
        let options = SearchOptions(regex: regex)
        #expect(terminal.findNext("界", options: options))
        #expect(terminal.searchMatchSummary("界", options: options).index == 1)
        #expect(terminal.findPrevious("界", options: options))
        #expect(terminal.searchMatchSummary("界", options: options).index == 2)
        #expect(terminal.getSelection() == "界")
    }

    @Test("previous search skips a fully checked logical line after multiple wraps", arguments: [false, true])
    func previousAcrossMultipleWraps(regex: Bool) {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        terminal.resize(cols: 5, rows: 8)
        terminal.feed(text: "界\r\nabcdefghij界界\r\n界")
        let options = SearchOptions(regex: regex)
        #expect(terminal.findNext("界", options: options))
        #expect(terminal.searchMatchSummary("界", options: options).total == 4)
        #expect(terminal.findNext("界", options: options))
        #expect(terminal.searchMatchSummary("界", options: options).index == 2)
        #expect(terminal.findPrevious("界", options: options))
        #expect(terminal.searchMatchSummary("界", options: options).index == 1)
        #expect(terminal.getSelection() == "界")
    }

    private func makeTerminal(_ text: String) -> TerminalView {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        terminal.resize(cols: 80, rows: 24)
        terminal.feed(text: text)
        return terminal
    }
}
#endif
