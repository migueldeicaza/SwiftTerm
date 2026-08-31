#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct ProcessOutputConsumerTests {
    private final class Delegate: LocalProcessTerminalViewDelegate {
        var exits = 0
        var onExit: (() -> Void)?
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            #expect(Thread.isMainThread)
            #expect(exitCode == 0)
            exits += 1
            onExit?()
        }
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }

    private final class Capture {
        var bytes: [UInt8] = []
        var batches = 0
        var events: [String] = []
    }

    private func waitForExit(_ delegate: Delegate, count: Int = 1) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while delegate.exits < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(delegate.exits == count)
    }

    @Test func actualPTYOutputIsConsumedExactlyOnceWithoutAutomaticFeed() async throws {
        let view = LocalProcessTerminalView(frame: .zero)
        let delegate = Delegate()
        view.processDelegate = delegate
        let capture = Capture()
        let handled = Locked(0)
        view.setProcessOutputHandler { handled.withLock { $0 += 1 } }
        try view.setProcessOutputConsumer { bytes in
            #expect(Thread.isMainThread)
            #expect(bytes.count <= 65_536)
            capture.bytes += bytes
            capture.batches += 1
        }
        view.startProcess(executable: "/bin/sh", args: ["-c", "printf consumer-output"], environment: [])
        await waitForExit(delegate)
        #expect(capture.bytes == Array("consumer-output".utf8))
        #expect(capture.batches > 0)
        #expect(handled.withLock { $0 } == capture.batches)
        #expect(view.terminalContentSnapshot(region: .viewport)?.rows.allSatisfy { $0.text.isEmpty } == true)
        view.feed(byteArray: capture.bytes[...])
        #expect(view.terminalContentSnapshot(region: .viewport)?.rows.first?.text == "consumer-output")
        #expect(capture.bytes == Array("consumer-output".utf8), "Replay must bypass the consumer")
        #expect(view.diagnostics.bytesFed == capture.bytes.count)
    }

    @Test func consumerCanFeedWithoutLockRecursionAndRejectsActiveChanges() async throws {
        let view = LocalProcessTerminalView(frame: .zero)
        let delegate = Delegate()
        view.processDelegate = delegate
        let capture = Capture()
        try view.setProcessOutputConsumer { [weak view] bytes in
            capture.bytes += bytes
            view?.feed(byteArray: bytes[...])
        }
        view.startProcess(executable: "/bin/sh", args: ["-c", "read line; printf fed-once"], environment: [])
        #expect(throws: ProcessOutputConsumerError.self) {
            try view.setProcessOutputConsumer(nil)
        }
        view.send([0x0d])
        await waitForExit(delegate)
        #expect(String(decoding: capture.bytes, as: UTF8.self).contains("fed-once"))
        #expect(view.diagnostics.bytesFed == capture.bytes.count)
        try view.setProcessOutputConsumer(nil)
    }

    @Test func blockedMainTimeoutKeepsOutputBeforeTerminationAndRelaunch() async throws {
        let view = LocalProcessTerminalView(frame: .zero)
        let delegate = Delegate()
        view.processDelegate = delegate
        view.process.drainTimeout = 0.2
        let capture = Capture()
        try view.setProcessOutputConsumer { bytes in
            capture.bytes += bytes
            capture.events.append(String(decoding: bytes, as: UTF8.self))
        }
        delegate.onExit = { [weak view, weak delegate] in
            capture.events.append("exit")
            if delegate?.exits == 1 {
                view?.startProcess(executable: "/bin/sh", args: ["-c", "printf second"], environment: [])
            }
        }
        let releaseHandled = DispatchSemaphore(value: 0)
        let handled = Locked(0)
        view.setProcessOutputHandler {
            let first = handled.withLock { count in
                count += 1
                return count == 1
            }
            if first { _ = releaseHandled.wait(timeout: .now() + 3) }
        }
        defer { releaseHandled.signal() }
        view.startProcess(executable: "/bin/sh", args: ["-c", "printf first"], environment: [])
        // Hold the parse worker after its first consumer returns. Let the
        // main-queue exit monitor start the drain, then block main so its
        // termination callback remains queued when the drain times out.
        let exitDeadline = ContinuousClock.now + .seconds(2)
        while (view.process.shellPid != 0 || handled.withLock { $0 } == 0),
              ContinuousClock.now < exitDeadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(view.process.shellPid == 0)
        blockMainUntilWindingDown(view.process)
        #expect(view.process.windingDown)
        #expect(capture.bytes == Array("first".utf8))
        #expect(delegate.exits == 0)
        #expect(throws: ProcessOutputConsumerError.self) {
            try view.setProcessOutputConsumer(nil)
        }
        releaseHandled.signal()
        await waitForExit(delegate, count: 2)
        #expect(capture.bytes == Array("firstsecond".utf8))
        #expect(capture.events == ["first", "exit", "second", "exit"])
        #expect(view.process.shellPid == 0)
        #expect(!view.process.running)
        #expect(!view.process.windingDown)
    }

    private func blockMainUntilWindingDown(_ process: LocalProcess) {
        let deadline = Date().addingTimeInterval(2)
        while !process.windingDown, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    @Test func nilConsumerRetainsAutomaticBackgroundParsing() async throws {
        let view = LocalProcessTerminalView(frame: .zero)
        let delegate = Delegate()
        view.processDelegate = delegate
        try view.setProcessOutputConsumer(nil)
        view.startProcess(executable: "/bin/sh", args: ["-c", "printf automatic"], environment: [])
        await waitForExit(delegate)
        #expect(view.terminalContentSnapshot(region: .viewport)?.rows.first?.text == "automatic")
        #expect(view.diagnostics.bytesFed == "automatic".utf8.count)
    }
}
#endif
