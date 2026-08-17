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
    private final class CountingDelegate: TerminalViewDelegate, Sendable {
        private let bytes = Locked(0)

        var byteCount: Int {
            bytes.withLock { $0 }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            bytes.withLock { $0 += data.count }
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

    private final class RecordingDelegate: TerminalViewDelegate, Sendable {
        private let payloads = Locked([[UInt8]]())

        var receivedPayloads: [[UInt8]] {
            payloads.withLock { $0 }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            payloads.withLock { $0.append(Array(data)) }
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
    private final class Counter: Sendable {
        private let count: Locked<Int>

        init(_ initial: Int) { count = Locked(initial) }

        var value: Int {
            count.withLock { $0 }
        }

        func decrement() {
            count.withLock { $0 -= 1 }
        }
    }

    /// An async countdown for work that must run on Dispatch threads.
    private final class AsyncCountdown: Sendable {
        private struct State {
            var remaining: Int
            var continuation: CheckedContinuation<Void, Never>?
        }

        private let state: Locked<State>

        init(_ count: Int) {
            state = Locked(State(remaining: count, continuation: nil))
        }

        func signal() {
            let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
                state.remaining -= 1
                guard state.remaining == 0 else { return nil }
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume()
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let resumeImmediately = state.withLock { state in
                    if state.remaining == 0 {
                        return true
                    }
                    precondition(state.continuation == nil)
                    state.continuation = continuation
                    return false
                }
                if resumeImmediately {
                    continuation.resume()
                }
            }
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
        let feedSender = view.feedSender
        let inputSender = view.inputSender
        let delegate = CountingDelegate()
        view.terminalDelegate = delegate

        let senders = 4
        let sendsPerThread = 500
        let done = AsyncCountdown(senders)

        // The feeder must still be running while the senders are, or the
        // scanner and the parser never overlap and the test proves nothing.
        // The first version fed a fixed 400 lines and finished first: with the
        // lock removed again, neither the assertions nor the thread sanitizer
        // noticed. It now feeds until the senders say they are done.
        let sendersRemaining = Counter(senders)
        let feeding = AsyncCountdown(1)
        DispatchQueue.global().async {
            var index = 0
            while sendersRemaining.value > 0 {
                // OSC 133 A/B on every line, because that is what makes the
                // parser *write* `buffer.semanticInput`. Without the markers
                // the submission scanner returns at its first guard and the
                // two threads never touch the same field — the test passed
                // with the lock removed precisely because of that.
                feedSender.feed(text: "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}line \(index)\r\n")
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
                    inputSender.send(data: Array("\u{1b}[A\r".utf8)[...])
                }
                sendersRemaining.decrement()
                done.signal()
            }
        }

        await done.wait()
        await feeding.wait()

        let expectedBytes = senders * sendsPerThread * 4
        let deadline = ContinuousClock.now + .seconds(2)
        while delegate.byteCount < expectedBytes, ContinuousClock.now < deadline {
            await Task.yield()
        }

        // Every byte reached the host: nothing was dropped or double-sent.
        #expect(delegate.byteCount == expectedBytes)
        // And the terminal is intact and still usable from the main thread.
        // (Not asserting a specific column count: the view sizes the terminal
        // from its frame, so `TerminalOptions.cols` is not what survives.)
        #expect(view.terminalDimensions.cols > 0)
    }

    /// The submission heuristic still works when the send arrives off the main
    /// thread: an armed prompt moves to `submitted` on a carriage return.
    @MainActor
    @Test func semanticSubmissionIsCorrectFromABackgroundSend() async {
        let view = makeView()
        let inputSender = view.inputSender

        // OSC 133;A then ;B arms the prompt for submission detection.
        view.feed(text: "\u{1b}]133;A\u{7}prompt$ \u{1b}]133;B\u{7}")
        let armed = view.withTerminal { $0.buffer.semanticInput }
        #expect(armed == .armed)

        let sent = AsyncCountdown(1)
        DispatchQueue.global().async {
            inputSender.send(data: Array("ls\r".utf8)[...])
            sent.signal()
        }
        await sent.wait()

        let after = view.withTerminal { $0.buffer.semanticInput }
        #expect(after == .submitted)
    }

    /// One serial producer must reach the main-actor delegate in the same
    /// order. A separate unstructured task for each payload cannot guarantee
    /// this property.
    @MainActor
    @Test func serialBackgroundSendsPreserveDelegateOrder() async {
        let view = makeView()
        let inputSender = view.inputSender
        let delegate = RecordingDelegate()
        view.terminalDelegate = delegate
        let sent = AsyncCountdown(1)
        let expected = (0..<256).map { index in
            [UInt8(index >> 8), UInt8(index & 0xff)]
        }

        DispatchQueue.global().async {
            for payload in expected {
                inputSender.send(data: payload[...])
            }
            sent.signal()
        }
        await sent.wait()

        let deadline = ContinuousClock.now + .seconds(2)
        while delegate.receivedPayloads.count < expected.count,
              ContinuousClock.now < deadline {
            await Task.yield()
        }

        #expect(delegate.receivedPayloads == expected)
    }

    /// Sends that carry no submission must leave the prompt armed. This is the
    /// direction that matters: a wrong `submitted` costs a dead click, a wrong
    /// `armed` injects bytes into a child process.
    @MainActor
    @Test func nonSubmittingBackgroundSendLeavesPromptArmed() async {
        let view = makeView()
        let inputSender = view.inputSender

        view.feed(text: "\u{1b}]133;A\u{7}prompt$ \u{1b}]133;B\u{7}")
        let sent = AsyncCountdown(1)
        DispatchQueue.global().async {
            for byte in Array("ls -la".utf8) {
                inputSender.send(data: [byte][...])
            }
            sent.signal()
        }
        await sent.wait()

        let after = view.withTerminal { $0.buffer.semanticInput }
        #expect(after == .armed)
    }

    @MainActor
    @Test func viewStateAndBufferCopiesDoNotExposeLiveStorage() {
        let view = makeView()
        view.feed(text: "first")

        let first = view.terminalStateSnapshot()
        let firstText = first.visibleRows.map(\.text).joined(separator: "\n")
        #expect(first.dimensions == view.terminalDimensions)
        #expect(firstText.contains("first"))
        #expect(first.visibleRows.allSatisfy {
            $0.cellWidths.count == first.dimensions.cols
        })

        view.feed(text: "second")
        let currentText = view.terminalStateSnapshot().visibleRows
            .map(\.text).joined(separator: "\n")
        let bufferText = String(data: view.getBufferAsData(), encoding: .utf8)

        #expect(first.visibleRows.map(\.text).joined(separator: "\n") == firstText)
        #expect(!firstText.contains("second"))
        #expect(currentText.contains("firstsecond"))
        #expect(bufferText?.contains("firstsecond") == true)
    }

    @MainActor
    @Test func viewCommandsUpdateStateWithoutRawTerminalAccess() {
        let view = makeView()

        view.ansi256PaletteStrategy = .xterm
        view.maximumBidiParagraphRows = 7
        #expect(view.ansi256PaletteStrategy == .xterm)
        #expect(view.maximumBidiParagraphRows == 7)

        view.feed(text: "erase me")
        view.resetToInitialState()
        let visibleText = view.terminalStateSnapshot().visibleRows
            .map(\.text).joined(separator: "\n")
        #expect(!visibleText.contains("erase me"))
    }
}
#endif
