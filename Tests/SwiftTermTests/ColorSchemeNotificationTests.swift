import Testing
@testable import SwiftTerm

#if os(macOS)
import AppKit
#endif

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

    @Test func silentUpdateRecordsWithoutNotifying() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        terminal.feed(text: "\(esc)[?2031h")
        terminal.updateColorScheme(.light, notify: false)
        #expect(delegate.sentData.isEmpty)

        // Queries already see the new preference while the notification waits.
        terminal.feed(text: "\(esc)[?996n")
        #expect(response(from: delegate) == "\(esc)[?997;2n")

        delegate.clearSentData()
        terminal.notifyColorScheme()
        #expect(response(from: delegate) == "\(esc)[?997;2n")
    }

    @Test func saveAndRestoreSubscriptionValues() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        terminal.feed(text: "\(esc)[?2031s")
        terminal.feed(text: "\(esc)[?2031h\(esc)[?2031r")
        #expect(!terminal.colorSchemeUpdatesEnabled)

        terminal.feed(text: "\(esc)[?2031h\(esc)[?2031s\(esc)[?2031l")
        terminal.feed(text: "\(esc)[?2031r")
        #expect(terminal.colorSchemeUpdatesEnabled)

        terminal.updateColorScheme(.light)
        #expect(response(from: delegate) == "\(esc)[?997;2n")
    }

    @Test func risClearsSavedSubscriptionWithoutSendingReport() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        terminal.feed(text: "\(esc)[?2031h\(esc)[?2031s")
        delegate.clearSentData()
        terminal.feed(text: "\(esc)c")

        #expect(!terminal.colorSchemeUpdatesEnabled)
        #expect(delegate.sentData.isEmpty)

        terminal.feed(text: "\(esc)[?2031h\(esc)[?2031r")
        #expect(!terminal.colorSchemeUpdatesEnabled)
        #expect(delegate.sentData.isEmpty)
    }

    @Test func notifyIsSilentWithoutSubscription() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        terminal.updateColorScheme(.light, notify: false)
        terminal.notifyColorScheme()
        #expect(delegate.sentData.isEmpty)
    }

    @Test func fullResetClearsSubscription() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        terminal.updateColorScheme(.light)
        terminal.feed(text: "\(esc)[?2031h")
        terminal.feed(text: "\(esc)c")
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

#if os(macOS)
@Suite(.serialized)
@MainActor
struct ColorSchemeViewAPITests {
    private final class RecordingDelegate: TerminalViewDelegate {
        var sentData: [[UInt8]] = []

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            sentData.append(Array(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    @Test func viewCanRecordThenNotifyColorScheme() async {
        let view = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let delegate = RecordingDelegate()
        view.terminalDelegate = delegate

        view.feed(text: "\u{1b}[?2031h")
        view.updateColorScheme(.light, notify: false)
        #expect(delegate.sentData.isEmpty)

        view.feed(text: "\u{1b}[?996n")
        await waitForPayload(count: 1, from: delegate)
        #expect(response(from: delegate) == "\u{1b}[?997;2n")

        delegate.sentData.removeAll()
        view.notifyColorScheme()
        await waitForPayload(count: 1, from: delegate)
        #expect(response(from: delegate) == "\u{1b}[?997;2n")
    }

    private func waitForPayload(count: Int, from delegate: RecordingDelegate) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while delegate.sentData.count < count, ContinuousClock.now < deadline {
            await Task.yield()
        }
    }

    private func response(from delegate: RecordingDelegate) -> String {
        String(decoding: delegate.sentData.last ?? [], as: UTF8.self)
    }
}
#endif
