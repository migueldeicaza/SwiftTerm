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

    @Test(arguments: [false, true])
    func disabledMarginsReportFullWidth(synchronizedOutput: Bool) throws {
        let enabled = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        let disabled = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        for view in [enabled, disabled] {
            view.resize(cols: 80, rows: 24)
            if synchronizedOutput {
                view.feed(text: "\u{1B}[?2026h\u{1B}[?1049h")
            }
            view.feed(text: "\u{1B}[?69h\u{1B}[3;5s\u{1B}[1;5H")
        }
        disabled.feed(text: "\u{1B}[?69l")

        let enabledState = try #require(enabled.terminalInputStateSnapshot())
        let disabledState = try #require(disabled.terminalInputStateSnapshot())
        #expect(enabledState.cursor == disabledState.cursor)
        #expect(enabledState.marginLeft == 2)
        #expect(enabledState.marginRight == 4)
        #expect(disabledState.marginLeft == 0)
        #expect(disabledState.marginRight == 79)

        enabled.feed(text: "ab")
        disabled.feed(text: "ab")
        #expect(enabled.terminalInputStateSnapshot()?.cursor == Position(col: 3, row: 1))
        #expect(disabled.terminalInputStateSnapshot()?.cursor == Position(col: 6, row: 0))
        // Copies taken before subsequent output must retain their old cursor.
        #expect(enabledState.cursor == Position(col: 4, row: 0))
        #expect(disabledState.cursor == Position(col: 4, row: 0))
        if synchronizedOutput {
            enabled.feed(text: "\u{1B}[?2026l")
            disabled.feed(text: "\u{1B}[?2026l")
        }
    }

    @Test func uiShutdownRetainsCopiedInputState() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        view.feed(text: "$ ls")
        let before = try #require(view.terminalInputStateSnapshot())

        #expect(view.updateUiClosed())
        #expect(view.updateUiClosed())

        let after = try #require(view.terminalInputStateSnapshot())
        #expect(after.dimensions == before.dimensions)
        #expect(after.cursor == before.cursor)
        #expect(after.cursorRow?.text == "$ ls")
        #expect(after.cursorRow?.cellWidths == before.cursorRow?.cellWidths)
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
