import Foundation
import XCTest

@testable import SwiftTerm

/// Reflow to a narrower width must not read past the end of a source line.
/// The buffer state comes from terminal output only; the host or DECCOLM
/// then narrows the terminal. Run with --sanitize=address: in a release
/// build the out-of-range read is silent.
final class ReflowNarrowerBoundsTests: XCTestCase {
    private final class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private let delegate = Delegate()

    private func assertTrimmedLengths(_ terminal: Terminal,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let buffer = terminal.buffer
        for y in 0..<buffer.lines.count {
            XCTAssertLessThanOrEqual(buffer.lines[y].getTrimmedLength(),
                                     buffer.lines[y].count, file: file, line: line)
        }
    }

    private func feedAndNarrow(_ bytes: [UInt8], widths: [Int], rows: Int) {
        for cols in widths {
            let terminal = Terminal(delegate: delegate,
                                    options: TerminalOptions(cols: 80, rows: 24))
            terminal.feed(byteArray: bytes)
            terminal.resize(cols: cols, rows: rows)
            assertTrimmedLengths(terminal)
        }
    }

    // DECLRMM, DECSLRM with a left margin past the screen, CPL, a wide
    // character, LF. Then the host narrows the terminal.
    func testWideCharacterAtLastColumnDoesNotOverreadOnNarrowerReflow() {
        let bytes: [UInt8] = Array("\u{1b}[?69h\u{1b}[670s\u{1b}[F\u{1F600}\n".utf8)
        XCTAssertEqual(bytes.count, 20)
        feedAndNarrow(bytes, widths: [24], rows: 65)
        feedAndNarrow(bytes, widths: [79, 60, 40, 30, 20, 10], rows: 24)
    }

    // Output only, no host resize. CSI ? 40 h allows DECCOLM (it is off by
    // default on 1.x, and a DECCOLM switch resets it). CSI ? 3 h goes to 132
    // columns, the same wide character goes on the last column, and
    // CSI ? 3 l goes back to 80 columns: that resize reflows 132 -> 80.
    func testDECCOLMNarrowingDoesNotOverread() {
        var text = "\u{1b}[?40h\u{1b}[?3h\u{1b}[?40h"
        for i in 0..<5 {
            text += String(repeating: Character(String(i)), count: 132)
        }
        text += "\r\n\u{1b}[?69h\u{1b}[670s\u{1b}[F\u{1F600}\n"
        text += "\u{1b}[?3l"
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: 80, rows: 24))
        terminal.feed(byteArray: Array(text.utf8))
        XCTAssertEqual(terminal.cols, 80)
        assertTrimmedLengths(terminal)
    }

    func testTrimmedLengthDoesNotExceedLineCount() {
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: 80, rows: 24))
        terminal.feed(byteArray: Array("\u{1b}[?69h\u{1b}[670s\u{1b}[F\u{1F600}".utf8))
        assertTrimmedLengths(terminal)
    }

    /// The reflow guards: a line with a wide head on its last column (no
    /// cell for the tail) must not make reflow read past the line. Output
    /// cannot make this line now, so the test writes it directly.
    func testReflowGuardsWithWideHeadOnLastColumn() {
        for cols in [79, 60, 24, 10] {
            let terminal = Terminal(delegate: delegate,
                                    options: TerminalOptions(cols: 80, rows: 24))
            terminal.feed(text: "abc\r\n")
            let buffer = terminal.buffer
            let wide = CharData(attribute: CharData.defaultAttr,
                                scalar: UnicodeScalar(0x1F600)!, size: 2)
            buffer.lines[buffer.yBase][79] = wide
            XCTAssertEqual(buffer.lines[buffer.yBase].getTrimmedLength(), 80)
            terminal.resize(cols: cols, rows: 24)
        }
    }

    /// As xterm and Ghostty: DECSLRM with left >= right is ignored.
    func testDECSLRMIgnoresRegionNarrowerThanTwoColumns() {
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: 80, rows: 24))
        terminal.feed(text: "\u{1b}[?69h\u{1b}[5;20s")
        for request in ["670s", "5;5s", "20;5s", "80;100s", "80s"] {
            terminal.feed(text: "\u{1b}[\(request)")
            XCTAssertEqual(terminal.buffer.marginLeft, 4, request)
            XCTAssertEqual(terminal.buffer.marginRight, 19, request)
        }
        // Right is clamped to the screen, and 0 or missing means the screen.
        terminal.feed(text: "\u{1b}[79;200s")
        XCTAssertEqual(terminal.buffer.marginLeft, 78)
        XCTAssertEqual(terminal.buffer.marginRight, 79)
        terminal.feed(text: "\u{1b}[0;0s")
        XCTAssertEqual(terminal.buffer.marginLeft, 0)
        XCTAssertEqual(terminal.buffer.marginRight, 79)
        terminal.feed(text: "\u{1b}[3s")
        XCTAssertEqual(terminal.buffer.marginLeft, 2)
        XCTAssertEqual(terminal.buffer.marginRight, 79)
    }
}
