//
//  SendThreadingTests.swift
//  SwiftTermTests
//
//  `TerminalView.send(data:)` is callable from any thread (io-gaps.md G5a).
//  Before that it asserted `Thread.isMainThread`, because it ran the OSC 133
//  submission scanner inline without the terminal lock.
//

#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import SwiftTerm

@Suite(.serialized)
struct SendThreadingTests {

    /// Counts the bytes that reach the host, which is where a send that was
    /// dropped or corrupted would show up.
    private final class CountingDelegate: TerminalViewDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = 0

        var byteCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return bytes
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            lock.lock()
            bytes += data.count
            lock.unlock()
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

    /// A lock-guarded countdown, so the feeder knows when to stop.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count: Int

        init(_ initial: Int) { count = initial }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func decrement() {
            lock.lock()
            count -= 1
            lock.unlock()
        }
    }

    @MainActor
    private func makeView() -> TerminalView {
        let view = TerminalView(
            frame: CGRect(origin: .zero, size: CGSize(width: 400, height: 200)),
            font: nil,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 200))
        // Nothing in these tests needs frames, and a live display link only
        // adds noise to a threading assertion.
        view.frameDriver.invalidate()
        return view
    }

    /// The acceptance: a transport thread calls `send` directly, with no
    /// marshalling and no assert, while output is being fed from another.
    @MainActor
    @Test func sendFromBackgroundThreadDuringAFlood() async {
        let view = makeView()
        let terminal = view.getTerminal()
        let delegate = CountingDelegate()
        view.terminalDelegate = delegate

        let senders = 4
        let sendsPerThread = 500
        let done = DispatchSemaphore(value: 0)

        // The feeder must still be running while the senders are, or the
        // scanner and the parser never overlap and the test proves nothing.
        // The first version fed a fixed 400 lines and finished first: with the
        // lock removed again, neither the assertions nor the thread sanitizer
        // noticed. It now feeds until the senders say they are done.
        let sendersRemaining = Counter(senders)
        let feeding = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var index = 0
            while sendersRemaining.value > 0 {
                // OSC 133 A/B on every line, because that is what makes the
                // parser *write* `buffer.semanticInput`. Without the markers
                // the submission scanner returns at its first guard and the
                // two threads never touch the same field — the test passed
                // with the lock removed precisely because of that.
                view.feed(text: "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}line \(index)\r\n")
                index += 1
            }
            feeding.signal()
        }

        for _ in 0..<senders {
            DispatchQueue.global().async {
                for _ in 0..<sendsPerThread {
                    // Not a plain letter. `scanUserInputForSubmission` only
                    // *writes* its state machine on ESC and on CR/LF; for an
                    // ordinary character it reads one field and returns, so a
                    // payload of "x" produced no conflicting access at all and
                    // the thread sanitizer stayed silent with the lock removed.
                    // An arrow key plus a return exercises both writes, and the
                    // return also drives `buffer.semanticInput`, which the
                    // feeder's OSC 133 markers write from the other side.
                    view.send(data: Array("\u{1b}[A\r".utf8)[...])
                }
                sendersRemaining.decrement()
                done.signal()
            }
        }

        for _ in 0..<senders {
            #expect(done.wait(timeout: .now() + 30) == .success)
        }
        #expect(feeding.wait(timeout: .now() + 30) == .success)

        // Every byte reached the host: nothing was dropped or double-sent.
        #expect(delegate.byteCount == senders * sendsPerThread * 4)
        // And the terminal is intact and still usable from the main thread.
        // (Not asserting a specific column count: the view sizes the terminal
        // from its frame, so `TerminalOptions.cols` is not what survives.)
        let cols = terminal.terminalLock.withLock { terminal.cols }
        #expect(cols > 0)
    }

    /// The submission heuristic still works when the send arrives off the main
    /// thread: an armed prompt moves to `submitted` on a carriage return.
    @MainActor
    @Test func semanticSubmissionIsCorrectFromABackgroundSend() async {
        let view = makeView()
        let terminal = view.getTerminal()

        // OSC 133;A then ;B arms the prompt for submission detection.
        view.feed(text: "\u{1b}]133;A\u{7}prompt$ \u{1b}]133;B\u{7}")
        let armed = terminal.terminalLock.withLock {
            terminal.buffer.semanticInput
        }
        #expect(armed == .armed)

        let sent = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            view.send(data: Array("ls\r".utf8)[...])
            sent.signal()
        }
        #expect(sent.wait(timeout: .now() + 10) == .success)

        let after = terminal.terminalLock.withLock {
            terminal.buffer.semanticInput
        }
        #expect(after == .submitted)
    }

    /// Sends that carry no submission must leave the prompt armed. This is the
    /// direction that matters: a wrong `submitted` costs a dead click, a wrong
    /// `armed` injects bytes into a child process.
    @MainActor
    @Test func nonSubmittingBackgroundSendLeavesPromptArmed() async {
        let view = makeView()
        let terminal = view.getTerminal()

        view.feed(text: "\u{1b}]133;A\u{7}prompt$ \u{1b}]133;B\u{7}")
        let sent = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for byte in Array("ls -la".utf8) {
                view.send(data: [byte][...])
            }
            sent.signal()
        }
        #expect(sent.wait(timeout: .now() + 10) == .success)

        let after = terminal.terminalLock.withLock {
            terminal.buffer.semanticInput
        }
        #expect(after == .armed)
    }
}
#endif
