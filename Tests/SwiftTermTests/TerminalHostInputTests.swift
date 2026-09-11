import Testing
@testable import SwiftTerm

struct TerminalHostInputTests {
    @Test(arguments: [0, 1, 2, 3, 8, 10, 24, 31])
    func committedTextUsesKeyboardModes(flags: Int) {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\u{1b}[>\(flags)u\u{1b}[?2004h\u{1b}[?5522h")
        delegate.clearSentData()
        #expect(terminal.sendHostText("日本"))
        let expected = flags & 24 == 24 ? "\u{1b}[0;;26085:26412u" : "日本"
        #expect(delegate.sentData.flatMap { $0 } == Array(expected.utf8))
        delegate.clearSentData()
        #expect(!terminal.sendHostText(""))
        #expect(delegate.sentData.isEmpty)
    }

    @Test func x10SendsOnlyPresses() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\u{1b}[?9h")
        #expect(terminal.mouseMode.sendButtonPress())
        #expect(!terminal.mouseMode.sendButtonRelease())
        #expect(terminal.sendHostMouse(action: .press, button: .left, modifiers: 15,
                                       col: 0, row: 0, pixelX: 0, pixelY: 0))
        #expect(!terminal.sendHostMouse(action: .release, button: .left, modifiers: 0,
                                        col: 0, row: 0, pixelX: 0, pixelY: 0))
        #expect(!terminal.sendHostMouse(action: .move, button: .left, modifiers: 0,
                                        col: 0, row: 0, pixelX: 0, pixelY: 0))
        #expect(delegate.sentData.flatMap { $0 } == [27, 91, 77, 32, 33, 33])
    }

    @Test(arguments: [TerminalMouseButton.left, .middle, .right])
    func sgrReleaseKeepsButton(button: TerminalMouseButton) {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        #expect(terminal.sendHostMouse(action: .release, button: button, modifiers: 15,
                                       col: 4, row: 7, pixelX: 40, pixelY: 140))
        let expected = "\u{1b}[<\(28 + button.rawValue);5;8m"
        #expect(delegate.sentData.flatMap { $0 } == Array(expected.utf8))
        delegate.clearSentData()
        let flags = terminal.encodeButton(button: Int(button.rawValue), release: true,
                                          shift: true, meta: true, control: true)
        terminal.sendEvent(buttonFlags: flags, x: 4, y: 7, pixelX: 40, pixelY: 140)
        #expect(delegate.sentData.flatMap { $0 } == Array(expected.utf8))
    }

    /// The protocol keeps a Cb of 3 for releases and for motion with no button.
    /// An extra physical button must never encode one of those.
    @Test func extraButtonPressIsNotEncodedAsARelease() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        let flags = terminal.encodeButton(button: 3, release: false,
                                          shift: false, meta: false, control: false)
        terminal.sendEvent(buttonFlags: flags, x: 2, y: 3, pixelX: 2, pixelY: 3)
        #expect(delegate.sentData.flatMap { $0 } == Array("\u{1b}[<0;3;4M".utf8))
    }

    @Test(arguments: [1005, 1006, 1015, 1016])
    func protocolCoordinatesAndRelease(mode: Int) {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\u{1b}[?1000h\u{1b}[?\(mode)h")
        #expect(terminal.sendHostMouse(action: .release, button: .right, modifiers: 0,
                                       col: 2, row: 3, pixelX: 20, pixelY: 60))
        let expected: String
        switch mode {
        case 1005: expected = "\u{1b}[M##$"
        case 1006: expected = "\u{1b}[<2;3;4m"
        case 1015: expected = "\u{1b}[35;3;4M"
        // Pixels reach the encoder zero based, exactly like the Apple views.
        default: expected = "\u{1b}[<2;20;60m"
        }
        #expect(delegate.sentData.flatMap { $0 } == Array(expected.utf8))
    }

    @Test func motionAndHorizontalWheel() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\u{1b}[?1002h\u{1b}[?1006h")
        #expect(!terminal.sendHostMouse(action: .move, button: .none, modifiers: 0,
                                        col: 0, row: 0, pixelX: 0, pixelY: 0))
        #expect(terminal.sendHostMouse(action: .move, button: .middle, modifiers: 0,
                                       col: 0, row: 0, pixelX: 0, pixelY: 0))
        terminal.feed(text: "\u{1b}[?1003h")
        #expect(terminal.sendHostMouse(action: .move, button: .none, modifiers: 0,
                                       col: 0, row: 0, pixelX: 0, pixelY: 0))
        #expect(terminal.sendHostMouse(action: .wheel, button: .wheelRight, modifiers: 0,
                                       col: 0, row: 0, pixelX: 0, pixelY: 0))
        #expect(delegate.sentData.flatMap { $0 } == Array("\u{1b}[<33;1;1M\u{1b}[<35;1;1M\u{1b}[<67;1;1M".utf8))
    }

    @Test func pointerModeState() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        #expect(terminal.hostPointerModes == 128)
        terminal.feed(text: "\u{1b}[?1003h\u{1b}[?1016h\u{1b}[>1s\u{1b}[?1049h")
        #expect(terminal.hostPointerModes == (4 | (4 << 3) | 64 | 128 | 256))
        terminal.feed(text: "\u{1b}[?1007l\u{1b}[?1049l\u{1b}[?1003l")
        #expect(terminal.hostPointerModes == ((4 << 3) | 64))
    }

    @Test func invalidMouseEventsSendNothing() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\u{1b}[?1003h")
        #expect(!terminal.sendHostMouse(action: .press, button: .none, modifiers: 0,
                                        col: 0, row: 0, pixelX: 0, pixelY: 0))
        #expect(!terminal.sendHostMouse(action: .press, button: .left, modifiers: 0,
                                        col: terminal.cols, row: 0, pixelX: 0, pixelY: 0))
        #expect(!terminal.sendHostMouse(action: .press, button: .left, modifiers: 0,
                                        col: 0, row: -1, pixelX: 0, pixelY: 0))
        #expect(delegate.sentData.isEmpty)
    }
}
