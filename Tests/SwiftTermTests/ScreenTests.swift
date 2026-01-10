import Testing
@testable import SwiftTerm

final class ScreenTests {
    private func bufferLineText(_ buffer: Buffer, lineIndex: Int, terminal: Terminal? = nil) -> String {
        let characterProvider: ((CharData) -> Character)?
        if let terminal {
            characterProvider = { terminal.getCharacter(for: $0) }
        } else {
            characterProvider = nil
        }
        return buffer.translateBufferLineToString(
            lineIndex: lineIndex,
            trimRight: true,
            startCol: 0,
            endCol: -1,
            skipNullCellsFollowingWide: true,
            characterProvider: characterProvider
        ).replacingOccurrences(of: "\u{0}", with: " ")
    }

    @Test func testScrollbackStoresLines() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 2, scrollback: 10)
        terminal.feed(text: "hello\r\nworld\r\ntest")

        #expect(terminal.buffer.yBase == 1)
        #expect(terminal.buffer.yDisp == terminal.buffer.yBase)
        #expect(bufferLineText(terminal.buffer, lineIndex: 0) == "hello")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "world")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "test")
    }

    @Test func testViewportDoesNotFollowWhenUserScrolling() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 2, scrollback: 10)
        terminal.feed(text: "1\r\n2\r\n3\r\n4\r\n")

        #expect(terminal.buffer.yBase == 3)
        #expect(terminal.buffer.yDisp == terminal.buffer.yBase)

        terminal.userScrolling = true
        terminal.setViewYDisp(0)
        terminal.feed(text: "5\r\n")

        #expect(terminal.buffer.yBase == 4)
        #expect(terminal.buffer.yDisp == 0)
    }

    @Test func testNoScrollbackDropsLines() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 2, scrollback: 10)
        terminal.changeHistorySize(nil)
        terminal.feed(text: "hello\r\nworld\r\ntest")

        #expect(terminal.buffer.yBase == 0)
        #expect(bufferLineText(terminal.buffer, lineIndex: 0) == "world")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "world")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "test")
    }

    @Test func testSingleRowScrollNoScrollback() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1, scrollback: 0)
        terminal.feed(text: "1ABCD\r\n")

        #expect(terminal.buffer.yBase == 0)
        #expect(terminal.buffer.yDisp == 0)
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "")
    }

    @Test func testSingleRowScrollWithScrollback() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1, scrollback: 1)
        terminal.feed(text: "1ABCD\r\n")

        #expect(terminal.buffer.yBase == 1)
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "")

        terminal.userScrolling = true
        terminal.setViewYDisp(0)
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "1ABCD")
    }

    @Test func testUserScrollingAdjustsOnTrim() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 2, scrollback: 1)
        terminal.feed(text: "1\r\n2\r\n3\r\n")

        #expect(terminal.buffer.yBase == 1)
        terminal.userScrolling = true
        terminal.setViewYDisp(1)
        terminal.feed(text: "4\r\n")

        #expect(terminal.buffer.yDisp == 0)
    }

    @Test func testResizeReflowsWithScrollback() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 3, scrollback: 10)
        terminal.feed(text: "helloworld\r\nX")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "hello")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "world")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "X")

        terminal.resize(cols: 10, rows: 3)

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "helloworld")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "X")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "")
    }

    @Test func testResizeNarrowerReflowsWithScrollback() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 3, scrollback: 10)
        terminal.feed(text: "helloworld\r\nX")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "helloworld")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "X")

        terminal.resize(cols: 5, rows: 3)

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "hello")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "world")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "X")
    }

    @Test func testResizeWiderReflowsMultipleWrappedLines() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 4, rows: 4, scrollback: 10)
        terminal.feed(text: "abcdefghij\r\nX")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "abcd")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "efgh")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "ij")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 3, equals: "X")

        terminal.resize(cols: 10, rows: 4)

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "abcdefghij")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "X")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 3, equals: "")
    }

    @Test func testReadWriteSingleLine() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24, scrollback: 10)
        terminal.feed(text: "hello, world")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "hello, world")
        #expect(terminal.buffer.yBase == 0)
    }

    @Test func testReadWriteNewline() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24, scrollback: 10)
        terminal.feed(text: "hello\r\nworld")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "hello")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "world")
    }

    @Test func testNoScrollbackLargeDropsOldLines() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 2, scrollback: 0)

        for i in 0..<1_000 {
            terminal.feed(text: "\(i)\r\n")
        }
        terminal.feed(text: "1000")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "999")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "1000")
    }

    @Test func testResizeNoReflowWithoutScrollback() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 2, scrollback: 0)
        terminal.feed(text: "helloworld")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "hello")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "world")

        terminal.resize(cols: 10, rows: 2)

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "hello")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "world")
    }
}
