import Foundation
import Testing
@testable import SwiftTerm

final class TerminalLockingTests {
    private final class TestDelegate: TerminalDelegate {
        func showCursor(source: Terminal) {}
        func hideCursor(source: Terminal) {}
        func setTerminalTitle(source: Terminal, title: String) {}
        func setTerminalIconTitle(source: Terminal, title: String) {}
        func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { nil }
        func sizeChanged(source: Terminal) {}
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func scrolled(source: Terminal, yDisp: Int) {}
        func linefeed(source: Terminal) {}
        func bufferActivated(source: Terminal) {}
        func synchronizedOutputChanged(source: Terminal, active: Bool) {}
        func bell(source: Terminal) {}
        func selectionChanged(source: Terminal) {}
        func isProcessTrusted(source: Terminal) -> Bool { true }
        func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? { nil }
        func mouseModeChanged(source: Terminal) {}
        func setForegroundColor(source: Terminal, color: Color) {}
        func setBackgroundColor(source: Terminal, color: Color) {}
        func setCursorColor(source: Terminal, color: Color?, textColor: Color?) {}
        func colorChanged(source: Terminal, idx: Int?) {}
        func hostCurrentDirectoryUpdated(source: Terminal) {}
        func iTermContent(source: Terminal, content: ArraySlice<UInt8>) {}
        func clipboardCopy(source: Terminal, content: Data) {}
        func clipboardRead(source: Terminal) -> Data? { nil }
        func progressReport(source: Terminal, report: Terminal.ProgressReport) {}
        func getColors(source: Terminal) -> (foreground: Color, background: Color) {
            (Color.defaultForeground, Color.defaultBackground)
        }
    }

    private final class StopFlag {
        private let lock = NSLock()
        private var stopped = false

        func stop () {
            lock.lock()
            stopped = true
            lock.unlock()
        }

        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }
    }

    @Test func hammerBackgroundFeedAndReadersUnderTerminalLock() {
        let terminal = Terminal(delegate: TestDelegate(), options: TerminalOptions(cols: 40, rows: 12, scrollback: 80))
        let stop = StopFlag()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var i = 0
            while !stop.isStopped {
                terminal.terminalLock.withLock {
                    terminal.feed(text: "feed \(i) abcdefghijklmnopqrstuvwxyz\r\n")
                }
                i += 1
            }
            group.leave()
        }

        for reader in 0..<2 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var toggled = false
                while !stop.isStopped {
                    terminal.terminalLock.withLock {
                        let buffer = terminal.displayBuffer
                        let rows = min(buffer.lines.count, max(buffer.rows, 1))
                        for row in 0..<rows {
                            let line = buffer.lines[row]
                            if line.count > 0 {
                                _ = line[min(line.count - 1, reader)]
                            }
                        }
                        _ = terminal.getUpdateRange()
                        terminal.clearUpdateRange()
                        terminal.resize(cols: toggled ? 40 : 42, rows: toggled ? 12 : 13)
                        toggled.toggle()
                        let maxScroll = max(0, terminal.displayBuffer.lines.count - terminal.displayBuffer.rows)
                        terminal.setViewYDisp(min(maxScroll, reader))
                    }
                }
                group.leave()
            }
        }

        Thread.sleep(forTimeInterval: 2.0)
        stop.stop()
        #expect(group.wait(timeout: .now() + 5) == .success)

        terminal.terminalLock.withLock {
            terminal.resize(cols: 40, rows: 12)
            terminal.feed(text: "\u{1b}[2J\u{1b}[HLOCK-FINAL")
            let row = terminal.displayBuffer.yBase
            let text = terminal.getDisplayText(start: Position(col: 0, row: row), end: Position(col: 10, row: row))
            #expect(text.hasPrefix("LOCK-FINAL"))
        }
    }

    @Test func synchronizedOutputTimeoutClearsUnderBackgroundFeedLock() {
        let terminal = Terminal(delegate: TestDelegate(), options: TerminalOptions(cols: 40, rows: 10, scrollback: 20))
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            terminal.terminalLock.withLock {
                terminal.feed(text: "\u{1b}[?2026h")
            }
            group.leave()
        }

        #expect(group.wait(timeout: .now() + 2) == .success)

        let until = Date().addingTimeInterval(1.5)
        while Date() < until {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            let active = terminal.terminalLock.withLock {
                terminal.synchronizedOutputActive
            }
            if !active {
                break
            }
        }

        let active = terminal.terminalLock.withLock {
            terminal.synchronizedOutputActive
        }
        #expect(!active)
    }
}
