//
//  ReflowTests.swift
//
//
//  Created by Miguel de Icaza on 4/17/20.
//
#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

/// Helper to create a terminal with direct buffer access for reflow tests.
/// Uses a large scrollback by default so reflow has room to work.
private func makeTerminal(cols: Int, rows: Int, scrollback: Int = 500, reflowCursorLine: Bool = false) -> Terminal {
    let options = TerminalOptions(cols: cols, rows: rows, scrollback: scrollback, reflowCursorLine: reflowCursorLine)
    let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: options) { _ in }
    return h.terminal!
}

/// Helper to get the text content of a buffer line, trimming trailing spaces.
private func lineText(_ t: Terminal, _ row: Int, trimRight: Bool = true) -> String {
    return t.buffer.lines[row].translateToString(trimRight: trimRight)
}

/// Helper to set a single ASCII character into a buffer line at a given column.
private func setChar(_ line: BufferLine, col: Int, char: Character) {
    let code = Int32(char.asciiValue!)
    line[col] = CharData(attribute: CharData.defaultAttr, code: code, size: 1)
}

/// Helper to fill a buffer line with ASCII characters from a string.
private func fillLine(_ line: BufferLine, _ text: String) {
    for (i, ch) in text.enumerated() {
        setChar(line, col: i, char: ch)
    }
}

final class ReflowTests {

    @Test func testDoesNotCrashWhenReflowingToTinyWidth() {
        let options = TerminalOptions(cols: 10, rows: 10, scrollback: 1)
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: options) { _ in }

        let t = h.terminal!

        t.feed(text: "1234567890\r\n")
        t.feed(text: "ABCDEFGH\r\n")
        t.feed(text: "abcdefghijklmnopqrstxxx\r\n")
        t.feed(text: "\r\n")

