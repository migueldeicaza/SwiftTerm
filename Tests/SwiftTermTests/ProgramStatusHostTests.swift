#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

@Suite("Program status host delivery", .serialized)
struct ProgramStatusHostTests {
    @MainActor
    private final class Host: LocalProcessTerminalViewDelegate {
        var snapshots: [[TerminalProgramStatus]] = []
        var lockHeldDuringCallback = false
        var recordsAtExit: [TerminalProgramStatus] = []
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            recordsAtExit = source.programStatusRecords
        }
        func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {
            snapshots.append(records)
            lockHeldDuringCallback = source.terminal.terminalLock.isLockedByCurrentThread
        }
    }

    @Test @MainActor func updatesCombineAndForwardOutsideTheTerminalLock() {
        let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let host = Host()
        view.processDelegate = host
        view.eventQueue.drain()
        let priorDrains = view.eventQueue.drains
        for i in 0..<100 {
            view.feed(text: "\u{1b}]7501;state=working:progress=\(i)\u{7}")
        }
        #expect(view.programStatusRecords.first?.progress == 99)
        #expect(host.snapshots.isEmpty)
        #expect(view.eventQueue.drains == priorDrains)
        view.eventQueue.drain()
        #expect(host.snapshots.count == 1)
        #expect(host.snapshots.first?.first?.progress == 99)
        #expect(!host.lockHeldDuringCallback)
        view.clearProgramStatus()
        view.eventQueue.drain()
        #expect(host.snapshots.last == [])
        #expect(view.programStatusRecords.isEmpty)
    }

    @Test @MainActor func localExitClearsActiveStatusBeforeTheHostExitCallback() {
        let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let host = Host()
        view.processDelegate = host
        view.feed(text: "\u{1b}]7501;state=working\u{7}\u{1b}]7501;state=done:id=result\u{7}")
        view.processTerminated(view.process, exitCode: 0)
        #expect(host.recordsAtExit.map(\.state) == [.done])
        #expect(view.programStatusRecords.map(\.id) == ["result"])
        view.eventQueue.drain()
        #expect(host.snapshots.last?.map(\.state) == [.done])
    }

    @Test func headlessExitClearsActiveStatusBeforeTheEndCallback() {
        var recordsAtExit: [TerminalProgramStatus] = []
        var headless: HeadlessTerminal!
        headless = HeadlessTerminal { _ in
            headless.terminal.terminalLock.withLock {
                recordsAtExit = headless.terminal.programStatusRecords
            }
        }
        let data = Array("\u{1b}]7501;state=blocked\u{7}\u{1b}]7501;state=error:id=result\u{7}".utf8)
        headless.dataReceived(slice: data[...])
        headless.processTerminated(headless.process, exitCode: 1)
        #expect(recordsAtExit.map(\.state) == [.error])
        // Release the callback's reference after the test.
        headless = nil
    }
}
#endif
