import Testing
@testable import SwiftTerm

@Suite final class ScrollNotificationTests {
    private final class Delegate: TerminalDelegate {
        var scrolledPositions: [Int] = []

        func showCursor(source: Terminal) {}
        func hideCursor(source: Terminal) {}
        func setTerminalTitle(source: Terminal, title: String) {}
        func setTerminalIconTitle(source: Terminal, title: String) {}
        func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { nil }
        func sizeChanged(source: Terminal) {}
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func bufferActivated(source: Terminal) {}
        func bell(source: Terminal) {}
    }

    @Test func multipleScrolledLinesProduceOneNotificationPerFeed() {
        let delegate = Delegate()
        let terminal = ViewTerminal(
            delegate: delegate,
            options: TerminalOptions(cols: 20, rows: 3, scrollback: 20),
            synchronizedOutputWatchdogHandler: { _, _ in }
        ) { terminal in
            delegate.scrolledPositions.append(terminal.buffer.yDisp)
        }

        terminal.feed(text: "one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n")

        #expect(delegate.scrolledPositions == [terminal.buffer.yDisp])
        #expect(terminal.buffer.yDisp > 1)
    }

    @Test func separateFeedsProduceSeparateNotifications() {
        let delegate = Delegate()
        let terminal = ViewTerminal(
            delegate: delegate,
            options: TerminalOptions(cols: 20, rows: 2, scrollback: 20),
            synchronizedOutputWatchdogHandler: { _, _ in }
        ) { terminal in
            delegate.scrolledPositions.append(terminal.buffer.yDisp)
        }

        terminal.feed(text: "one\r\ntwo\r\nthree\r\n")
        terminal.feed(text: "four\r\nfive\r\n")

        #expect(delegate.scrolledPositions.count == 2)
        #expect(delegate.scrolledPositions.last == terminal.buffer.yDisp)
    }

    @Test func directScrollProducesImmediateNotification() {
        let delegate = Delegate()
        let terminal = ViewTerminal(
            delegate: delegate,
            options: TerminalOptions(cols: 20, rows: 3, scrollback: 20),
            synchronizedOutputWatchdogHandler: { _, _ in }
        ) { terminal in
            delegate.scrolledPositions.append(terminal.buffer.yDisp)
        }

        terminal.scroll()

        #expect(delegate.scrolledPositions == [terminal.buffer.yDisp])
    }

    @Test func batchedNotificationUsesTheActiveBufferPosition() {
        let delegate = Delegate()
        let terminal = ViewTerminal(
            delegate: delegate,
            options: TerminalOptions(cols: 20, rows: 2, scrollback: 20),
            synchronizedOutputWatchdogHandler: { _, _ in }
        ) { terminal in
            delegate.scrolledPositions.append(terminal.buffer.yDisp)
        }

        // Scroll the normal buffer, then activate the alternate buffer before
        // the feed batch delivers its one coalesced notification.
        terminal.feed(text: "one\r\ntwo\r\nthree\r\n\u{1b}[?1049h")

        #expect(terminal.isCurrentBufferAlternate)
        #expect(delegate.scrolledPositions == [terminal.buffer.yDisp])
    }
}
