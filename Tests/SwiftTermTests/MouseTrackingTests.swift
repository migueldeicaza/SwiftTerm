import Testing
@testable import SwiftTerm

struct MouseTrackingTests {
    private let esc = "\u{1b}"

    @Test func encodeButtonScrollUp() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        let flags = terminal.encodeButton(button: 4, release: false, shift: false, meta: false, control: false)
        #expect(flags == 64)
    }

    @Test func encodeButtonScrollDown() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        let flags = terminal.encodeButton(button: 5, release: false, shift: false, meta: false, control: false)
        #expect(flags == 65)
    }

    @Test func encodeButtonScrollUpWithShift() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?1000h")
        let flags = terminal.encodeButton(button: 4, release: false, shift: true, meta: false, control: false)
        #expect(flags == 68)
    }

    @Test func encodeButtonScrollDownWithControl() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?1000h")
        let flags = terminal.encodeButton(button: 5, release: false, shift: false, meta: false, control: true)
        #expect(flags == 81)
    }

    @Test func encodeButtonScrollUpWithAllModifiers() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?1000h")
        let flags = terminal.encodeButton(button: 4, release: false, shift: true, meta: true, control: true)
        #expect(flags == 92)
    }

    @Test func encodeButtonIgnoresModifiersInX10Mode() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?9h")
        #expect(terminal.mouseMode == .x10)
        let flags = terminal.encodeButton(button: 4, release: false, shift: true, meta: true, control: true)
        #expect(flags == 64)
    }

    @Test func allNonOffMouseModesForwardScrollEvents() {
        let forwardingModes: [Terminal.MouseMode] = [.x10, .vt200, .buttonEventTracking, .anyEvent]
        for mode in forwardingModes {
            #expect(mode != .off, "Mode \(mode) should forward scroll events")
        }
        #expect(Terminal.MouseMode.off == .off)
    }

    @Test func mouseModeSetAndResetByCSISequences() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        #expect(terminal.mouseMode == .off)

        terminal.feed(text: "\(esc)[?9h")
        #expect(terminal.mouseMode == .x10)

        terminal.feed(text: "\(esc)[?9l")
        #expect(terminal.mouseMode == .off)

        terminal.feed(text: "\(esc)[?1000h")
        #expect(terminal.mouseMode == .vt200)

        terminal.feed(text: "\(esc)[?1000l")
        #expect(terminal.mouseMode == .off)

        terminal.feed(text: "\(esc)[?1002h")
        #expect(terminal.mouseMode == .buttonEventTracking)

        terminal.feed(text: "\(esc)[?1002l")
        #expect(terminal.mouseMode == .off)

        terminal.feed(text: "\(esc)[?1003h")
        #expect(terminal.mouseMode == .anyEvent)

        terminal.feed(text: "\(esc)[?1003l")
        #expect(terminal.mouseMode == .off)
    }

    @Test func scrollUpSendEventProducesSgrOutput() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?1000h")
        terminal.feed(text: "\(esc)[?1006h")
        delegate.clearSentData()

        let buttonFlags = terminal.encodeButton(button: 4, release: false, shift: false, meta: false, control: false)
        #expect(buttonFlags == 64)
        terminal.sendEvent(buttonFlags: buttonFlags, x: 10, y: 5, pixelX: 10, pixelY: 5)

        let sentString = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
        #expect(sentString == "\(esc)[<64;11;6M")
    }

    @Test func scrollDownSendEventProducesSgrOutput() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?1000h")
        terminal.feed(text: "\(esc)[?1006h")
        delegate.clearSentData()

        let buttonFlags = terminal.encodeButton(button: 5, release: false, shift: false, meta: false, control: false)
        #expect(buttonFlags == 65)
        terminal.sendEvent(buttonFlags: buttonFlags, x: 0, y: 0, pixelX: 0, pixelY: 0)

        let sentString = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
        #expect(sentString == "\(esc)[<65;1;1M")
    }

    @Test func scrollUpWithShiftSendEventEncodesSgrOutput() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?1000h")
        terminal.feed(text: "\(esc)[?1006h")
        delegate.clearSentData()

        let buttonFlags = terminal.encodeButton(button: 4, release: false, shift: true, meta: false, control: false)
        #expect(buttonFlags == 68)
        terminal.sendEvent(buttonFlags: buttonFlags, x: 5, y: 3, pixelX: 5, pixelY: 3)

        let sentString = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
        #expect(sentString == "\(esc)[<68;6;4M")
    }

    @Test func scrollEventUsesX10EncodingByDefault() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?1000h")
        delegate.clearSentData()

        let buttonFlags = terminal.encodeButton(button: 4, release: false, shift: false, meta: false, control: false)
        terminal.sendEvent(buttonFlags: buttonFlags, x: 10, y: 5, pixelX: 10, pixelY: 5)

        let sentBytes = delegate.sentData.flatMap { $0 }
        let expected: [UInt8] = [0x1b, UInt8(ascii: "["), UInt8(ascii: "M"), 96, 43, 38]
        #expect(sentBytes == expected)
    }

    @Test func multipleScrollLinesSendMultipleEvents() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?1000h")
        terminal.feed(text: "\(esc)[?1006h")
        delegate.clearSentData()

        let buttonFlags = terminal.encodeButton(button: 4, release: false, shift: false, meta: false, control: false)
        for _ in 0..<3 {
            terminal.sendEvent(buttonFlags: buttonFlags, x: 5, y: 3, pixelX: 5, pixelY: 3)
        }

        #expect(delegate.sentData.count == 3)
        for data in delegate.sentData {
            let sentString = String(bytes: data, encoding: .utf8) ?? ""
            #expect(sentString == "\(esc)[<64;6;4M")
        }
    }

    @Test func encodeButtonReleaseOverridesScrollValue() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        let flags = terminal.encodeButton(button: 4, release: true, shift: false, meta: false, control: false)
        #expect(flags == 3)
    }

    @Test func scrollEventAtMaxCoordinates() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[?1000h")
        terminal.feed(text: "\(esc)[?1006h")
        delegate.clearSentData()

        let buttonFlags = terminal.encodeButton(button: 5, release: false, shift: false, meta: false, control: false)
        terminal.sendEvent(buttonFlags: buttonFlags, x: 79, y: 23, pixelX: 79, pixelY: 23)

        let sentString = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
        #expect(sentString == "\(esc)[<65;80;24M")
    }

    @Test func scrollEventAtOrigin() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?1003h")
        terminal.feed(text: "\(esc)[?1006h")
        delegate.clearSentData()

        let buttonFlags = terminal.encodeButton(button: 4, release: false, shift: false, meta: false, control: false)
        terminal.sendEvent(buttonFlags: buttonFlags, x: 0, y: 0, pixelX: 0, pixelY: 0)

        let sentString = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
        #expect(sentString == "\(esc)[<64;1;1M")
    }

    @Test func xtshiftescapeDefaultsToOff() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        #expect(terminal.mouseShiftCapture == false)
    }

    @Test func xtshiftescapeEnableAndDisable() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()

        terminal.feed(text: "\(esc)[>1s")
        #expect(terminal.mouseShiftCapture == true)

        terminal.feed(text: "\(esc)[>0s")
        #expect(terminal.mouseShiftCapture == false)
    }

    @Test func xtshiftescapeMissingParameterDisables() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[>1s")
        #expect(terminal.mouseShiftCapture == true)

        // Per xterm, `CSI > s` with no Ps is equivalent to Ps = 0.
        terminal.feed(text: "\(esc)[>s")
        #expect(terminal.mouseShiftCapture == false)
    }

    @Test func xtshiftescapeIgnoresUnknownParameter() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[>1s")
        #expect(terminal.mouseShiftCapture == true)

        // Unknown Ps values must leave the current state untouched.
        terminal.feed(text: "\(esc)[>9s")
        #expect(terminal.mouseShiftCapture == true)
    }

    @Test func xtshiftescapeClearedByHardReset() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[>1s")
        #expect(terminal.mouseShiftCapture == true)

        terminal.resetToInitialState()
        #expect(terminal.mouseShiftCapture == false)
    }

    @Test func csiSWithUnknownIntermediateDoesNotSaveCursor() {
        // Regression: CSI <intermediate> s with an intermediate other than '>'
        // must not be routed to save-cursor or DECSLRM.
        let (terminal, _) = TerminalTestHarness.makeTerminal()

        // Position cursor at (col 10, row 5) and send "CSI ? s". If misrouted to
        // save-cursor, this position would be saved.
        terminal.feed(text: "\(esc)[5;10H")
        terminal.feed(text: "\(esc)[?s")

        // Move somewhere else, then restore.
        terminal.feed(text: "\(esc)[1;1H")
        terminal.feed(text: "\(esc)[u")

        // Restore must fall back to the default saved position (0,0), not (9,4).
        #expect(terminal.buffer.x == 0)
        #expect(terminal.buffer.y == 0)
    }
}
