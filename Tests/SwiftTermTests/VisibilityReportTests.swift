import Testing
@testable import SwiftTerm

@Suite(.serialized)
final class VisibilityReportTests {
    private let esc = "\u{1b}"

    @Test func decrqmInitiallyReportsReset() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        terminal.feed(text: "\(esc)[?2033$p")

        #expect(response(from: delegate) == "\(esc)[?2033;2$y")
    }

    @Test func oneShotQueryReportsDefaultVisibility() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        terminal.feed(text: "\(esc)[?998n")

        #expect(response(from: delegate) == "\(esc)[?999;1n")
    }

    @Test func decsetReportsImmediatelyAndRepeats() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        terminal.feed(text: "\(esc)[?2033h\(esc)[?2033h")

        #expect(responses(from: delegate) == [
            "\(esc)[?999;1n",
            "\(esc)[?999;1n",
        ])
    }

    @Test func changedVisibilityReportsOnceWhileEnabled() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?2033h")
        delegate.clearSentData()

        terminal.setTerminalVisibility(.notVisible)
        terminal.setTerminalVisibility(.notVisible)

        #expect(response(from: delegate) == "\(esc)[?999;2n")
        #expect(delegate.sentData.count == 1)
    }

    @Test func decrstIsSilentAndBlocksChanges() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?2033h")
        delegate.clearSentData()

        terminal.feed(text: "\(esc)[?2033l")
        terminal.setTerminalVisibility(.notVisible)

        #expect(!terminal.visibilityReportsEnabled)
        #expect(delegate.sentData.isEmpty)
    }

    @Test func oneShotQueryWorksWhileDisabled() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.setTerminalVisibility(.notVisible)

        terminal.feed(text: "\(esc)[?998n")

        #expect(response(from: delegate) == "\(esc)[?999;2n")
    }

    @Test func risPreservesVisibilityAndClearsSubscription() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.setTerminalVisibility(.notVisible)
        terminal.feed(text: "\(esc)[?2033h")
        delegate.clearSentData()

        terminal.feed(text: "\(esc)c")

        #expect(!terminal.visibilityReportsEnabled)
        #expect(terminal.reportedVisibility == .notVisible)
        #expect(delegate.sentData.isEmpty)

        terminal.feed(text: "\(esc)[?998n")
        #expect(response(from: delegate) == "\(esc)[?999;2n")
    }

    @Test func xtrestoreToSetReportsImmediately() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.setTerminalVisibility(.notVisible)
        terminal.feed(text: "\(esc)[?2033h\(esc)[?2033s\(esc)[?2033l")
        delegate.clearSentData()

        terminal.feed(text: "\(esc)[?2033r")

        #expect(terminal.visibilityReportsEnabled)
        #expect(response(from: delegate) == "\(esc)[?999;2n")
    }

#if os(macOS)
    @MainActor
    @Test func renderOwnerAppliesVisibilityPublishedBeforeAttach() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        let owner = TerminalRenderOwner()
        let selection = SelectionService(terminal: terminal)
        let search = SearchService(terminal: terminal)

        owner.setTerminalVisibility(.notVisible)
        owner.attach(terminal: terminal, selection: selection, search: search)

        #expect(terminal.reportedVisibility == .notVisible)
    }
#endif

    private func response(from delegate: TerminalTestDelegate) -> String {
        String(decoding: delegate.sentData.last ?? [], as: UTF8.self)
    }

    private func responses(from delegate: TerminalTestDelegate) -> [String] {
        delegate.sentData.map { String(decoding: $0, as: UTF8.self) }
    }
}
