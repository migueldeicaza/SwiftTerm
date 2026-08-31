#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
struct TerminalMouseEventTests {
    private final class Delegate: TerminalViewDelegate {
        var writes: [[UInt8]] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // This would recursively acquire TerminalLock if delivery happened
            // inside the encoding transaction.
            #expect(source.terminalInputStateSnapshot() != nil)
            writes.append(Array(data))
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    }

    @Test(arguments: [0, 1005, 1006, 1015, 1016])
    func matchesTerminalEncoding(protocolMode: Int) {
        let view = TerminalView(frame: .zero)
        let delegate = Delegate()
        view.terminalDelegate = delegate
        let (terminal, rawDelegate) = TerminalTestHarness.makeTerminal()
        let modes = "\u{1b}[?1000h" + (protocolMode == 0 ? "" : "\u{1b}[?\(protocolMode)h")
        view.feed(text: modes)
        terminal.feed(text: modes)
        for button in [0, 1, 2, 4, 5] {
            for release in [false, true] {
                let flags = terminal.encodeButton(button: button, release: release,
                                                   shift: true, meta: true, control: true)
                terminal.sendEvent(buttonFlags: flags, x: 400, y: 8, pixelX: 90, pixelY: 100)
                view.sendMouseEvent(button: button, release: release,
                                    shift: true, meta: true, control: true,
                                    col: 400, row: 8, pixelX: 90, pixelY: 100)
            }
        }
        #expect(delegate.writes == rawDelegate.sentData)
        switch protocolMode {
        case 0: #expect(delegate.writes.first == [27, 91, 77, 60, 255, 41])
        case 1005: #expect(delegate.writes.first == [27, 91, 77, 60, 0xc6, 0xb1, 41])
        case 1006: #expect(delegate.writes.first == Array("\u{1b}[<28;401;9M".utf8))
        case 1015: #expect(delegate.writes.first == Array("\u{1b}[60;401;9M".utf8))
        case 1016: #expect(delegate.writes.first == Array("\u{1b}[<28;90;100M".utf8))
        default: Issue.record("Unexpected test protocol")
        }
    }

    @Test func mouseReportsAreOrderedAndDoNotRegisterSemanticInput() {
        let view = TerminalView(frame: .zero)
        let delegate = Delegate()
        view.terminalDelegate = delegate
        view.allowMouseReporting = false
        view.feed(text: "\u{1b}[?1006h\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}input")
        view.send(Array("a".utf8))
        view.sendMouseEvent(button: 0, release: false, col: 4, row: 8)
        view.sendMouseEvent(button: 0, release: true, col: 4, row: 8)
        #expect(view.withTerminal { $0.buffer.semanticInput } == .armed)
        view.send([0x0d])
        #expect(delegate.writes == [Array("a".utf8), Array("\u{1b}[<0;5;9M".utf8),
                                    Array("\u{1b}[<0;5;9m".utf8), [0x0d]])
        #expect(view.withTerminal { $0.buffer.semanticInput } == .submitted)
    }

    private final class InputRecordingTerminal: Terminal {
        var registrations = 0
        override func registerUserInput(_ data: ArraySlice<UInt8>) {
            registrations += 1
            super.registerUserInput(data)
        }
    }

    @Test func mouseResponseNeverInvokesInputRegistration() {
        let view = TerminalView(frame: .zero)
        let delegate = Delegate()
        view.terminalDelegate = delegate
        let terminal = InputRecordingTerminal(delegate: view)
        view.renderOwner.attach(terminal: terminal,
                                selection: SelectionService(terminal: terminal),
                                search: SearchService(terminal: terminal))
        view.sendMouseEvent(button: 4, release: false, col: 0, row: 0)
        view.sendMouseEvent(button: 0, release: true, col: 0, row: 0)
        #expect(terminal.registrations == 0)
        view.send([0x0d])
        #expect(terminal.registrations == 1)
    }

    @Test(arguments: [-1, 3, 99, Int.min, Int.max])
    func unsupportedButtonsDoNotSend(button: Int) {
        let view = TerminalView(frame: .zero)
        let delegate = Delegate()
        view.terminalDelegate = delegate
        view.sendMouseEvent(button: button, release: false, col: 0, row: 0)
        view.sendMouseEvent(button: button, release: true, col: 0, row: 0)
        #expect(delegate.writes.isEmpty)
    }

    @Test func invalidCoordinatesDoNotTrapOrSend() {
        let view = TerminalView(frame: .zero)
        let delegate = Delegate()
        view.terminalDelegate = delegate
        view.sendMouseEvent(button: 0, release: false, col: -1, row: 0)
        view.sendMouseEvent(button: 0, release: false, col: Int.max, row: 0)
        view.sendMouseEvent(button: 0, release: false, col: 0, row: Int.max)
        view.sendMouseEvent(button: 0, release: false, col: 0, row: 0, pixelY: -1)
        #expect(delegate.writes.isEmpty)
    }
}
#endif
