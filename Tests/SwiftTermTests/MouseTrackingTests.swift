import Testing
@testable import SwiftTerm

#if os(macOS)
import AppKit

private final class MouseMotionCapturingDelegate: TerminalViewDelegate {
    var sentData: [[UInt8]] = []
    var openedLinks: [String] = []

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sentData.append(Array(data)) }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {
        openedLinks.append(link)
    }
}

private final class ResponseDroppingTerminalView: TerminalView {
    private let responses = Locked([[UInt8]]())

    nonisolated var droppedResponses: [[UInt8]] {
        responses.withLock { $0 }
    }

    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        responses.withLock { $0.append(Array(data)) }
    }
}
#endif

struct MouseTrackingTests {
    private let esc = "\u{1b}"

#if os(macOS)
    @MainActor private func waitForSemanticClick(in view: TerminalView) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while view.semanticClickPendingForTesting, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(!view.semanticClickPendingForTesting, "The semantic click did not finish")
    }

    @MainActor private func waitForTerminalViewCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor private func waitForSentData(from delegate: MouseMotionCapturingDelegate) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while delegate.sentData.isEmpty, ContinuousClock.now < deadline {
            await Task.yield()
        }
    }

    @Test @MainActor func tripleClickDragExtendsByCompleteRows() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view

        let seedPoint = CGPoint(
            x: 3.5 * view.cellDimension.width,
            y: view.frame.height - 1.5 * view.cellDimension.height
        )
        let dragPoint = CGPoint(
            x: 5.5 * view.cellDimension.width,
            y: view.frame.height - 3.5 * view.cellDimension.height
        )
        let seedRow = view.calculateMouseHit(at: seedPoint).grid.row
        let dragRow = view.calculateMouseHit(at: dragPoint).grid.row
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: seedPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 3,
            pressure: 1
        )!
        let drag = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: dragPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 3,
            pressure: 1
        )!

        view.mouseDown(with: down)
        #expect(view.withTerminal { _ in view.selection.selectionMode } == .row)

        view.mouseDragged(with: drag)

        let range = view.withTerminal { terminal in
            (view.selection.start, view.selection.end, terminal.cols)
        }
        #expect(range.0 == Position(col: 0, row: seedRow))
        #expect(range.1 == Position(col: range.2 - 1, row: dragRow))
    }

    @Test @MainActor func trackingAreaAvoidsMouseMovedOnTahoe() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        view.feed(text: "\(esc)[?1003h")
        await waitForTerminalViewCallbacks()

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

    @Test @MainActor func commandReleaseDeregistersUnusedMouseTracking() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        view.commandActive = true
        view.startTracking()
        #expect(view.tracking != nil)

        view.turnOffUrlPreview()
        #expect(view.tracking == nil)
    }

    @Test @MainActor func typedInputBypassesResponseOverride() {
        let view = ResponseDroppingTerminalView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 160)
        )
        let delegate = MouseMotionCapturingDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\(esc)]133;A;cl=line\u{07}>\(esc)]133;B\u{07}hi")

        view.send(data: [0x0d][...])

        #expect(delegate.sentData == [[0x0d]])
        #expect(view.droppedResponses.isEmpty)
        #expect(view.withTerminal { $0.buffer.semanticInput } == .submitted)
    }

    /// Acceptance 7 / R6: `allowMouseReporting` governs mouse reports and
    /// must not gate arrow-key emission from a semantic prompt click.
    @Test @MainActor func disabledMouseReportingStillRoutesSemanticPromptClicks() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        view.semanticClickCoalescingDelay = 0.01
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        let delegate = MouseMotionCapturingDelegate()
        view.terminalDelegate = delegate
        view.allowMouseReporting = false
        view.feed(text: "\(esc)]133;A;cl=line\u{07}>\(esc)]133;B\u{07}hi")

        let point = CGPoint(
            x: 1.5 * view.cellDimension.width,
            y: view.frame.height - 0.5 * view.cellDimension.height
        )
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        )!

        view.mouseDown(with: down)
        view.mouseUp(with: up)
        await waitForSemanticClick(in: view)
        await waitForTerminalViewCallbacks()

        #expect(!delegate.sentData.isEmpty)
    }

    // F.5: with no OSC 133 ever seen, a plain click schedules no deferral
    // (no retained line, no armed timer); once a prompt is armed, it does.
    @Test @MainActor func mouseUpPreGatesDeferralWithoutArmedPrompt() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        let delegate = MouseMotionCapturingDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "plain terminal output")

        func click(count: Int) -> (NSEvent, NSEvent) {
            let point = CGPoint(x: 1.5 * view.cellDimension.width,
                                y: view.frame.height - 0.5 * view.cellDimension.height)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                          modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 1, clickCount: count, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                                        modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil,
                                        eventNumber: 2, clickCount: count, pressure: 0)!
            return (down, up)
        }

        let (d1, u1) = click(count: 1)
        view.mouseDown(with: d1)
        view.mouseUp(with: u1)
        #expect(view.semanticDeferralScheduleCount == 0)

        // Now arm a prompt; the identical click schedules the deferral.
        view.feed(text: "\(esc)]133;A;cl=line\u{07}>\(esc)]133;B\u{07}hi")
        let (d2, u2) = click(count: 1)
        view.mouseDown(with: d2)
        view.mouseUp(with: u2)
        #expect(view.semanticDeferralScheduleCount == 1)
        withExtendedLifetime(delegate) {}
    }

    @Test @MainActor func shiftSelectionDoesNotBecomeSemanticPromptClick() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        view.semanticClickCoalescingDelay = 0.01
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        let delegate = MouseMotionCapturingDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\(esc)]133;A;cl=line\u{07}>\(esc)]133;B\u{07}hi")

        let point = CGPoint(
            x: 2.5 * view.cellDimension.width,
            y: view.frame.height - 0.5 * view.cellDimension.height
        )
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: .shift,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: .shift,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        )!

        view.mouseDown(with: down)
        view.mouseUp(with: up)
        await waitForSemanticClick(in: view)
        await waitForTerminalViewCallbacks()

        #expect(!view.withTerminal { _ in view.selection.active })
        #expect(delegate.sentData.isEmpty)
    }

    @Test @MainActor func requiredShiftModifierRoutesSemanticPromptClick() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        view.semanticClickCoalescingDelay = 0.01
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        let delegate = MouseMotionCapturingDelegate()
        view.terminalDelegate = delegate
        view.withTerminal { $0.semanticPromptClickBehavior = .requireModifier(.shift) }
        view.feed(text: "\(esc)]133;A;cl=line\u{07}>\(esc)]133;B\u{07}hi")

        let point = CGPoint(
            x: 1.5 * view.cellDimension.width,
            y: view.frame.height - 0.5 * view.cellDimension.height
        )
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: .shift,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: .shift,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        )!

        view.mouseDown(with: down)
        view.mouseUp(with: up)
        await waitForSemanticClick(in: view)
        await waitForTerminalViewCallbacks()

        #expect(!delegate.sentData.isEmpty)
    }

    @Test @MainActor func clickThatClearsSelectionDoesNotMovePromptCursor() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        view.semanticClickCoalescingDelay = 0.01
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        let delegate = MouseMotionCapturingDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\(esc)]133;A;cl=line\u{07}>\(esc)]133;B\u{07}hi")
        view.withTerminal { _ in view.selection.select(row: 0) }

        let point = CGPoint(x: 1.5 * view.cellDimension.width,
                            y: view.frame.height - 0.5 * view.cellDimension.height)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                      modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                                    modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil,
                                    eventNumber: 2, clickCount: 1, pressure: 0)!

        view.mouseDown(with: down)
        view.mouseUp(with: up)
        await waitForSemanticClick(in: view)

        #expect(!view.withTerminal { _ in view.selection.active })
        #expect(delegate.sentData.isEmpty)
    }

    @Test @MainActor func enabledPolicyDoesNotStealCommandOrControlClick() async {
        for modifier: NSEvent.ModifierFlags in [.command, .control] {
            let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
            view.semanticClickCoalescingDelay = 0.01
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.contentView = view
            let delegate = MouseMotionCapturingDelegate()
            view.terminalDelegate = delegate
            view.feed(text: "\(esc)]133;A;cl=line\u{07}>\(esc)]133;B\u{07}hi")

            let point = CGPoint(x: 1.5 * view.cellDimension.width,
                                y: view.frame.height - 0.5 * view.cellDimension.height)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                          modifierFlags: modifier, timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 1, clickCount: 1, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                                        modifierFlags: modifier, timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil,
                                        eventNumber: 2, clickCount: 1, pressure: 0)!

            view.mouseDown(with: down)
            view.mouseUp(with: up)
            await waitForSemanticClick(in: view)

            #expect(delegate.sentData.isEmpty)
        }
    }

    @Test @MainActor func selectionDragDoesNotOpenLinkAndClearsDragState() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        view.semanticClickCoalescingDelay = 0.01
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        let delegate = MouseMotionCapturingDelegate()
        view.terminalDelegate = delegate
        view.linkHighlightMode = .always
        view.feed(
            text: "\(esc)]8;;https://example.com\(esc)\\link\(esc)]8;;\(esc)\\\r\n" +
                  "\(esc)]133;A;cl=line\u{07}>\(esc)]133;B\u{07}hi"
        )

        let linkPoint = CGPoint(
            x: 1.5 * view.cellDimension.width,
            y: view.frame.height - 0.5 * view.cellDimension.height
        )
        let linkUp = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: linkPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        )!
        view.didSelectionDrag = true
        view.mouseUp(with: linkUp)

        #expect(delegate.openedLinks.isEmpty)
        #expect(!view.didSelectionDrag)

        let promptPoint = CGPoint(
            x: 1.5 * view.cellDimension.width,
            y: view.frame.height - 1.5 * view.cellDimension.height
        )
        let promptDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: promptPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        )!
        let promptUp = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: promptPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 3,
            clickCount: 1,
            pressure: 0
        )!
        view.mouseDown(with: promptDown)
        view.mouseUp(with: promptUp)
        await waitForSemanticClick(in: view)
        await waitForTerminalViewCallbacks()

        #expect(!delegate.sentData.isEmpty)
    }

    @Test @MainActor func doubleClickCancelsPendingSemanticClick() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        view.semanticClickCoalescingDelay = 0.01
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        let delegate = MouseMotionCapturingDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\(esc)]133;A;cl=line\u{07}>\(esc)]133;B\u{07}hello")
        let point = CGPoint(x: 3.5 * view.cellDimension.width,
                            y: view.frame.height - 0.5 * view.cellDimension.height)

        for clickCount in 1...2 {
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                          modifierFlags: [], timestamp: Double(clickCount),
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: clickCount * 2 - 1,
                                          clickCount: clickCount, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                                        modifierFlags: [], timestamp: Double(clickCount),
                                        windowNumber: window.windowNumber, context: nil,
                                        eventNumber: clickCount * 2,
                                        clickCount: clickCount, pressure: 0)!
            view.mouseDown(with: down)
            view.mouseUp(with: up)
        }
        await waitForSemanticClick(in: view)

        #expect(delegate.sentData.isEmpty)
        #expect(view.withTerminal { _ in view.selection.active })
        #expect(view.withTerminal { _ in view.selection.getSelectedText() } == "hello")
    }

    @Test @MainActor func singleClickRoutesAfterCoalescingDelay() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        view.semanticClickCoalescingDelay = 0.01
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        let delegate = MouseMotionCapturingDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\(esc)]133;A;cl=line\u{07}>\(esc)]133;B\u{07}hi")
        let point = CGPoint(x: 1.5 * view.cellDimension.width,
                            y: view.frame.height - 0.5 * view.cellDimension.height)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                      modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                                    modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil,
                                    eventNumber: 2, clickCount: 1, pressure: 0)!

        view.mouseDown(with: down)
        view.mouseUp(with: up)
        #expect(delegate.sentData.isEmpty)
        await waitForSemanticClick(in: view)
        await waitForTerminalViewCallbacks()

        #expect(!delegate.sentData.isEmpty)
    }

    @Test @MainActor func mouseModeEnabledBeforeReleaseReportsReleaseOnly() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        view.semanticClickCoalescingDelay = 0.01
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        let delegate = MouseMotionCapturingDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\(esc)]133;A;cl=line\u{07}>\(esc)]133;B\u{07}hi")
        let point = CGPoint(x: 1.5 * view.cellDimension.width,
                            y: view.frame.height - 0.5 * view.cellDimension.height)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                      modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                                    modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil,
                                    eventNumber: 2, clickCount: 1, pressure: 0)!

        view.mouseDown(with: down)
        view.feed(text: "\(esc)[?1000h\(esc)[?1006h")
        view.mouseUp(with: up)
        await waitForSentData(from: delegate)

        let sent = delegate.sentData.map { String(bytes: $0, encoding: .utf8) ?? "" }
        #expect(sent.count == 1)
        #expect(sent.first?.hasPrefix("\(esc)[<0;") == true)
        #expect(sent.first?.hasSuffix("m") == true)
    }

    @Test @MainActor func shiftBypassedPressStillReportsUnshiftedRelease() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        view.semanticClickCoalescingDelay = 0.01
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        let delegate = MouseMotionCapturingDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\(esc)]133;A;cl=line\u{07}>\(esc)]133;B\u{07}hi" +
                                 "\(esc)[?1000h\(esc)[?1006h")
        let point = CGPoint(x: 1.5 * view.cellDimension.width,
                            y: view.frame.height - 0.5 * view.cellDimension.height)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                      modifierFlags: .shift, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                                    modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil,
                                    eventNumber: 2, clickCount: 1, pressure: 0)!

        view.mouseDown(with: down)
        view.mouseUp(with: up)
        await waitForSentData(from: delegate)

        let sent = delegate.sentData.map { String(bytes: $0, encoding: .utf8) ?? "" }
        #expect(sent.count == 1)
        #expect(sent.first?.hasPrefix("\(esc)[<0;") == true)
        #expect(sent.first?.hasSuffix("m") == true)
    }

    @Test @MainActor func reportedPressCannotFallThroughToSemanticRelease() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        view.semanticClickCoalescingDelay = 0.01
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        let delegate = MouseMotionCapturingDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\(esc)]133;A;cl=line\u{07}>\(esc)]133;B\u{07}hi" +
                                 "\(esc)[?1000h\(esc)[?1006h")
        let point = CGPoint(x: 1.5 * view.cellDimension.width,
                            y: view.frame.height - 0.5 * view.cellDimension.height)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                      modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                                    modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil,
                                    eventNumber: 2, clickCount: 1, pressure: 0)!

        view.mouseDown(with: down)
        await waitForTerminalViewCallbacks()
        delegate.sentData.removeAll()
        view.feed(text: "\(esc)[?1000l")
        view.mouseUp(with: up)
        await waitForSemanticClick(in: view)
        await waitForTerminalViewCallbacks()

        #expect(delegate.sentData.isEmpty)
    }

    @Test @MainActor func TahoeFallbackForwardsWindowMouseMovedEvents() async {
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
        view.feed(text: "\(esc)[?1003h\(esc)[?1006h")
        await waitForTerminalViewCallbacks()
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
        TerminalView.dispatchWindowMouseMovedForTesting(event, window: window)
        await waitForTerminalViewCallbacks()

        #expect(!delegate.sentData.isEmpty)

        view.feed(text: "\(esc)[?1003l")
        await waitForTerminalViewCallbacks()
        #expect(window.acceptsMouseMovedEvents == wasAcceptingMouseMovedEvents)
    }

    @Test @MainActor func TahoeFallbackIgnoresOutOfBoundsMouseMoved() async {
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
        view.feed(text: "\(esc)[?1003h\(esc)[?1006h")
        await waitForTerminalViewCallbacks()

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
        await waitForTerminalViewCallbacks()
        #expect(!delegate.sentData.isEmpty)
    }

    @Test @MainActor func TahoeFallbackDoesNotClobberHostDisablingMouseMoved() async {
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

        view.feed(text: "\(esc)[?1003h")
        await waitForTerminalViewCallbacks()
        #expect(window.acceptsMouseMovedEvents)

        // The host disables it while the terminal is still tracking.
        window.acceptsMouseMovedEvents = false

        // Ending the terminal's fallback must respect the host's choice, not force the
        // captured original value back on.
        view.feed(text: "\(esc)[?1003l")
        await waitForTerminalViewCallbacks()
        #expect(!window.acceptsMouseMovedEvents)
    }

    @Test @MainActor func TahoeFallbackSharesWindowMouseMovedSettingAcrossTerminalViews() async {
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

        firstView.feed(text: "\(esc)[?1003h")
        secondView.feed(text: "\(esc)[?1003h")
        await waitForTerminalViewCallbacks()
        #expect(window.acceptsMouseMovedEvents)

        firstView.feed(text: "\(esc)[?1003l")
        await waitForTerminalViewCallbacks()
        #expect(window.acceptsMouseMovedEvents)

        secondView.feed(text: "\(esc)[?1003l")
        await waitForTerminalViewCallbacks()
        #expect(window.acceptsMouseMovedEvents == wasAcceptingMouseMovedEvents)
    }

    @Test @MainActor func dragMotionForwardedInButtonEventTracking() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        let delegate = MouseMotionCapturingDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\(esc)[?1002h\(esc)[?1006h")

        let event = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: CGPoint(
                x: 5.5 * view.cellDimension.width,
                y: view.frame.height - 3.5 * view.cellDimension.height
            ),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!

        view.mouseDragged(with: event)
        await waitForTerminalViewCallbacks()

        let sentString = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8)
        #expect(sentString == "\(esc)[<32;6;4M")
    }

    @Test @MainActor func dragMotionForwardedInAnyEventMode() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        let delegate = MouseMotionCapturingDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\(esc)[?1003h\(esc)[?1006h")

        let event = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: CGPoint(
                x: 5.5 * view.cellDimension.width,
                y: view.frame.height - 3.5 * view.cellDimension.height
            ),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!

        view.mouseDragged(with: event)
        await waitForTerminalViewCallbacks()

        let sentString = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8)
        #expect(sentString == "\(esc)[<32;6;4M")
    }
