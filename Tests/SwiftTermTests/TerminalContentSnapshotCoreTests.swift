import Testing
@testable import SwiftTerm

struct TerminalContentSnapshotCoreTests {
    private final class Fixture {
        let delegate = TerminalTestDelegate()
        let terminal: Terminal

        init(scrollback: Int = 20) {
            terminal = Terminal(
                delegate: delegate,
                options: TerminalOptions(cols: 12, rows: 4, scrollback: scrollback))
        }

        func feed(_ text: String) {
            terminal.terminalLock.withLock {
                terminal.feed(text: text)
            }
        }
    }

    @Test func terminalCopiedModesReflectInputState() {
        let fixture = Fixture()
        fixture.feed("\u{1b}=\u{1b}[?1h\u{1b}[?1002h\u{1b}[?2004h\u{1b}[?1004h\u{1b}[>8u")
        let input = fixture.terminal.inputStateSnapshot()
        #expect(input.dimensions == TerminalDimensions(cols: 12, rows: 4))
        #expect(input.isAlternateBuffer == false)
        #expect(input.applicationCursor)
        #expect(input.applicationKeypad)
        #expect(input.mouseMode == .buttonEventTracking)
        #expect(input.bracketedPasteMode)
        #expect(input.keyboardEnhancementFlags.contains(.reportAllKeys))
        #expect(input.focusReportingEnabled)

        fixture.feed("\u{1b}>\u{1b}[?1l\u{1b}[?1002l\u{1b}[?2004l\u{1b}[?1004l")
        let reset = fixture.terminal.inputStateSnapshot()
        #expect(reset.applicationCursor == false)
        #expect(reset.applicationKeypad == false)
        #expect(reset.mouseMode == .off)
        #expect(reset.bracketedPasteMode == false)
        #expect(reset.focusReportingEnabled == false)
    }

    @Test(arguments: [
        ("", ""),
        ("A", "A"),
        ("A  ", "A  "),
        ("A\u{1b}[3GX", "A X"),
        ("界", "界"),
        ("界 ", "界 "),
        ("1234567890界", "1234567890界"),
        ("12345678901界", "12345678901"),
        ("e\u{301}", "e\u{301}"),
        ("\u{A98F}\u{A9C0}\u{A994}\u{A9B8}", "\u{A98F}\u{A9C0}\u{A994}\u{A9B8}"),
        ("\u{1b}[44m\u{1b}[2K", ""),
    ])
    func rowTextMatchesDisplayTextWithoutNUL(sample: (String, String)) throws {
        let fixture = Fixture()
        fixture.feed(sample.0)
        let row = try #require(fixture.terminal.contentSnapshot(region: .viewport).rows.first)
        let reference = fixture.terminal.terminalLock.withLock {
            fixture.terminal.translateBufferLineToString(
                buffer: fixture.terminal.displayBuffer,
                line: fixture.terminal.displayBuffer.yDisp,
                start: 0,
                end: -1)
        }
        #expect(row.text == reference)
        #expect(row.text == sample.1)
        #expect(!row.text.contains("\u{0}"))
    }

    @Test func cellsPreserveNULTailsWhileRowTextHidesThem() throws {
        let wide = Fixture()
        wide.feed("界 ")
        let wideRow = try #require(wide.terminal.contentSnapshot(region: .viewport).rows.first)
        #expect(wideRow.cells[0].text == "界")
        #expect(wideRow.cells[0].width == 2)
        #expect(wideRow.cells[1].text == "\u{0}")
        #expect(wideRow.cells[1].width == 0)
        #expect(wideRow.text == "界 ")

        let gap = Fixture()
        gap.feed("A\u{1b}[3GX")
        let gapRow = try #require(gap.terminal.contentSnapshot(region: .viewport).rows.first)
        #expect(gapRow.cells[1].text == "\u{0}")
        #expect(gapRow.cells[1].width == 1)
        #expect(gapRow.text == "A X")
    }

    @Test func copiedRowsExposeWrapFlags() throws {
        let fixture = Fixture()
        fixture.feed("1234567890123\r\nnext")
        let snapshot = fixture.terminal.contentSnapshot(region: .viewport)
        #expect(snapshot.rows[0].text == "123456789012")
        #expect(snapshot.rows[0].isWrapped == false)
        #expect(snapshot.rows[1].text == "3")
        #expect(snapshot.rows[1].isWrapped == true)
        #expect(snapshot.rows[2].text == "next")
        #expect(snapshot.rows[2].isWrapped == false)
    }

    @Test func narrowedAlternateScreenDoesNotExposeOffscreenCells() throws {
        let fixture = Fixture()
        fixture.feed("\u{1b}[?1049hABCDEFGHIJKL")
        fixture.terminal.terminalLock.withLock {
            fixture.terminal.resize(cols: 8, rows: 4)
            fixture.terminal.feed(text: "\u{1b}[2J\u{1b}[Hx")
        }

        let snapshot = fixture.terminal.contentSnapshot(region: .viewport)
        let row = try #require(snapshot.rows.first)
        #expect(snapshot.inputState.dimensions == TerminalDimensions(cols: 8, rows: 4))
        #expect(row.cells.count == 8)
        #expect(row.text == "x")
    }

    @Test func historyIsBoundedAndUsesScrollInvariantCoordinates() throws {
        let fixture = Fixture(scrollback: 800)
        fixture.feed((0..<1_000).map { "row\($0)\r\n" }.joined())
        let bounded = fixture.terminal.contentSnapshot(
            region: .history(maximumScrollbackRows: 500))
        #expect(bounded.rows.count == 504)
        #expect(bounded.capturedRange.count == bounded.rows.count)
        #expect(bounded.rows.map(\.absoluteRow) == Array(bounded.capturedRange))
        #expect(bounded.liveTopRow == bounded.capturedRange.upperBound - 4)
        #expect(bounded.capturedRange.lowerBound > 0)
    }

    @Test func valueTypesAreCheckedSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(TerminalDimensions.self)
        requireSendable(TerminalInputStateSnapshot.self)
        requireSendable(TerminalContentRegion.self)
        requireSendable(TerminalCellSnapshot.self)
        requireSendable(TerminalContentRowSnapshot.self)
        requireSendable(TerminalContentSnapshot.self)
    }

    #if !os(iOS) && !os(Windows) && !os(WASI)
    @Test func headlessTerminalExposesSnapshots() throws {
        let headless = HeadlessTerminal(
            options: TerminalOptions(cols: 12, rows: 4, scrollback: 20),
            directDelivery: true
        ) { _ in }
        headless.dataReceived(slice: Array("headless".utf8)[...])
        #expect(headless.terminalInputStateSnapshot().dimensions == TerminalDimensions(cols: 12, rows: 4))
        let snapshot = headless.terminalContentSnapshot(region: .viewport)
        #expect(snapshot.rows.first?.text == "headless")
    }
    #endif
}
