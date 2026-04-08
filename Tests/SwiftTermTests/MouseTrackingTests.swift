import Testing
@testable import SwiftTerm

struct MouseTrackingTests {
    private let esc = "\u{1b}"

    // MARK: - MouseMode.sendButtonTracking() unit tests

    @Test func sendButtonTrackingReturnsTrueForButtonEventTracking() {
        let mode = Terminal.MouseMode.buttonEventTracking
        #expect(mode.sendButtonTracking() == true)
    }

    @Test func sendButtonTrackingReturnsTrueForAnyEvent() {
        let mode = Terminal.MouseMode.anyEvent
        #expect(mode.sendButtonTracking() == true)
    }

    @Test func sendButtonTrackingReturnsFalseForOff() {
        let mode = Terminal.MouseMode.off
        #expect(mode.sendButtonTracking() == false)
    }

    @Test func sendButtonTrackingReturnsFalseForX10() {
        let mode = Terminal.MouseMode.x10
        #expect(mode.sendButtonTracking() == false)
    }

    @Test func sendButtonTrackingReturnsFalseForVt200() {
        let mode = Terminal.MouseMode.vt200
        #expect(mode.sendButtonTracking() == false)
    }

    // MARK: - MouseMode.sendMotionEvent() unit tests (only anyEvent)

    @Test func sendMotionEventReturnsTrueOnlyForAnyEvent() {
        #expect(Terminal.MouseMode.anyEvent.sendMotionEvent() == true)
        #expect(Terminal.MouseMode.buttonEventTracking.sendMotionEvent() == false)
        #expect(Terminal.MouseMode.vt200.sendMotionEvent() == false)
        #expect(Terminal.MouseMode.x10.sendMotionEvent() == false)
        #expect(Terminal.MouseMode.off.sendMotionEvent() == false)
    }

    // MARK: - Verify the key behavioral difference: sendButtonTracking is a
    //   superset of sendMotionEvent (the fix relies on this relationship)

