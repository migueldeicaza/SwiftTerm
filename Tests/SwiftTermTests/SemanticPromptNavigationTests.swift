#if os(macOS)
import Foundation
import Testing
@testable import SwiftTerm

@Suite("TerminalView semantic prompt navigation")
struct SemanticPromptNavigationTests {
    /// Moving to the prompt above or below asks each row on the way whether
    /// it opens a prompt, and the row's own marks answer. A row's derived
    /// kind walks back up the rows it wraps from, so asking that of each row
    /// over a long wrapped output took seconds under the terminal's lock.
    @MainActor
    @Test func aLongWrappedOutputIsCrossedInOnePass() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 640, height: 320)),
                                options: TerminalOptions(scrollback: 10_000))
        let cols = view.terminalStateSnapshot().dimensions.cols
        let output = 3_000
        view.feed(text: "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}cat min.js\r\n\u{1b}]133;C\u{7}"
            + String(repeating: "x", count: cols * output) + "\r\n\u{1b}]133;D;0\u{7}\u{1b}]133;A\u{7}$ ")
        let deadline = Date(timeIntervalSinceNow: 20)
        while Date() < deadline {
            let state = view.terminalStateSnapshot()
            if state.viewportRow + state.cursor.row == output + 1 { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        view.scrollTo(row: output / 2)
#if DEBUG
        let visitsBefore = view.withTerminal { $0.buffer.testingSemanticPromptRowVisits }
#endif
        let previous = view.previousSemanticPromptRow()
        let next = view.nextSemanticPromptRow()
        #expect(previous == 0)
        #expect(next == output + 1)
#if DEBUG
        let visits = view.withTerminal { $0.buffer.testingSemanticPromptRowVisits } - visitsBefore
        #expect(visits > 0)
        #expect(visits <= output + 1)
#endif
    }

    @MainActor
    private func makeView() -> TerminalView {
        TerminalView(frame: CGRect(origin: .zero, size: .init(width: 640, height: 320)),
                     options: TerminalOptions(scrollback: 1_000))
    }

    @MainActor
    private func waitUntil(_ view: TerminalView, _ done: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 20)
        while Date() < deadline, !done() {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    /// Two completed commands and an open prompt, one line each.
    @MainActor
    private func feedTwoCommands(_ view: TerminalView) {
        view.feed(text: "banner\r\n"
            + "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}one\r\n\u{1b}]133;C\u{7}out1\r\n\u{1b}]133;D;0\u{7}"
            + "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}two\r\n\u{1b}]133;C\u{7}out2\r\n\u{1b}]133;D;0\u{7}"
            + "\u{1b}]133;A\u{7}$ ")
        waitUntil(view) { view.terminalStateSnapshot().cursor.row == 5 }
    }

    @MainActor
    @Test func aBufferWithoutPromptsHasNone() {
        let view = makeView()
        view.feed(text: "plain\r\ntext")
        waitUntil(view) { view.terminalStateSnapshot().cursor.row == 1 }
        #expect(!view.hasSemanticPrompts)
        let map = view.semanticRowMap()
        #expect(map != nil)
        #expect(map?.roles.allSatisfy { $0 == .none } == true)
        #expect(map?.visibleRows == view.terminalStateSnapshot().dimensions.rows)
    }

    @MainActor
    @Test func promptAndOutputRowsAreClassified() {
        let view = makeView()
        feedTwoCommands(view)
        #expect(view.hasSemanticPrompts)
        let map = view.semanticRowMap()
        #expect(Array(map?.roles.prefix(6) ?? []) == [.none, .prompt, .output, .prompt, .output, .prompt])
        #expect(map?.viewportTop == view.terminalStateSnapshot().viewportRow)
    }

    @MainActor
    @Test func classificationSpansScrollback() {
        let view = makeView()
        let rows = view.terminalStateSnapshot().dimensions.rows
        let count = rows + 10
        var text = ""
        for i in 0..<count {
            text += "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}c\(i)\r\n\u{1b}]133;C\u{7}o\(i)\r\n\u{1b}]133;D;0\u{7}"
        }
        view.feed(text: text + "\u{1b}]133;A\u{7}$ ")
        waitUntil(view) { view.terminalStateSnapshot().viewportRow + view.terminalStateSnapshot().cursor.row == count * 2 }
        let map = view.semanticRowMap()
        #expect(map?.roles.count == count * 2 + 1)
        #expect((map?.viewportTop ?? 0) > 0)
        for i in 0..<count {
            #expect(map?.roles[i * 2] == .prompt)
            #expect(map?.roles[i * 2 + 1] == .output)
        }
        #expect(map?.roles[count * 2] == .prompt)
    }

    @MainActor
    @Test func theAlternateBufferHasNoSemanticPrompts() {
        let view = makeView()
        feedTwoCommands(view)
        view.feed(text: "\u{1b}[?1049h")
        waitUntil(view) { view.withTerminal { $0.isCurrentBufferAlternate } }
        #expect(!view.hasSemanticPrompts)
        #expect(view.semanticRowMap() == nil)
    }

    @MainActor
    @Test func selectingBufferRowsCopiesExactlyThoseRows() {
        let view = makeView()
        feedTwoCommands(view)
        view.selectBufferRows(4...4)
        #expect(view.selectionActive)
        #expect(view.getSelection() == "out2")
        view.selectBufferRows(2...4)
        #expect(view.getSelection() == "out1\n$ two\nout2")
        view.selectBufferRows(4...100)
        #expect(view.getSelection()?.hasPrefix("out2") == true)
    }
}
#endif
