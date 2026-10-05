#if !SWIFTTERM_EMBEDDED && (os(macOS) || os(iOS) || os(visionOS))
import Foundation
import Testing
@testable import SwiftTerm

@Suite(.serialized)
@MainActor
struct TerminalViewInputStateTests {
    @Test func copiesActiveModesAndCursorCells() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        view.resize(cols: 80, rows: 24)
        view.changeScrollback(123)
        view.feed(text: "\u{1B}[?1049h\u{1B}[?1h\u{1B}[?69h\u{1B}[3;20s$ 文件 doc")
        let state = try #require(view.terminalInputStateSnapshot())
        #expect(state.dimensions == TerminalDimensions(cols: 80, rows: 24))
        #expect(state.isAlternateBuffer)
        #expect(state.applicationCursor)
        #expect(state.marginLeft == 2)
        #expect(state.marginRight == 19)
        #expect(state.scrollback == 123)
        #expect(state.cursor.col == 10)
        #expect(state.cursorRow?.text == "$ 文件 doc")
        #expect(state.cursorRow?.cellWidths[2] == 2)
        view.resetToInitialState()
        let reset = try #require(view.terminalInputStateSnapshot())
        #expect(!reset.isAlternateBuffer)
        #expect(!reset.applicationCursor)
        #expect(reset.marginLeft == 0)
        #expect(reset.marginRight == 79)
    }

    @Test func staysLiveDuringSynchronizedOutput() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        view.resize(cols: 80, rows: 24)
        view.feed(text: "$ old\u{1B}[?2026h\u{1B}[?1049h\u{1B}[?1h\rlive")
        let state = try #require(view.terminalInputStateSnapshot())
        #expect(state.isAlternateBuffer)
        #expect(state.applicationCursor)
        #expect(state.cursorRow?.text == "live")
        #expect(state.cursor.col == 4)
        #expect(view.terminalStateSnapshot().visibleRows.first?.text == "live")
        view.feed(text: "\u{1B}[?2026l")
        #expect(view.terminalStateSnapshot().visibleRows.first?.text == "live")
    }

    @Test func cursorRowIsIndependentOfTheScrolledViewport() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        view.resize(cols: 80, rows: 4)
        view.feed(text: "$ old\r\n" + String(repeating: "line\r\n", count: 30) + "$ ls")
        view.scroll(toPosition: 0)
        let state = try #require(view.terminalInputStateSnapshot())
        #expect(state.cursorRow?.text == "$ ls")
        #expect(state.screenBaseRow + state.cursor.row - state.viewportRow >= state.dimensions.rows)
        #expect(view.terminalStateSnapshot().visibleRows.first?.text == "$ old")
    }
}
#endif
