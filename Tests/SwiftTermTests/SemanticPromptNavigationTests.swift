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

    /// Runs the main run loop until `done` is true. The view parses off the
    /// main thread, so a test waits for the parse before it reads state.
    @MainActor
    private func waitUntil(_ done: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        let deadline = Date(timeIntervalSinceNow: 20)
        while !done() {
            guard Date() < deadline else {
                Issue.record("Timed out waiting for the terminal", sourceLocation: sourceLocation)
                return
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    /// Rows: 0 banner, 1 prompt, 2 "out1", 3 prompt, 4 "out2", 5 blank,
    /// 6 "more", 7 prompt with no output, 8 idle prompt.
    @MainActor
    private func feedCommands(_ view: TerminalView) {
        let prompt = "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}"
        let output = "\u{1b}]133;C\u{7}"
        let end = "\u{1b}]133;D;0\u{7}"
        view.feed(text: "banner\r\n"
            + prompt + "one\r\n" + output + "out1\r\n" + end
            + prompt + "two\r\n" + output + "out2\r\n\r\nmore\r\n" + end
            + prompt + "cd /\r\n" + output + end
            + prompt)
        waitUntil { view.terminalStateSnapshot().cursor.row == 8 }
    }

    @MainActor
    @Test func theOutputOfTheNewestCommandIsSelected() {
        let view = makeView()
        feedCommands(view)
        #expect(view.semanticCommandOutputRows() == 4...6)
        #expect(view.selectSemanticCommandOutput())
        #expect(view.getSelection() == "out2\n\nmore")
    }

    @MainActor
    @Test func theOutputOfAGivenPromptIsSelected() {
        let view = makeView()
        feedCommands(view)
        #expect(view.semanticCommandOutputRows(forPromptAt: 1) == 2...2)
        #expect(view.selectSemanticCommandOutput(forPromptAt: 1))
        #expect(view.getSelection() == "out1")
    }

    @MainActor
    @Test func noOutputKeepsTheCurrentSelection() {
        let view = makeView()
        feedCommands(view)
        view.setSelectionRange(start: Position(col: 0, row: 0), end: Position(col: 6, row: 0))
        #expect(view.getSelection() == "banner")
        #expect(view.semanticCommandOutputRows(forPromptAt: 7) == nil)
        #expect(!view.selectSemanticCommandOutput(forPromptAt: 7))
        #expect(!view.selectSemanticCommandOutput(forPromptAt: 2))
        #expect(view.getSelection() == "banner")
    }

    @MainActor
    @Test func theAlternateBufferHasNoCommandOutput() {
        let view = makeView()
        feedCommands(view)
        view.feed(text: "\u{1b}[?1049h")
        waitUntil { view.withTerminal { $0.isCurrentBufferAlternate } }
        #expect(view.semanticCommandOutputRows() == nil)
        #expect(!view.selectSemanticCommandOutput())
        #expect(!view.selectionActive)
    }

    @MainActor
    @Test func setSelectionRangeClampsToTheBuffer() {
        let view = makeView()
        feedCommands(view)
        view.setSelectionRange(start: Position(col: 0, row: 4), end: Position(col: 500, row: 4))
        #expect(view.getSelection() == "out2")
    }

    @MainActor
    @Test func aFullWidthOutputRowIsSelectedToTheLastColumn() {
        let view = makeView()
        let cols = view.terminalStateSnapshot().dimensions.cols
        let row = String(repeating: "x", count: cols - 1) + "y"
        view.feed(text: "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}cat\r\n\u{1b}]133;C\u{7}"
            + row + "\r\n\u{1b}]133;D;0\u{7}\u{1b}]133;A\u{7}$ ")
        waitUntil { view.terminalStateSnapshot().cursor.row == 2 }
        #expect(view.selectSemanticCommandOutput())
        #expect(view.getSelection() == row)
    }
}
#endif