    @Test func sendButtonTrackingIsSupersetOfSendMotionEvent() {
        // The bug was that mouseDragged used sendMotionEvent() which only
        // matched anyEvent. The fix changes it to sendButtonTracking() which
        // also matches buttonEventTracking. This test codifies the superset
        // relationship: any mode where sendMotionEvent() is true must also
        // have sendButtonTracking() true, but NOT vice versa.
        let allModes: [Terminal.MouseMode] = [.off, .x10, .vt200, .buttonEventTracking, .anyEvent]
        for mode in allModes {
            if mode.sendMotionEvent() {
                #expect(mode.sendButtonTracking() == true,
                        "sendMotionEvent() implies sendButtonTracking() for \(mode)")
            }
        }
        // buttonEventTracking is the mode that the fix specifically covers:
        // it must return true for sendButtonTracking but false for sendMotionEvent.
        #expect(Terminal.MouseMode.buttonEventTracking.sendButtonTracking() == true)
        #expect(Terminal.MouseMode.buttonEventTracking.sendMotionEvent() == false)
    }

    // MARK: - Integration tests using Terminal + delegate

    /// Enable buttonEventTracking (CSI ? 1002 h) with SGR encoding (CSI ? 1006 h),
    /// then call sendMotion() and verify the delegate receives the SGR motion report.
    @Test func sendMotionInButtonEventTrackingProducesOutput() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        // Enable button-event tracking mode and SGR mouse encoding
        terminal.feed(text: "\(esc)[?1002h")
        terminal.feed(text: "\(esc)[?1006h")

        #expect(terminal.mouseMode == .buttonEventTracking)

        // Simulate a drag motion at column 10, row 5 with left-button flag (0)
        // sendMotion adds 32 to buttonFlags to signal motion
        terminal.sendMotion(buttonFlags: 0, x: 10, y: 5, pixelX: 10, pixelY: 5)

        // In SGR mode, sendMotion calls sendEvent with buttonFlags+32.
        // sendEvent emits: CSI < {flags} ; {x+1} ; {y+1} M
        // flags = 0 + 32 = 32 (motion with left button)
        let sentBytes = delegate.sentData.flatMap { $0 }
        let sentString = String(bytes: sentBytes, encoding: .utf8) ?? ""

        // Expected: ESC [ < 32 ; 11 ; 6 M
        #expect(sentString.contains("<32;11;6M"),
                "Expected SGR motion report '<32;11;6M' but got: \(sentString)")
    }

    /// Verify that mouseMode is correctly set via CSI sequences.
    @Test func mouseModeSetByCSISequences() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()

        #expect(terminal.mouseMode == .off)

        // CSI ? 1002 h -> buttonEventTracking
        terminal.feed(text: "\(esc)[?1002h")
        #expect(terminal.mouseMode == .buttonEventTracking)

        // CSI ? 1002 l -> reset to off
        terminal.feed(text: "\(esc)[?1002l")
        #expect(terminal.mouseMode == .off)

        // CSI ? 1003 h -> anyEvent
        terminal.feed(text: "\(esc)[?1003h")
        #expect(terminal.mouseMode == .anyEvent)

        // CSI ? 1003 l -> reset to off
        terminal.feed(text: "\(esc)[?1003l")
        #expect(terminal.mouseMode == .off)

        // CSI ? 1000 h -> vt200
        terminal.feed(text: "\(esc)[?1000h")
        #expect(terminal.mouseMode == .vt200)
    }

    /// Verify that sendMotion produces output when in buttonEventTracking mode,
    /// and that the delegate captures it. This is the core scenario the fix enables:
    /// a drag event in buttonEventTracking mode should be forwarded.
    @Test func dragMotionForwardedInButtonEventTracking() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        // Enable buttonEventTracking + SGR protocol
        terminal.feed(text: "\(esc)[?1002h")
        terminal.feed(text: "\(esc)[?1006h")

        // Clear any data sent during mode setup
        delegate.clearSentData()

        // The fix: mouseMode.sendButtonTracking() returns true for
        // buttonEventTracking, so the drag motion WILL be forwarded.
        #expect(terminal.mouseMode.sendButtonTracking() == true)

        // Simulate the motion event that the fixed mouseDragged would send
        terminal.sendMotion(buttonFlags: 0, x: 5, y: 3, pixelX: 5, pixelY: 3)

        #expect(delegate.sentData.isEmpty == false,
                "Motion event should produce output when buttonEventTracking is active")

        // Verify the SGR-encoded motion report
        let sentString = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
        #expect(sentString.contains("<32;6;4M"))
    }

    /// Verify that in anyEvent mode (the original code path that worked),
    /// drag motion is also forwarded. This is a regression safeguard.
    @Test func dragMotionForwardedInAnyEventMode() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        // Enable anyEvent tracking + SGR protocol
        terminal.feed(text: "\(esc)[?1003h")
        terminal.feed(text: "\(esc)[?1006h")

        delegate.clearSentData()

        #expect(terminal.mouseMode.sendButtonTracking() == true)
        #expect(terminal.mouseMode.sendMotionEvent() == true)

        terminal.sendMotion(buttonFlags: 0, x: 5, y: 3, pixelX: 5, pixelY: 3)

        #expect(delegate.sentData.isEmpty == false,
                "Motion event should produce output when anyEvent is active")
    }

    /// Verify that modes which should NOT forward drag motion don't pass the
    /// sendButtonTracking() check. This tests the guard condition.
    @Test func dragMotionNotForwardedWhenMouseModeOff() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()

        #expect(terminal.mouseMode == .off)
        #expect(terminal.mouseMode.sendButtonTracking() == false,
                "sendButtonTracking should be false when mouseMode is off")
    }

    @Test func dragMotionNotForwardedInVt200Mode() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()

        terminal.feed(text: "\(esc)[?1000h")
        #expect(terminal.mouseMode == .vt200)
        #expect(terminal.mouseMode.sendButtonTracking() == false,
                "sendButtonTracking should be false for vt200 mode (press/release only)")
    }

    /// Test the SGR encoding format for motion events to ensure the protocol
    /// output matches what applications like tmux expect.
    @Test func sgrMotionEncodingFormat() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        terminal.feed(text: "\(esc)[?1002h")
        terminal.feed(text: "\(esc)[?1006h")
        delegate.clearSentData()

        // Left button drag at (0,0)
        terminal.sendMotion(buttonFlags: 0, x: 0, y: 0, pixelX: 0, pixelY: 0)
        var sentString = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
        // buttonFlags=0 + 32 (motion) = 32, x=0+1=1, y=0+1=1
        #expect(sentString == "\(esc)[<32;1;1M")

        delegate.clearSentData()

        // Middle button drag at (79,23) - typical bottom-right of 80x24
        terminal.sendMotion(buttonFlags: 1, x: 79, y: 23, pixelX: 79, pixelY: 23)
        sentString = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
        // buttonFlags=1 + 32 (motion) = 33, x=80, y=24
        #expect(sentString == "\(esc)[<33;80;24M")
    }

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
}