        // if we resize to a small column width, content is pushed back up and out the top
        // of the buffer. Ensure that this does not crash
        t.resize(cols: 3, rows: 10)
        #expect(Bool(true))
    }

    // MARK: - Basic reflow tests (ported from xterm.js)

    @Test func testShouldNotWrapEmptyLines() {
        let t = makeTerminal(cols: 80, rows: 10)
        #expect(t.buffer.lines.count == 10)
        t.resize(cols: 75, rows: 10)
        #expect(t.buffer.lines.count == 10)
    }

    @Test func testShouldShrinkRowLength() {
        let t = makeTerminal(cols: 80, rows: 10)
        t.resize(cols: 5, rows: 10)
        #expect(t.buffer.lines.count == 10)
        for i in 0..<10 {
            #expect(t.buffer.lines[i].count == 5)
        }
    }

    @Test func testWrapAndUnwrapLines() {
        // Start with 6-col terminal, put "abcdef" on first line, cursor on row 1
        let t = makeTerminal(cols: 6, rows: 10)
        let firstLine = t.buffer.lines[0]
        fillLine(firstLine, "abcdef")
        t.buffer.y = 1

        #expect(lineText(t, 0) == "abcdef")

        // Shrink to 2 cols: "abcdef" wraps into 3 lines
        t.resize(cols: 2, rows: 10)
        #expect(t.buffer.lines.count == 10)
        #expect(lineText(t, 0) == "ab")
        #expect(lineText(t, 1) == "cd")
        #expect(lineText(t, 2) == "ef")
        for i in 3..<10 {
            #expect(lineText(t, i) == "")
        }

        // Expand back to 6 cols: should unwrap into original single line
        t.resize(cols: 6, rows: 10)
        #expect(t.buffer.lines.count == 10)
        #expect(lineText(t, 0) == "abcdef")
        for i in 1..<10 {
            #expect(lineText(t, i) == "")
        }
    }

    @Test func testShouldRemoveCorrectAmountOfRowsWhenReflowingLarger() {
        // Regression test: successive wrapped lines getting 3+ lines removed on reflow
        let t = makeTerminal(cols: 10, rows: 10)
        t.buffer.y = 2
        fillLine(t.buffer.lines[0], "abcdefghij")
        fillLine(t.buffer.lines[1], "0123456789")

        #expect(lineText(t, 0) == "abcdefghij")
        #expect(lineText(t, 1) == "0123456789")

        // Shrink to 2 cols
        t.resize(cols: 2, rows: 10)
        #expect(t.buffer.lines.count >= 11)
        #expect(lineText(t, 0) == "ab")
        #expect(lineText(t, 1) == "cd")
        #expect(lineText(t, 2) == "ef")
        #expect(lineText(t, 3) == "gh")
        #expect(lineText(t, 4) == "ij")
        #expect(lineText(t, 5) == "01")
        #expect(lineText(t, 6) == "23")
        #expect(lineText(t, 7) == "45")
        #expect(lineText(t, 8) == "67")
        #expect(lineText(t, 9) == "89")

        // Expand back to 10 cols: should recombine
        t.resize(cols: 10, rows: 10)
        #expect(lineText(t, 0) == "abcdefghij")
        #expect(lineText(t, 1) == "0123456789")
        for i in 2..<10 {
            #expect(lineText(t, i) == "")
        }
    }

    @Test func testShouldDiscardWrappedLinesThatGoOutOfScrollback() {
        let t = makeTerminal(cols: 10, rows: 5, scrollback: 1)
        let line = t.buffer.lines[3]
        fillLine(line, "abcdefghij")
        t.buffer.y = 4

        #expect(t.buffer.lines.count == 5)

        // Shrink to 2 cols: "abcdefghij" becomes 5 wrapped lines
        t.resize(cols: 2, rows: 5)
        #expect(t.buffer.y == 4)
        #expect(t.buffer.yBase == 1)
        #expect(t.buffer.lines.count == 6)
        #expect(lineText(t, 0) == "ab")
        #expect(lineText(t, 1) == "cd")
        #expect(lineText(t, 2) == "ef")
        #expect(lineText(t, 3) == "gh")
        #expect(lineText(t, 4) == "ij")

        // Expand back to 10 cols: content is recovered
        t.resize(cols: 10, rows: 5)
        #expect(t.buffer.lines.count == 5)
        #expect(lineText(t, 0) == "abcdefghij")
    }

    // MARK: - reflowSmaller viewport tests

    @Test func testReflowSmallerViewportNotYetFilled() {
        // Setup: 4-col terminal with 3 lines of content, cursor at row 3
        let t = makeTerminal(cols: 4, rows: 10)
        fillLine(t.buffer.lines[0], "abcd")
        fillLine(t.buffer.lines[1], "efgh")
        t.buffer.lines[1].isWrapped = true
        fillLine(t.buffer.lines[2], "ijkl")

        t.buffer.y = 3

        // Shrink to 2 cols
        t.resize(cols: 2, rows: 10)

        #expect(t.buffer.y == 6)
        #expect(t.buffer.yDisp == 0)
        #expect(t.buffer.yBase == 0)
        #expect(t.buffer.lines.count == 10)
        #expect(lineText(t, 0) == "ab")
        #expect(lineText(t, 1) == "cd")
        #expect(lineText(t, 2) == "ef")
        #expect(lineText(t, 3) == "gh")
        #expect(lineText(t, 4) == "ij")
        #expect(lineText(t, 5) == "kl")

        // Check isWrapped markers
        // Lines 0 and 1 ("abcdefgh") reflow to lines 0-3, so lines 1,2,3 are wrapped
        // Line 2 ("ijkl") reflows to lines 4-5, so line 5 is wrapped
        #expect(t.buffer.lines[0].isWrapped == false)
        #expect(t.buffer.lines[1].isWrapped == true)
        #expect(t.buffer.lines[2].isWrapped == true)
        #expect(t.buffer.lines[3].isWrapped == true)
        #expect(t.buffer.lines[4].isWrapped == false)
        #expect(t.buffer.lines[5].isWrapped == true)
    }

    @Test func testReflowSmallerViewportFilledYbaseZero() {
        let t = makeTerminal(cols: 4, rows: 10)
        fillLine(t.buffer.lines[0], "abcd")
        fillLine(t.buffer.lines[1], "efgh")
        t.buffer.lines[1].isWrapped = true
        fillLine(t.buffer.lines[2], "ijkl")

        t.buffer.y = 9

        // Shrink to 2 cols
        t.resize(cols: 2, rows: 10)

        #expect(t.buffer.y == 9)
        #expect(t.buffer.yBase == 3)
        #expect(t.buffer.lines.count == 13)
        #expect(lineText(t, 0) == "ab")
        #expect(lineText(t, 1) == "cd")
        #expect(lineText(t, 2) == "ef")
        #expect(lineText(t, 3) == "gh")
        #expect(lineText(t, 4) == "ij")
        #expect(lineText(t, 5) == "kl")
    }

    // MARK: - reflowLarger viewport tests

    @Test func testReflowLargerViewportNotYetFilled() {
        // Start at 2 cols with wrapped content, then expand to 4
        let t = makeTerminal(cols: 4, rows: 10)
        fillLine(t.buffer.lines[0], "abcd")
        fillLine(t.buffer.lines[1], "efgh")
        t.buffer.lines[1].isWrapped = true
        fillLine(t.buffer.lines[2], "ijkl")

        t.buffer.y = 3
        // First shrink to 2 to create wrapped state
        t.resize(cols: 2, rows: 10)
        #expect(t.buffer.y == 6)

        // Now expand back to 4
        t.resize(cols: 4, rows: 10)
        #expect(t.buffer.y == 3)
        #expect(t.buffer.yDisp == 0)
        #expect(t.buffer.yBase == 0)
        #expect(t.buffer.lines.count == 10)
        #expect(lineText(t, 0) == "abcd")
        #expect(lineText(t, 1) == "efgh")
        #expect(lineText(t, 2) == "ijkl")
        for i in 3..<10 {
            #expect(lineText(t, i) == "")
        }
    }

    @Test func testReflowLargerViewportFilledWithScrollback() {
        let t = makeTerminal(cols: 4, rows: 10)
        fillLine(t.buffer.lines[0], "abcd")
        fillLine(t.buffer.lines[1], "efgh")
        t.buffer.lines[1].isWrapped = true
        fillLine(t.buffer.lines[2], "ijkl")

        t.buffer.y = 9
        t.resize(cols: 2, rows: 10)

        // After shrink, yBase > 0 since viewport was full
        let yBaseAfterShrink = t.buffer.yBase

        // Now expand back to 4
        t.resize(cols: 4, rows: 10)
        // Content should be recombined
        // Find where content starts (may be offset by scrollback)
        var contentStart = -1
        for i in 0..<t.buffer.lines.count {
            if lineText(t, i) == "abcd" {
                contentStart = i
                break
            }
        }
        #expect(contentStart >= 0)
        if contentStart >= 0 {
            #expect(lineText(t, contentStart) == "abcd")
            #expect(lineText(t, contentStart + 1) == "efgh")
            #expect(lineText(t, contentStart + 2) == "ijkl")
        }
    }

    // MARK: - Cursor line reflow with reflowCursorLine: true

    @Test func testCursorLineIsReflowedNarrower() {
        // With reflowCursorLine: true, the cursor line should be reflowed like any other line.
        let t = makeTerminal(cols: 10, rows: 10, reflowCursorLine: true)
        t.feed(text: "% 12345")

        // Shrink to 6 cols: "% 12345" (7 chars) should wrap into 2 lines
        t.resize(cols: 6, rows: 10)

        #expect(lineText(t, 0) == "% 1234")
        #expect(lineText(t, 1) == "5")
        #expect(t.buffer.lines[1].isWrapped == true)
        // No duplicate of the first line
        #expect(lineText(t, 2) == "")
    }

    @Test func testCursorLineReflowRoundTrip() {
        // Verify no orphan lines remain after narrowing then widening
        let t = makeTerminal(cols: 80, rows: 10, reflowCursorLine: true)
        t.feed(text: "% 12345")

        t.resize(cols: 6, rows: 10)
        #expect(lineText(t, 0) == "% 1234")
        #expect(lineText(t, 1) == "5")

        t.resize(cols: 80, rows: 10)
        #expect(lineText(t, 0) == "% 12345")
        #expect(lineText(t, 1) == "")
    }

    @Test func testCursorLineReflowPreservesAllContent() {
        let t = makeTerminal(cols: 20, rows: 10, reflowCursorLine: true)
        t.feed(text: "abcdefghijklmnopqrst")  // exactly 20 chars

        t.resize(cols: 5, rows: 10)
        #expect(lineText(t, 0) == "abcde")
        #expect(lineText(t, 1) == "fghij")
        #expect(lineText(t, 2) == "klmno")
        #expect(lineText(t, 3) == "pqrst")

        t.resize(cols: 20, rows: 10)
        #expect(lineText(t, 0) == "abcdefghijklmnopqrst")
        #expect(lineText(t, 1) == "")
    }

    @Test func testMultipleLinesWithCursorReflow() {
        let t = makeTerminal(cols: 10, rows: 10, reflowCursorLine: true)
        t.feed(text: "1234567890")
        t.feed(text: "\r\n")
        t.feed(text: "abcdefghij")

        let contentBefore = (0..<5).map { lineText(t, $0) }

        t.resize(cols: 5, rows: 10)
        t.resize(cols: 10, rows: 10)

        let contentAfter = (0..<5).map { lineText(t, $0) }
        #expect(contentBefore == contentAfter)
    }

    @Test func testReflowNarrowerDoesNotDropReflowedBottomLines() {
        let t = makeTerminal(cols: 6, rows: 5, reflowCursorLine: true)
        fillLine(t.buffer.lines[3], "123456")
        fillLine(t.buffer.lines[4], "abcdef")
        t.buffer.y = 0

        t.resize(cols: 3, rows: 5)

        let narrowed = (0..<t.buffer.lines.count)
            .map { lineText(t, $0) }
            .filter { !$0.isEmpty }
        #expect(narrowed.contains("123"))
        #expect(narrowed.contains("456"))
        #expect(narrowed.contains("abc"))
        #expect(narrowed.contains("def"))

        t.resize(cols: 6, rows: 5)

        let widened = (0..<t.buffer.lines.count)
            .map { lineText(t, $0) }
            .filter { !$0.isEmpty }
        #expect(widened.contains("123456"))
        #expect(widened.contains("abcdef"))
    }

    // MARK: - Default behavior (reflowCursorLine: false) skips cursor line

    @Test func testDefaultSkipsCursorLineOnNarrower() {
        // By default (reflowCursorLine: false), cursor line is skipped
        let t = makeTerminal(cols: 10, rows: 10)
        t.feed(text: "% 12345")

        // Shrink to 6 cols: cursor line should be SKIPPED
        t.resize(cols: 6, rows: 10)

        // The cursor line is not reflowed; content is truncated to newCols
        #expect(lineText(t, 0) == "% 1234")
        // No wrapped continuation line created
        #expect(t.buffer.lines[1].isWrapped == false)
    }

    // MARK: - Post-reflow cursor invariant

    @Test func testCursorPositionInvariantAfterReflow() {
        let t = makeTerminal(cols: 80, rows: 10, reflowCursorLine: true)
        t.feed(text: "hello world this is a test line")
        t.buffer.y = 5

        t.resize(cols: 5, rows: 10)

        #expect(t.buffer.yBase + t.buffer.y < t.buffer.lines.count)
        #expect(t.buffer.y >= 0)
    }

    @Test func testReflowNarrowerThenWiderWithScrollback() {
        let t = makeTerminal(cols: 10, rows: 5, scrollback: 10, reflowCursorLine: true)

        for i in 0..<8 {
            t.feed(text: "line\(i)-----\r\n")
        }

        t.resize(cols: 5, rows: 5)

        #expect(t.buffer.yBase + t.buffer.y < t.buffer.lines.count)
        #expect(t.buffer.y >= 0)
        #expect(t.buffer.y < 5)

        t.resize(cols: 10, rows: 5)

        #expect(t.buffer.yBase + t.buffer.y < t.buffer.lines.count)
        #expect(t.buffer.y >= 0)
    }
}
#endif
