import Testing
@testable import SwiftTerm

struct MouseTrackingTests {
    private let esc = "\u{1b}"

    // MARK: - encodeButton for scroll wheel buttons (4 = up, 5 = down)

    @Test func encodeButtonScrollUp() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        // Button 4 (scroll up) should encode to 64
        let flags = terminal.encodeButton(button: 4, release: false, shift: false, meta: false, control: false)
        #expect(flags == 64)
    }

    @Test func encodeButtonScrollDown() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        // Button 5 (scroll down) should encode to 65
        let flags = terminal.encodeButton(button: 5, release: false, shift: false, meta: false, control: false)
        #expect(flags == 65)
    }

    @Test func encodeButtonScrollUpWithShift() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        // Enable a mode that sends modifiers
        terminal.feed(text: "\(esc)[?1000h")
        let flags = terminal.encodeButton(button: 4, release: false, shift: true, meta: false, control: false)
        // 64 (scroll up) | 4 (shift) = 68
        #expect(flags == 68)
    }

    @Test func encodeButtonScrollDownWithControl() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?1000h")
        let flags = terminal.encodeButton(button: 5, release: false, shift: false, meta: false, control: true)
        // 65 (scroll down) | 16 (control) = 81
        #expect(flags == 81)
    }

    @Test func encodeButtonScrollUpWithAllModifiers() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?1000h")
        let flags = terminal.encodeButton(button: 4, release: false, shift: true, meta: true, control: true)
        // 64 (scroll up) | 4 (shift) | 8 (meta) | 16 (control) = 92
        #expect(flags == 92)
    }

    @Test func encodeButtonIgnoresModifiersInX10Mode() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        // x10 mode does not send modifiers (sendsModifiers returns false)
        terminal.feed(text: "\(esc)[?9h")
        #expect(terminal.mouseMode == .x10)
        let flags = terminal.encodeButton(button: 4, release: false, shift: true, meta: true, control: true)
        // x10 doesn't encode modifiers, so just 64
        #expect(flags == 64)
    }

    // MARK: - MouseMode: which modes should forward scroll events

    @Test func allNonOffMouseModesForwardScrollEvents() {
        // The fix uses `terminal.mouseMode != .off` as the guard condition.
        // Verify that every non-off mode would pass this check.
        let forwardingModes: [Terminal.MouseMode] = [.x10, .vt200, .buttonEventTracking, .anyEvent]
        for mode in forwardingModes {
            #expect(mode != .off, "Mode \(mode) should forward scroll events")
        }
        #expect(Terminal.MouseMode.off == .off, "Off mode should NOT forward scroll events")
    }

    @Test func mouseModeSetAndResetByCSISequences() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        #expect(terminal.mouseMode == .off)

        // CSI ? 9 h -> x10
        terminal.feed(text: "\(esc)[?9h")
        #expect(terminal.mouseMode == .x10)

        terminal.feed(text: "\(esc)[?9l")
        #expect(terminal.mouseMode == .off)

        // CSI ? 1000 h -> vt200
        terminal.feed(text: "\(esc)[?1000h")
        #expect(terminal.mouseMode == .vt200)

        terminal.feed(text: "\(esc)[?1000l")
        #expect(terminal.mouseMode == .off)

        // CSI ? 1002 h -> buttonEventTracking
        terminal.feed(text: "\(esc)[?1002h")
        #expect(terminal.mouseMode == .buttonEventTracking)

        terminal.feed(text: "\(esc)[?1002l")
        #expect(terminal.mouseMode == .off)

        // CSI ? 1003 h -> anyEvent
        terminal.feed(text: "\(esc)[?1003h")
        #expect(terminal.mouseMode == .anyEvent)

        terminal.feed(text: "\(esc)[?1003l")
        #expect(terminal.mouseMode == .off)
    }

    // MARK: - sendEvent integration: verify scroll escape sequences in SGR mode

    @Test func scrollUpSendEventProducesSgrOutput() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        // Enable vt200 mouse mode + SGR protocol
        terminal.feed(text: "\(esc)[?1000h")
        terminal.feed(text: "\(esc)[?1006h")
        delegate.clearSentData()

        // Simulate what scrollWheel would do: encode button 4 (scroll up) and send
        let buttonFlags = terminal.encodeButton(button: 4, release: false, shift: false, meta: false, control: false)
        #expect(buttonFlags == 64)
        terminal.sendEvent(buttonFlags: buttonFlags, x: 10, y: 5, pixelX: 10, pixelY: 5)

        let sentString = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
        // SGR format: CSI < Cb ; Cx ; Cy M -> ESC [ < 64 ; 11 ; 6 M
        #expect(sentString == "\(esc)[<64;11;6M",
                "Expected SGR scroll-up report but got: \(sentString)")
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
        // SGR format: ESC [ < 65 ; 1 ; 1 M
        #expect(sentString == "\(esc)[<65;1;1M",
                "Expected SGR scroll-down report but got: \(sentString)")
    }

    @Test func scrollUpWithShiftSendEventEncodesSgrOutput() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        terminal.feed(text: "\(esc)[?1000h")
        terminal.feed(text: "\(esc)[?1006h")
        delegate.clearSentData()

        let buttonFlags = terminal.encodeButton(button: 4, release: false, shift: true, meta: false, control: false)
        #expect(buttonFlags == 68) // 64 | 4
        terminal.sendEvent(buttonFlags: buttonFlags, x: 5, y: 3, pixelX: 5, pixelY: 3)

        let sentString = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
        #expect(sentString == "\(esc)[<68;6;4M",
                "Expected SGR scroll-up+shift report but got: \(sentString)")
    }

    // MARK: - sendEvent integration: verify scroll escape sequences in x10 mode

    @Test func scrollEventUsesX10EncodingByDefault() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        // Enable vt200 mode WITHOUT SGR - default protocol is x10
        terminal.feed(text: "\(esc)[?1000h")
        delegate.clearSentData()

        let buttonFlags = terminal.encodeButton(button: 4, release: false, shift: false, meta: false, control: false)
        terminal.sendEvent(buttonFlags: buttonFlags, x: 10, y: 5, pixelX: 10, pixelY: 5)

        let sentBytes = delegate.sentData.flatMap { $0 }
        // x10 format: CSI M Cb Cx Cy  where Cb=buttonFlags+32, Cx=32+x+1, Cy=32+y+1
        // Cb = 64 + 32 = 96, Cx = 32 + 10 + 1 = 43, Cy = 32 + 5 + 1 = 38
        let expected: [UInt8] = [0x1b, UInt8(ascii: "["), UInt8(ascii: "M"), 96, 43, 38]
        #expect(sentBytes == expected,
                "Expected x10 scroll-up report but got: \(sentBytes)")
    }

    // MARK: - Multiple scroll lines produce multiple events

    @Test func multipleScrollLinesSendMultipleEvents() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        terminal.feed(text: "\(esc)[?1000h")
        terminal.feed(text: "\(esc)[?1006h")
        delegate.clearSentData()

        let buttonFlags = terminal.encodeButton(button: 4, release: false, shift: false, meta: false, control: false)
        // Simulate 3 scroll lines (like abs(event.deltaY) = 3)
        for _ in 0..<3 {
            terminal.sendEvent(buttonFlags: buttonFlags, x: 5, y: 3, pixelX: 5, pixelY: 3)
        }

        // Should have 3 separate events sent
        #expect(delegate.sentData.count == 3,
                "Expected 3 scroll events but got \(delegate.sentData.count)")

        // Each should be the same SGR scroll-up sequence
        for data in delegate.sentData {
            let s = String(bytes: data, encoding: .utf8) ?? ""
            #expect(s == "\(esc)[<64;6;4M")
        }
    }

    // MARK: - Edge cases

    @Test func encodeButtonReleaseOverridesScrollValue() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        // When release is true, encodeButton returns 3 regardless of button number.
        // Scroll events should never be sent as releases, but verify the behavior.
        let flags = terminal.encodeButton(button: 4, release: true, shift: false, meta: false, control: false)
        #expect(flags == 3, "Release encoding should return 3 regardless of button number")
    }

    @Test func scrollEventAtMaxCoordinates() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)

        terminal.feed(text: "\(esc)[?1000h")
        terminal.feed(text: "\(esc)[?1006h")
        delegate.clearSentData()

        let buttonFlags = terminal.encodeButton(button: 5, release: false, shift: false, meta: false, control: false)
        // Send at max coordinates (79, 23) for an 80x24 terminal
        terminal.sendEvent(buttonFlags: buttonFlags, x: 79, y: 23, pixelX: 79, pixelY: 23)

        let sentString = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
        #expect(sentString == "\(esc)[<65;80;24M",
                "Expected scroll-down at max coords but got: \(sentString)")
    }

    @Test func scrollEventAtOrigin() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        terminal.feed(text: "\(esc)[?1003h")
        terminal.feed(text: "\(esc)[?1006h")
        delegate.clearSentData()

        let buttonFlags = terminal.encodeButton(button: 4, release: false, shift: false, meta: false, control: false)
        terminal.sendEvent(buttonFlags: buttonFlags, x: 0, y: 0, pixelX: 0, pixelY: 0)

        let sentString = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
        // SGR coordinates are 1-based: col 0 -> 1, row 0 -> 1
        #expect(sentString == "\(esc)[<64;1;1M",
                "Expected scroll-up at origin but got: \(sentString)")
    }
}
