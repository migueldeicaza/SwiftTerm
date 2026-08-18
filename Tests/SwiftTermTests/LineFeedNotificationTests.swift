import Testing
@testable import SwiftTerm

@Suite final class LineFeedNotificationTests {
    private final class Delegate: TerminalDelegate {
        var lineFeedCount = 0

        func linefeed(source: Terminal) {
            lineFeedCount += 1
        }

        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private enum TestError: Error {
        case expected
    }

    @Test func terminalReportsEachLineFeed() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)

        terminal.feed(text: "one\ntwo\nthree\n")

        #expect(delegate.lineFeedCount == 3)
    }

    @Test func managedFeedSuppressesLineFeedCallbacks() {
        let delegate = Delegate()
        let terminal = ManagedFeedTerminal(delegate: delegate)

        terminal.withManagedFeed {
            terminal.feed(text: "one\ntwo\nthree\n")
        }

        #expect(delegate.lineFeedCount == 0)
    }

    @Test func directFeedKeepsDelegateBehavior() {
        let delegate = Delegate()
        let terminal: Terminal = ManagedFeedTerminal(delegate: delegate)

        terminal.feed(text: "one\ntwo\n")

        #expect(delegate.lineFeedCount == 2)
    }

    @Test func normalTerminalKeepsDelegateBehaviorForManagedFeedRequest() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)

        terminal.withManagedFeed {
            terminal.feed(text: "one\ntwo\n")
        }

        #expect(delegate.lineFeedCount == 2)
    }

    @Test func nestedManagedFeedsRestoreDelegateBehavior() {
        let delegate = Delegate()
        let terminal = ManagedFeedTerminal(delegate: delegate)

        terminal.withManagedFeed {
            terminal.withManagedFeed {
                terminal.feed(text: "one\ntwo\n")
            }
        }
        terminal.feed(text: "three\n")

        #expect(delegate.lineFeedCount == 1)
    }

    @Test func throwingManagedFeedRestoresDelegateBehavior() {
        let delegate = Delegate()
        let terminal = ManagedFeedTerminal(delegate: delegate)

        do {
            try terminal.withManagedFeed {
                throw TestError.expected
            }
        } catch TestError.expected {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        terminal.feed(text: "one\n")

        #expect(delegate.lineFeedCount == 1)
    }

    @Test func managedTerminalDoesNotRetainDelegate() {
        let terminal: ManagedFeedTerminal
        weak var weakDelegate: Delegate?

        do {
            let delegate = Delegate()
            weakDelegate = delegate
            terminal = ManagedFeedTerminal(delegate: delegate)
        }

        #expect(weakDelegate == nil)
        terminal.feed(text: "one\n")
    }
}
