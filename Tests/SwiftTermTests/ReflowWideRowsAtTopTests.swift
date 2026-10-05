#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

/// Widening the terminal re-joins soft-wrapped lines (`Buffer.getLinesToRemove`). The length of the
/// first line of each wrapped group must be measured on that group, not on row 0 of the buffer:
/// when rows 0 and 1 were "null-padded line followed by a wide character", every re-joined line
/// lost its last cell of the first row.
final class ReflowWideRowsAtTopTests {
    private let queue = DispatchQueue(label: "SwiftTerm.ReflowWideRowsAtTopTests")

    private func rows(_ terminal: Terminal) -> [String] {
        (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            .filter { !$0.isEmpty }
    }

    @Test func testWideningKeepsEveryCharacterWhenTheFirstRowsHoldWideCharacters() {
        let headless = HeadlessTerminal(
            queue: queue,
            options: TerminalOptions(cols: 110, rows: 40, scrollback: 500)
        ) { _ in }
        let terminal = headless.terminal!
        let line = "Type /help for commands. Enter sends; Ctrl+J or Shift+Enter adds a new line."
        terminal.feed(text: "🚀 a\r\n📦 b\r\n\(line)\r\n\(line)\r\n")

        terminal.resize(cols: 63, rows: 40)
        terminal.resize(cols: 122, rows: 40)

        let text = rows(terminal)
        #expect(text.filter { $0 == line }.count == 2, "re-joined lines changed: \(text)")
    }
}
#endif
