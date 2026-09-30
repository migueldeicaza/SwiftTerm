import XCTest
@testable import SwiftTerm

final class PortableSelectionTests: XCTestCase, TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
    private var notified: [(Position, Position)] = []
    private var watched: SelectionService?
    func selectionChanged(source: Terminal) {
        if let watched { notified.append((watched.start, watched.end)) }
    }
    private func makeTerminal(cols: Int = 10, rows: Int = 3, scrollback: Int = 10)
        -> (Terminal, SelectionService) {
        let terminal = Terminal(delegate: self,
            options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
        return (terminal, SelectionService(terminal: terminal, exclusiveEnd: true))
    }

    private func feed(_ text: String, into terminal: Terminal, selection: SelectionService) {
        terminal.feedPreservingSelection(Array(text.utf8)[...], selection: selection)
    }

    func testLastCellAndExclusiveEnd() {
        let (terminal, selection) = makeTerminal()
        feed("0123456789", into: terminal, selection: selection)
        XCTAssertTrue(terminal.updateSelection(selection, action: 0, column: 9, row: 0))
        XCTAssertEqual(terminal.selectionText(selection), "9")
        XCTAssertEqual(terminal.selectionState(selection).spans.first?.startColumn, 9)
        XCTAssertEqual(terminal.selectionState(selection).spans.first?.endColumn, 10)
        terminal.updateSelection(selection, action: 0, column: 8, row: 0)
        XCTAssertEqual(terminal.selectionText(selection), "8")
        XCTAssertEqual(terminal.selectionState(selection).spans.first?.endColumn, 9)
        terminal.updateSelection(selection, action: 1, column: 9, row: 0)
        XCTAssertEqual(terminal.selectionText(selection), "89")
        terminal.updateSelection(selection, action: 1, column: 7, row: 0)
        XCTAssertEqual(terminal.selectionText(selection), "78")
        terminal.updateSelection(selection, action: 1, column: 9, row: 0)
        XCTAssertEqual(terminal.selectionText(selection), "89")
    }

    func testWideCombiningAndEmojiCells() {
        let (terminal, selection) = makeTerminal()
        feed("a界e\u{301}😀z", into: terminal, selection: selection)
        terminal.updateSelection(selection, action: 0, column: 2, row: 0)
        XCTAssertEqual(terminal.selectionText(selection), "界")
        XCTAssertEqual(terminal.selectionState(selection).spans.first?.startColumn, 1)
        XCTAssertEqual(terminal.selectionState(selection).spans.first?.endColumn, 3)
        terminal.updateSelection(selection, action: 0, column: 3, row: 0)
        XCTAssertEqual(terminal.selectionText(selection), "e\u{301}")
        terminal.updateSelection(selection, action: 0, column: 5, row: 0, mode: 1)
        XCTAssertEqual(terminal.selectionText(selection), "😀")
    }

    func testWordRowAndAllSelection() {
        let (terminal, selection) = makeTerminal()
        feed("hello abcd\r\nnext", into: terminal, selection: selection)
        terminal.updateSelection(selection, action: 0, column: 7, row: 0, mode: 1)
        XCTAssertEqual(terminal.selectionText(selection), "abcd")
        terminal.updateSelection(selection, action: 0, column: 7, row: 0, mode: 2)
        XCTAssertEqual(terminal.selectionText(selection), "hello abcd")
        terminal.updateSelection(selection, action: 3)
        XCTAssertEqual(terminal.selectionText(selection), "hello abcd\nnext")
    }

    func testSoftWrapTextAndShiftExtension() {
        let (terminal, selection) = makeTerminal(cols: 5)
        feed("abcdefgh", into: terminal, selection: selection)
        terminal.updateSelection(selection, action: 0, column: 3, row: 0)
        terminal.updateSelection(selection, action: 0, column: 2, row: 1, mode: 3)
        XCTAssertEqual(terminal.selectionText(selection), "defgh")
        XCTAssertEqual(terminal.selectionState(selection).spans.count, 2)
    }

    func testWordExtensionIncludesPunctuationAndEmojiTargets() {
        for (suffix, width) in [("!", 1), ("😀", 2)] {
            for shift in [false, true] {
                let (terminal, selection) = makeTerminal()
                feed("abc " + suffix, into: terminal, selection: selection)
                terminal.updateSelection(selection, action: 0, column: 1, row: 0, mode: 1)
                terminal.updateSelection(selection, action: shift ? 0 : 1,
                    column: 4 + width - 1, row: 0, mode: shift ? 3 : 0)
                XCTAssertEqual(terminal.selectionText(selection), "abc " + suffix)
                XCTAssertEqual(terminal.selectionState(selection).spans.first?.endColumn, 4 + width)
            }
        }
        let (terminal, selection) = makeTerminal()
        feed("! abc", into: terminal, selection: selection)
        terminal.updateSelection(selection, action: 0, column: 3, row: 0, mode: 1)
        terminal.updateSelection(selection, action: 0, column: 0, row: 0, mode: 3)
        XCTAssertEqual(terminal.selectionText(selection), "! abc")
    }

    func testViewportCoordinatesAndScrollPreserveSelection() {
        let (terminal, selection) = makeTerminal(cols: 8, rows: 2)
        feed("zero\r\none\r\ntwo\r\nthree", into: terminal, selection: selection)
        XCTAssertEqual(terminal.viewportState().maximumTopRow, 2)
        terminal.scrollViewport(Int.min)
        XCTAssertEqual(terminal.viewportState().topRow, 0)
        terminal.updateSelection(selection, action: 0, column: 0, row: 1, mode: 1)
        XCTAssertEqual(terminal.selectionText(selection), "one")
        terminal.scrollViewport(1)
        XCTAssertEqual(terminal.selectionState(selection).spans.first?.row, 0)
        feed("\r\nfour", into: terminal, selection: selection)
        XCTAssertEqual(terminal.viewportState().topRow, 1)
        XCTAssertEqual(terminal.selectionText(selection), "one")
        terminal.scrollViewport(Int.max)
        XCTAssertEqual(terminal.viewportState().topRow, terminal.viewportState().maximumTopRow)
    }

    func testFeedClearsOnlyChangedSelectionAndBufferSwitch() {
        let (terminal, selection) = makeTerminal()
        feed("abcdef", into: terminal, selection: selection)
        terminal.updateSelection(selection, action: 0, column: 1, row: 0)
        feed("\u{1b}[1;6HX", into: terminal, selection: selection)
        XCTAssertEqual(terminal.selectionText(selection), "b")
        feed("\u{1b}[1;2HX", into: terminal, selection: selection)
        XCTAssertFalse(terminal.selectionState(selection).active)
        terminal.updateSelection(selection, action: 0, column: 0, row: 0)
        feed("\u{1b}[?1049h", into: terminal, selection: selection)
        XCTAssertFalse(terminal.selectionState(selection).active)
        XCTAssertTrue(terminal.viewportState().isAlternateScreen)
    }

    /// The endpoint mode belongs to the service the host builds.
    func testUpdateSelectionKeepsTheServiceEndpointMode() {
        let terminal = Terminal(delegate: self,
            options: TerminalOptions(cols: 10, rows: 3, scrollback: 10))
        let selection = SelectionService(terminal: terminal)
        terminal.feedPreservingSelection(Array("0123456789".utf8)[...], selection: selection)
        XCTAssertTrue(terminal.updateSelection(selection, action: 0, column: 2, row: 0))
        XCTAssertFalse(selection.exclusiveEnd)
        selection.selectAll()
        XCTAssertEqual(selection.end.col, terminal.cols - 1)
    }

    /// A delegate must never see endpoints that still split a wide cell.
    func testNormalizedEndpointsReachTheDelegate() {
        let terminal = Terminal(delegate: self,
            options: TerminalOptions(cols: 10, rows: 3, scrollback: 10))
        let selection = SelectionService(terminal: terminal)
        watched = selection
        // The wide cell ends the row, so an inclusive row endpoint splits it.
        terminal.feedPreservingSelection(Array("01234567界".utf8)[...], selection: selection)
        terminal.updateSelection(selection, action: 0, column: 0, row: 0, mode: 2)
        notified.removeAll()
        terminal.updateSelection(selection, action: 1, column: 5, row: 0)
        XCTAssertEqual(selection.end.col, 10)
        XCTAssertFalse(notified.isEmpty)
        XCTAssertEqual(notified.last?.0, selection.start)
        XCTAssertEqual(notified.last?.1, selection.end)
    }

    func testHistoryEvictionAndInvalidCoordinates() {
        let (terminal, selection) = makeTerminal(cols: 8, rows: 2, scrollback: 2)
        feed("zero\r\none\r\ntwo\r\nthree", into: terminal, selection: selection)
        terminal.scrollViewport(0, absolute: true)
        terminal.updateSelection(selection, action: 0, column: 0, row: 1, mode: 1)
        XCTAssertEqual(terminal.selectionText(selection), "one")
        feed("\r\nfour", into: terminal, selection: selection)
        XCTAssertEqual(terminal.selectionText(selection), "one")
        feed("\r\nfive", into: terminal, selection: selection)
        XCTAssertFalse(terminal.selectionState(selection).active)
        XCTAssertFalse(terminal.updateSelection(selection, action: 0, column: 8, row: 0))
        XCTAssertFalse(terminal.updateSelection(selection, action: 0, column: 0, row: 2))
        XCTAssertFalse(terminal.updateSelection(selection, action: 0, column: -1, row: 0))
    }
}
