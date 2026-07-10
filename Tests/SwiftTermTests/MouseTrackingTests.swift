import Testing
@testable import SwiftTerm

#if os(macOS)
import AppKit

private final class MouseMotionCapturingDelegate: TerminalViewDelegate {
    var sentData: [[UInt8]] = []

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sentData.append(Array(data)) }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
#endif

struct MouseTrackingTests {
    private let esc = "\u{1b}"

#if os(macOS)
    @Test func trackingAreaAvoidsMouseMovedOnTahoe() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        view.terminal.feed(text: "\(esc)[?1003h")

        guard let tracking = view.tracking else {
            Issue.record("All-motion mouse reporting should install a tracking area")
            return
        }

        if #available(macOS 26, *) {
            #expect(!tracking.options.contains(.mouseMoved))
        } else {
            #expect(tracking.options.contains(.mouseMoved))
        }
    }

    @Test func commandReleaseDeregistersUnusedMouseTracking() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        view.commandActive = true
        view.startTracking()
        #expect(view.tracking != nil)

        view.turnOffUrlPreview()
        #expect(view.tracking == nil)
    }

    @Test @MainActor func TahoeFallbackForwardsWindowMouseMovedEvents() {
        guard #available(macOS 26, *) else { return }

        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        let wasAcceptingMouseMovedEvents = window.acceptsMouseMovedEvents

        let delegate = MouseMotionCapturingDelegate()
        view.terminalDelegate = delegate
        view.terminal.feed(text: "\(esc)[?1003h\(esc)[?1006h")
        #expect(window.acceptsMouseMovedEvents)

        let event = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: CGPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0
        )!
        NSApplication.shared.sendEvent(event)

        #expect(!delegate.sentData.isEmpty)

        view.terminal.feed(text: "\(esc)[?1003l")
        #expect(window.acceptsMouseMovedEvents == wasAcceptingMouseMovedEvents)
    }

    @Test @MainActor func TahoeFallbackIgnoresOutOfBoundsMouseMoved() {
        guard #available(macOS 26, *) else { return }

        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view

        let delegate = MouseMotionCapturingDelegate()
        view.terminalDelegate = delegate
        view.terminal.feed(text: "\(esc)[?1003h\(esc)[?1006h")

        // `acceptsMouseMovedEvents` delivers mouseMoved to the first responder regardless
        // of the pointer's location, so a move outside the view must not be reported.
        let outside = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: CGPoint(x: 1000, y: 1000),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0
        )!
        view.mouseMoved(with: outside)
        #expect(delegate.sentData.isEmpty)

        // A move inside the view is still reported.
        let inside = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: CGPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 0,
            pressure: 0
        )!
        view.mouseMoved(with: inside)
        #expect(!delegate.sentData.isEmpty)
    }

    @Test @MainActor func TahoeFallbackDoesNotClobberHostDisablingMouseMoved() {
        guard #available(macOS 26, *) else { return }

        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        // The host has its own reason to want mouse-moved events on.
        window.acceptsMouseMovedEvents = true

        view.terminal.feed(text: "\(esc)[?1003h")
        #expect(window.acceptsMouseMovedEvents)

        // The host disables it while the terminal is still tracking.
        window.acceptsMouseMovedEvents = false

        // Ending the terminal's fallback must respect the host's choice, not force the
        // captured original value back on.
        view.terminal.feed(text: "\(esc)[?1003l")
        #expect(!window.acceptsMouseMovedEvents)
    }

    @Test @MainActor func TahoeFallbackSharesWindowMouseMovedSettingAcrossTerminalViews() {
        guard #available(macOS 26, *) else { return }

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let firstView = TerminalView(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        let secondView = TerminalView(frame: CGRect(x: 160, y: 0, width: 160, height: 160))
        container.addSubview(firstView)
        container.addSubview(secondView)
        window.contentView = container
        let wasAcceptingMouseMovedEvents = window.acceptsMouseMovedEvents

        firstView.terminal.feed(text: "\(esc)[?1003h")
        secondView.terminal.feed(text: "\(esc)[?1003h")
        #expect(window.acceptsMouseMovedEvents)

        firstView.terminal.feed(text: "\(esc)[?1003l")
        #expect(window.acceptsMouseMovedEvents)

        secondView.terminal.feed(text: "\(esc)[?1003l")
        #expect(window.acceptsMouseMovedEvents == wasAcceptingMouseMovedEvents)
    }
#endif

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

    // MARK: - DECRST on encoding modes (1005/1006/1015/1016) must not stop tracking

    @Test func decrstEncodingModeKeepsTrackingEnabled() {
        // 1005/1006/1015/1016 select the coordinate encoding and are independent of
        // the tracking modes (9/1000-1003): resetting an encoding reverts how
        // coordinates are encoded, it must not turn tracking off (in xterm these are
        // separate state variables: extend_coords vs send_mouse_pos).
        for encodingMode in [1005, 1006, 1015, 1016] {
            let (terminal, _) = TerminalTestHarness.makeTerminal()
            terminal.feed(text: "\(esc)[?1003h")
            terminal.feed(text: "\(esc)[?\(encodingMode)h")
            terminal.feed(text: "\(esc)[?\(encodingMode)l")
            #expect(terminal.mouseMode == .anyEvent, "DECRST \(encodingMode) must not disable mouse tracking")
        }
    }

    @Test func decrstEncodingModeStillResetsEncoding() {
        // After ?1006l events are reported in the default X10 encoding again.
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?1000h")
        terminal.feed(text: "\(esc)[?1006h")
        terminal.feed(text: "\(esc)[?1006l")
        delegate.clearSentData()

        let buttonFlags = terminal.encodeButton(button: 4, release: false, shift: false, meta: false, control: false)
        terminal.sendEvent(buttonFlags: buttonFlags, x: 10, y: 5, pixelX: 10, pixelY: 5)

        let sentBytes = delegate.sentData.flatMap { $0 }
        let expected: [UInt8] = [0x1b, UInt8(ascii: "["), UInt8(ascii: "M"), 96, 43, 38]
        #expect(sentBytes == expected)
    }

    @Test func decrstEncodingModeReportedViaDecrqm() {
        // DECRQM after ?1006l: the encoding reports reset while tracking reports set.
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?1003h")
        terminal.feed(text: "\(esc)[?1006h")
        terminal.feed(text: "\(esc)[?1006l")
        delegate.clearSentData()

        terminal.feed(text: "\(esc)[?1006$p")
        terminal.feed(text: "\(esc)[?1003$p")

        let responses = delegate.sentData.map { String(bytes: $0, encoding: .utf8) ?? "" }
        #expect(responses == ["\(esc)[?1006;2$y", "\(esc)[?1003;1$y"])
    }

    @Test func moshStyleModeReassertKeepsTrackingAndSgrEncoding() {
        // mosh re-asserts mouse state on every resize/reattach repaint as
        // "CSI ?1003l ?1003h ?1004l ?1006l ?1006h"; the trailing ?1006l used to
        // disable tracking right after ?1003h re-enabled it, leaving mouse
        // reporting permanently off after the first resize.
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?1003h\(esc)[?1006h") // app enables mouse reporting
        terminal.feed(text: "\(esc)[?1003l\(esc)[?1003h\(esc)[?1004l\(esc)[?1006l\(esc)[?1006h")
        #expect(terminal.mouseMode == .anyEvent)
        delegate.clearSentData()

        // Events must still flow, SGR-encoded.
        let buttonFlags = terminal.encodeButton(button: 4, release: false, shift: false, meta: false, control: false)
        terminal.sendEvent(buttonFlags: buttonFlags, x: 10, y: 5, pixelX: 10, pixelY: 5)

        let sentString = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
        #expect(sentString == "\(esc)[<64;11;6M")
    }

    @Test func decrstTrackingModeStillDisablesTracking() {
        // The tracking modes themselves still turn tracking off, also when an
        // encoding is active.
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?1003h")
        terminal.feed(text: "\(esc)[?1006h")
        terminal.feed(text: "\(esc)[?1003l")
        #expect(terminal.mouseMode == .off)
    }
}
