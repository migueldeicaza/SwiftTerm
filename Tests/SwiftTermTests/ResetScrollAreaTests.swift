import Testing
@testable import SwiftTerm

/// A full reset (RIS, `ESC c`) replaces the buffer, so any view that derives its
/// scroll geometry from `lines.count` / `yDisp` has to be told about it.
/// `syncScrollArea()` is a no-op stub, and none of the other paths that make a
/// view recompute that geometry run here — there is no buffer switch, no scrolled
/// line, no keystroke and no resize — so `resetToInitialState()` notifies
/// explicitly. Without that, a view keeps the contentSize/contentOffset of the
/// buffer that was just discarded and renders blank.
@Suite("Full reset scroll area")
struct ResetScrollAreaTests {
    @Test("RIS notifies the delegate that the buffer changed")
    func fullResetNotifiesDelegate() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24, scrollback: 500)

        // Build up scrollback so the reset is a real change in buffer size.
        for i in 0..<200 {
            terminal.feed(text: "line \(i)\r\n")
        }
        #expect(terminal.buffer.lines.count > terminal.rows)

        let before = delegate.bufferActivatedCount
        terminal.feed(text: "\u{1b}c")

        // The buffer really did shrink back to a single screen...
        #expect(terminal.buffer.lines.count == terminal.rows)
        #expect(terminal.buffer.yBase == 0)
        #expect(terminal.buffer.yDisp == 0)
        // ...and the delegate heard about it exactly once.
        #expect(delegate.bufferActivatedCount == before + 1)
    }

    private final class DirectoryDelegate: TerminalDelegate {
        var directories: [String?] = []
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func hostCurrentDirectoryUpdated(source: Terminal) {
            directories.append(source.hostCurrentDirectory)
        }
    }

    @Test("RIS reports a cleared shell directory only when it changes")
    func fullResetReportsClearedDirectory() {
        let delegate = DirectoryDelegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: "\u{1b}c")
        #expect(delegate.directories.isEmpty)
        terminal.feed(text: "\u{1b}]7;file://localhost/tmp/project\u{07}")
        terminal.feed(text: "\u{1b}c")
        terminal.feed(text: "\u{1b}c")
        #expect(terminal.hostCurrentDirectory == nil)
        #expect(delegate.directories == ["file://localhost/tmp/project", nil])
    }

    @Test("Keypad mode changes do not claim the buffer changed")
    func keypadModeDoesNotNotify() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24, scrollback: 500)

        let before = delegate.bufferActivatedCount
        terminal.feed(text: "\u{1b}=")   // application keypad
        terminal.feed(text: "\u{1b}>")   // numeric keypad

        // These also call syncScrollArea(), but they do not touch the buffer, so
        // they must not be reported as a buffer activation: on iOS that resets
        // the scroll-follow state and would yank a user who has scrolled back
        // down to the bottom.
        #expect(delegate.bufferActivatedCount == before)
    }
}