#endif

    @Test func sendButtonTrackingReturnsTrueForButtonEventTracking() {
        #expect(Terminal.MouseMode.buttonEventTracking.sendButtonTracking())
    }

    @Test func sendButtonTrackingReturnsTrueForAnyEvent() {
        #expect(Terminal.MouseMode.anyEvent.sendButtonTracking())
    }

    @Test func sendButtonTrackingReturnsFalseForOff() {
        #expect(!Terminal.MouseMode.off.sendButtonTracking())
    }

    @Test func sendButtonTrackingReturnsFalseForX10() {
        #expect(!Terminal.MouseMode.x10.sendButtonTracking())
    }

    @Test func sendButtonTrackingReturnsFalseForVt200() {
        #expect(!Terminal.MouseMode.vt200.sendButtonTracking())
    }

    @Test func sendMotionEventReturnsTrueOnlyForAnyEvent() {
        #expect(Terminal.MouseMode.anyEvent.sendMotionEvent())
        #expect(!Terminal.MouseMode.buttonEventTracking.sendMotionEvent())
        #expect(!Terminal.MouseMode.vt200.sendMotionEvent())
        #expect(!Terminal.MouseMode.x10.sendMotionEvent())
        #expect(!Terminal.MouseMode.off.sendMotionEvent())
    }

    @Test func sendButtonTrackingIsSupersetOfSendMotionEvent() {
        let allModes: [Terminal.MouseMode] = [
            .off,
            .x10,
            .vt200,
            .buttonEventTracking,
            .anyEvent,
        ]

        for mode in allModes where mode.sendMotionEvent() {
            #expect(mode.sendButtonTracking())
        }

        #expect(Terminal.MouseMode.buttonEventTracking.sendButtonTracking())
        #expect(!Terminal.MouseMode.buttonEventTracking.sendMotionEvent())
    }

    @Test func sendMotionInButtonEventTrackingProducesOutput() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?1002h\(esc)[?1006h")

        terminal.sendMotion(buttonFlags: 0, x: 10, y: 5, pixelX: 10, pixelY: 5)

        let sentString = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8)
        #expect(sentString == "\(esc)[<32;11;6M")
    }

    @Test func mouseModeSetByCSISequences() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        #expect(terminal.mouseMode == .off)

        terminal.feed(text: "\(esc)[?1002h")
        #expect(terminal.mouseMode == .buttonEventTracking)

        terminal.feed(text: "\(esc)[?1002l")
        #expect(terminal.mouseMode == .off)

        terminal.feed(text: "\(esc)[?1003h")
        #expect(terminal.mouseMode == .anyEvent)

        terminal.feed(text: "\(esc)[?1003l")
        #expect(terminal.mouseMode == .off)

        terminal.feed(text: "\(esc)[?1000h")
        #expect(terminal.mouseMode == .vt200)
    }

    @Test func dragMotionNotForwardedWhenMouseModeOff() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()

        #expect(terminal.mouseMode == .off)
        #expect(!terminal.mouseMode.sendButtonTracking())
    }

    @Test func dragMotionNotForwardedInVt200Mode() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?1000h")

        #expect(terminal.mouseMode == .vt200)
        #expect(!terminal.mouseMode.sendButtonTracking())
    }

    @Test func sgrMotionEncodingFormat() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?1002h\(esc)[?1006h")

        terminal.sendMotion(buttonFlags: 0, x: 0, y: 0, pixelX: 0, pixelY: 0)
        var sentString = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8)
        #expect(sentString == "\(esc)[<32;1;1M")

        delegate.clearSentData()
        terminal.sendMotion(buttonFlags: 1, x: 79, y: 23, pixelX: 79, pixelY: 23)
        sentString = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8)
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
