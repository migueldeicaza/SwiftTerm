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
}
#endif
