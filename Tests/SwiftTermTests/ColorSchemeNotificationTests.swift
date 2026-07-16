import Testing
@testable import SwiftTerm

final class ColorSchemeNotificationTests {
    private let esc = "\u{1b}"

    @Test func queryReportsCurrentColorScheme() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        terminal.updateColorScheme(.light)
        #expect(delegate.sentData.isEmpty)

        terminal.feed(text: "\(esc)[?996n")

        #expect(response(from: delegate) == "\(esc)[?997;2n")
    }

    @Test func subscribedApplicationReceivesPaletteUpdates() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        terminal.feed(text: "\(esc)[?2031h")
        terminal.updateColorScheme(.light)

        #expect(terminal.colorSchemeUpdatesEnabled)
        #expect(response(from: delegate) == "\(esc)[?997;2n")
    }

    @Test func unsubscribedApplicationDoesNotReceivePaletteUpdates() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        terminal.feed(text: "\(esc)[?2031h")
        terminal.feed(text: "\(esc)[?2031l")
        terminal.updateColorScheme(.light)

        #expect(!terminal.colorSchemeUpdatesEnabled)
        #expect(delegate.sentData.isEmpty)
    }

    @Test func modeQueryReportsSubscriptionState() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        terminal.feed(text: "\(esc)[?2031$p")
        #expect(response(from: delegate) == "\(esc)[?2031;2$y")

        delegate.clearSentData()
        terminal.feed(text: "\(esc)[?2031h")
        terminal.feed(text: "\(esc)[?2031$p")
        #expect(response(from: delegate) == "\(esc)[?2031;1$y")
    }

    @Test func fullResetClearsSubscription() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        terminal.updateColorScheme(.light)
        terminal.feed(text: "\(esc)[?2031h")
        terminal.resetToInitialState()
        terminal.updateColorScheme(.dark)

        #expect(!terminal.colorSchemeUpdatesEnabled)
        #expect(delegate.sentData.isEmpty)

        terminal.feed(text: "\(esc)[?996n")
        #expect(response(from: delegate) == "\(esc)[?997;1n")
    }

    private func response(from delegate: TerminalTestDelegate) -> String {
        String(decoding: delegate.sentData.last ?? [], as: UTF8.self)
    }
}
