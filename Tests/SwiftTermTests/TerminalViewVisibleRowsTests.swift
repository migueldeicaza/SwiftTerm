#if os(macOS)
import Foundation
import Testing
@testable import SwiftTerm

@Suite("TerminalView visible rows text")
struct TerminalViewVisibleRowsTests {
    /// The view parses a feed on its I/O thread, so read the copied rows until they settle.
    @MainActor
    private func rows(_ view: TerminalView, _ range: Range<Int>,
                      equal expected: [String], within seconds: TimeInterval = 2) -> [String] {
        let deadline = Date(timeIntervalSinceNow: seconds)
        var seen = view.visibleRowsText(range)
        while seen != expected, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            seen = view.visibleRowsText(range)
        }
        return seen
    }

    @MainActor
    @Test func viewReportsTheRowsAskedForAsTheSnapshotReadsThem() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 640, height: 320)))
        view.feed(text: "one\r\ntwo  \r\nthree")
        // Cells never written are dropped from the end; the spaces the application wrote stay.
        let expected = ["one", "two  ", "three"]
        #expect(rows(view, 0..<3, equal: expected) == expected)
        #expect(view.visibleRowsText(1..<2) == ["two  "])
        #expect(view.visibleRowsText(0..<3) == view.terminalStateSnapshot().visibleRows.prefix(3).map(\.text))
    }

    /// A wide glyph occupies two cells and reads as one character; a cursor jump leaves unwritten
    /// cells before the text, which read as spaces. Neither yields a NUL, and both match the
    /// snapshot exactly.
    @MainActor
    @Test func wideGlyphsAndCursorJumpsReadAsTheSnapshotReadsThem() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 640, height: 320)))
        view.feed(text: "界x\r\n\u{1b}[10Gx")
        let expected = ["界x", "         x"]
        let seen = rows(view, 0..<2, equal: expected)
        #expect(seen == expected)
        #expect(seen == view.terminalStateSnapshot().visibleRows.prefix(2).map(\.text))
        #expect(!seen.contains { $0.contains("\u{0}") })
    }

    @MainActor
    @Test func rangesAreClampedToTheScreen() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 640, height: 320)))
        let screen = view.terminalDimensions.rows
        #expect(screen > 0)
        #expect(view.visibleRowsText(0..<0).isEmpty)
        #expect(view.visibleRowsText(screen..<(screen + 5)).isEmpty)
        #expect(view.visibleRowsText((screen - 2)..<(screen + 10)).count == 2)
        #expect(view.visibleRowsText(0..<1000).count == screen)
    }
}
#endif
