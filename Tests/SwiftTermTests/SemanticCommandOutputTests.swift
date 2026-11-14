//
//  SemanticCommandOutputTests.swift
//
//  Covers the rule that finds the rows of one OSC 133 command's output,
//  which "Select Command Output" uses. Only written characters carry the
//  `.output` tag, so the rule must keep blank lines inside the output and
//  leave out the command's input rows and trailing blank lines.
//

import Testing

@testable import SwiftTerm

@Suite final class SemanticCommandOutputTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    private func makeTerminal(scrollback: Int = 100) -> Terminal {
        Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 10, scrollback: scrollback))
    }

    private let prompt = "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}"
    private let startOutput = "\u{1b}]133;C\u{7}"
    private let endCommand = "\u{1b}]133;D;0\u{7}"

    /// A prompt, the typed command and its Enter, then the output and `D`.
    private func command(_ input: String, output: String) -> String {
        prompt + input + "\r\n" + startOutput + output + endCommand
    }

    private func outputRows(_ terminal: Terminal, _ promptRow: Int? = nil) -> ClosedRange<Int>? {
        terminal.buffer.semanticCommandOutputRows(forPromptAt: promptRow)
    }

    @Test func outputRowsSitBetweenTwoPrompts() {
        let terminal = makeTerminal()
        // 0 banner, 1 prompt, 2-3 output, 4 prompt, 5 output, 6 idle prompt
        terminal.feed(text: "banner\r\n"
            + command("one", output: "a\r\nb\r\n")
            + command("two", output: "c\r\n")
            + prompt)
        #expect(outputRows(terminal, 1) == 2...3)
        #expect(outputRows(terminal, 4) == 5...5)
        #expect(outputRows(terminal, 6) == nil)
    }

    @Test func theNewestCommandWithOutputIsTheDefault() {
        let terminal = makeTerminal()
        // 0 prompt, 1 output, 2 prompt with no output, 3 idle prompt
        terminal.feed(text: command("ls", output: "x\r\n")
            + command("cd /", output: "")
            + prompt)
        #expect(outputRows(terminal, 2) == nil)
        #expect(outputRows(terminal) == 1...1)
    }

    @Test func blankLinesInsideTheOutputArePartOfIt() {
        let terminal = makeTerminal()
        // 0 prompt, 1 "a", 2 blank, 3 "b", 4 prompt
        terminal.feed(text: command("cmd", output: "a\r\n\r\nb\r\n") + prompt)
        #expect(outputRows(terminal, 0) == 1...3)
    }

    @Test func trailingBlankLinesAreNotPartOfTheOutput() {
        let terminal = makeTerminal()
        // 0 prompt, 1 "a", 2-3 blank, 4 prompt
        terminal.feed(text: command("cmd", output: "a\r\n\r\n\r\n") + prompt)
        #expect(terminal.buffer.semanticRowOpensPrompt(4))
        #expect(outputRows(terminal, 0) == 1...1)
    }

    @Test func theInputRowsOfAMultiLineCommandAreNotPartOfTheOutput() {
        let terminal = makeTerminal()
        // 0 prompt, 1 PS2 input row, 2-3 output, 4 prompt
        terminal.feed(text: prompt + "for i in 1 2\r\n"
            + "\u{1b}]133;A;k=s\u{7}> \u{1b}]133;B\u{7}do echo $i; done\r\n"
            + startOutput + "1\r\n2\r\n" + endCommand
            + prompt)
        #expect(!terminal.buffer.semanticRowOpensPrompt(1))
        #expect(outputRows(terminal, 0) == 2...3)
        #expect(outputRows(terminal) == 2...3)
    }

    @Test func aRunningCommandEndsAtItsLastOutputRow() {
        let terminal = makeTerminal()
        // 0 prompt, 1-2 output, cursor on row 3, no `D` yet
        terminal.feed(text: prompt + "make\r\n" + startOutput + "step 1\r\nstep 2\r\n")
        #expect(outputRows(terminal, 0) == 1...2)
        #expect(outputRows(terminal) == 1...2)
    }

    @Test func aRowThatDoesNotOpenAPromptHasNoOutput() {
        let terminal = makeTerminal()
        terminal.feed(text: command("ls", output: "x\r\n") + prompt)
        #expect(outputRows(terminal, 1) == nil)
        #expect(outputRows(terminal, -1) == nil)
        #expect(outputRows(terminal, 1_000) == nil)
    }

    @Test func aBufferWithoutPromptsHasNoOutput() {
        let terminal = makeTerminal()
        terminal.feed(text: "plain\r\noutput\r\n")
        #expect(outputRows(terminal) == nil)
    }

    @Test func aShellThatDoesNotSendCHasNoOutput() {
        let terminal = makeTerminal()
        // Without `C` or `D` after the input, "x" is still tagged as input.
        terminal.feed(text: prompt + "ls\r\nx\r\n" + prompt)
        #expect(outputRows(terminal, 0) == nil)
    }

    @Test func rowsStayCorrectAfterScrollbackIsTrimmed() {
        let terminal = makeTerminal(scrollback: 5)
        var text = ""
        for i in 0..<20 {
            text += command("c\(i)", output: "o\(i)\r\n")
        }
        terminal.feed(text: text + prompt)
        let buffer = terminal.buffer
        // The full buffer is 15 rows: the oldest commands are gone.
        #expect(buffer.lines.count == 15)
        guard let rows = outputRows(terminal) else {
            Issue.record("no output found")
            return
        }
        #expect(rows.count == 1)
        #expect(buffer.translateBufferLineToString(lineIndex: rows.lowerBound, trimRight: true) == "o19")
        #expect(buffer.semanticRowOpensPrompt(rows.lowerBound - 1))
    }
}
