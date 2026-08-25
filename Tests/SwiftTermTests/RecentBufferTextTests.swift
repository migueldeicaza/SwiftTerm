#if os(macOS)
import Foundation
import XCTest

@testable import SwiftTerm

final class RecentBufferTextTests: XCTestCase {
    private let queue = DispatchQueue(label: "SwiftTerm.RecentBufferTextTests")

    private func terminal(
        cols: Int = 80,
        rows: Int = 24,
        scrollback: Int = 100
    ) -> Terminal {
        HeadlessTerminal(
            queue: queue,
            options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback)
        ) { _ in }.terminal
    }

    private func feedLines(_ terminal: Terminal, _ range: ClosedRange<Int>) {
        for index in range {
            terminal.feed(text: "line-\(index)\r\n")
        }
    }

    func testJoinsSoftWrapsAndPreservesHardBreaks() {
        let terminal = terminal(cols: 12, rows: 8)
        let path = "/tmp/a-very-long-render-name.png"
        terminal.feed(text: path + "\r\nnext")

        let text = terminal.getRecentLogicalBufferText(maximumUTF8Bytes: 4_096)

        XCTAssertTrue(text.contains(path))
        XCTAssertTrue(text.contains("\nnext"))
    }

    func testOmitsAnOversizedPartialLogicalLine() {
        let terminal = terminal(cols: 8, rows: 6)
        terminal.feed(text: "/tmp/this-logical-line-is-larger-than-the-budget.png")

        let text = terminal.getRecentLogicalBufferText(maximumUTF8Bytes: 16)

        XCTAssertLessThanOrEqual(text.utf8.count, 16)
        XCTAssertFalse(text.contains(".png"))
        XCTAssertFalse(text.contains("budget"))
    }

    func testIncrementalReadSkipsStableScrollback() {
        let terminal = terminal(cols: 40, rows: 5, scrollback: 2_000)
        feedLines(terminal, 1...300)
        let first = terminal.getRecentLogicalBufferText(
            maximumUTF8Bytes: 256 * 1024,
            sinceAbsoluteRow: 0)

        feedLines(terminal, 301...301)
        let second = terminal.getRecentLogicalBufferText(
            maximumUTF8Bytes: 256 * 1024,
            sinceAbsoluteRow: first.nextAbsoluteRow)

        XCTAssertTrue(second.text.contains("line-301"))
        XCTAssertFalse(second.text.contains("line-100"))
        XCTAssertLessThanOrEqual(
            second.text.split(separator: "\n", omittingEmptySubsequences: false).count,
            8)
    }

    func testIncrementalReadAlwaysIncludesCurrentScreen() {
        let terminal = terminal(cols: 40, rows: 5, scrollback: 2_000)
        feedLines(terminal, 1...300)
        let first = terminal.getRecentLogicalBufferText(
            maximumUTF8Bytes: 256 * 1024,
            sinceAbsoluteRow: 0)

        terminal.feed(text: "\u{1b}[H/tmp/painted-in-place.png")
        let second = terminal.getRecentLogicalBufferText(
            maximumUTF8Bytes: 256 * 1024,
            sinceAbsoluteRow: first.nextAbsoluteRow)

        XCTAssertTrue(second.text.contains("/tmp/painted-in-place.png"))
    }

    func testCursorPastCurrentBufferReadsTheRetainedWindow() {
        let terminal = terminal(cols: 40, rows: 5, scrollback: 2_000)
        feedLines(terminal, 1...300)

        let read = terminal.getRecentLogicalBufferText(
            maximumUTF8Bytes: 256 * 1024,
            sinceAbsoluteRow: 10_000_000)

        XCTAssertTrue(read.text.contains("line-1\n"))
    }

    func testCursorAdvancesByProducedRows() {
        let terminal = terminal(cols: 40, rows: 5, scrollback: 2_000)
        feedLines(terminal, 1...10)
        let first = terminal.getRecentLogicalBufferText(
            maximumUTF8Bytes: 256 * 1024,
            sinceAbsoluteRow: 0)

        feedLines(terminal, 11...13)
        let second = terminal.getRecentLogicalBufferText(
            maximumUTF8Bytes: 256 * 1024,
            sinceAbsoluteRow: first.nextAbsoluteRow)

        XCTAssertEqual(second.nextAbsoluteRow - first.nextAbsoluteRow, 3)
    }
}
#endif
