//
//  AlternateScrollModeTests.swift
//
//  DECSET/DECRST 1007: Alternate Scroll Mode (xterm's "alternateScroll" resource).
//  Terminal tracks the mode's boolean state on Terminal.alternateScrollMode, and
//  the macOS view gates its wheel-to-cursor-key translation on it.
//
import Foundation
import Testing

@testable import SwiftTerm

#if os(macOS)
    @MainActor private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

import AppKit
#endif

final class AlternateScrollModeTests: TerminalDelegate {
    var sent: [UInt8] = []

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        sent.append(contentsOf: data)
    }

    func makeTerminal() -> Terminal {
        Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))
    }

    @Test func defaultsToEnabled() {
        let terminal = makeTerminal()
        #expect(terminal.alternateScrollMode == true, "SwiftTerm defaults 1007 to on, matching modern terminals like Ghostty")
    }

    @Test func decsetEnablesAndDecrstDisables() {
        let terminal = makeTerminal()

        terminal.feed(text: "\u{1b}[?1007l")
        #expect(terminal.alternateScrollMode == false)

        terminal.feed(text: "\u{1b}[?1007h")
        #expect(terminal.alternateScrollMode == true)

        terminal.feed(text: "\u{1b}[?1007l")
        #expect(terminal.alternateScrollMode == false)
    }

    @Test func fullResetRestoresDefault() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[?1007l")
        #expect(terminal.alternateScrollMode == false)

        // RIS (Reset to Initial State) should restore the mode to its default (on).
        terminal.feed(text: "\u{1b}c")
        #expect(terminal.alternateScrollMode == true)
    }

    @Test func modeIsIndependentOfAltScreenAndMouseTracking() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[?1007l")
        terminal.feed(text: "\u{1b}[?1049h") // enter alt screen
        #expect(terminal.alternateScrollMode == false, "entering the alt screen must not change 1007's own state")

        terminal.feed(text: "\u{1b}[?1000h") // vt200 mouse tracking
        #expect(terminal.alternateScrollMode == false, "enabling mouse tracking must not implicitly change 1007's state")
    }

    /// DECRQM (`CSI ? 1007 $ p`) must report the mode, the way the neighbouring
    /// mouse modes (1000-1006) already do — otherwise an application can set the
    /// mode but never find out what it currently is.
    @Test func decrqmReportsCurrentState() {
        let terminal = makeTerminal()

        sent = []
        terminal.feed(text: "\u{1b}[?1007$p")
        #expect(String(decoding: sent, as: UTF8.self) == "\u{1b}[?1007;1$y", "set is reported as 1")

        terminal.feed(text: "\u{1b}[?1007l")
        sent = []
        terminal.feed(text: "\u{1b}[?1007$p")
        #expect(String(decoding: sent, as: UTF8.self) == "\u{1b}[?1007;2$y", "reset is reported as 2")
    }

#if os(macOS)
    @MainActor @Test func mouseReportsPreserveAppKitScrollDirection() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        let delegate = WheelCapturingDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        #expect(view.terminal.mouseMode != .off)

        guard let up = Self.makeWheelEvent(lines: 1),
              let down = Self.makeWheelEvent(lines: -1) else {
            Issue.record("could not synthesize scroll wheel events")
            return
        }

        view.scrollWheel(with: up)
        await Self.waitForTerminalViewCallbacks()
        guard delegate.sent.count == 1 else {
            Issue.record("positive delta produced \(delegate.sent.count) mouse reports")
            return
        }
        #expect(String(decoding: delegate.sent[0], as: UTF8.self).hasPrefix("\u{1b}[<64;"),
                "positive AppKit delta must report mouse button 4")

        delegate.sent = []
        view.scrollWheel(with: down)
        await Self.waitForTerminalViewCallbacks()
        guard delegate.sent.count == 1 else {
            Issue.record("negative delta produced \(delegate.sent.count) mouse reports")
            return
        }
        #expect(String(decoding: delegate.sent[0], as: UTF8.self).hasPrefix("\u{1b}[<65;"),
                "negative AppKit delta must report mouse button 5")
    }

    /// The point of tracking the mode is that an application can turn the
    /// translation off: with 1007 reset, the wheel must produce nothing on the
    /// alternate screen (there is no scrollback there to move either).
    @MainActor @Test func viewOnlyTranslatesWheelWhileModeIsSet() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let delegate = WheelCapturingDelegate()
        view.terminalDelegate = delegate
        view.terminal.feed(text: "\u{1b}[?1049h") // alternate screen, no mouse tracking

        guard let wheel = Self.makeWheelEvent(lines: -1) else {
            Issue.record("could not synthesize a scroll wheel event")
            return
        }

        view.scrollWheel(with: wheel)
        #expect(delegate.sent == [Array(EscapeSequences.moveDownNormal)], "mode set: the wheel moves the cursor")

        view.terminal.feed(text: "\u{1b}[?1007l")
        delegate.sent = []
        view.scrollWheel(with: wheel)
        #expect(delegate.sent.isEmpty, "mode reset: the wheel must send nothing")
    }

    /// Suppressed motion must not be banked: trackpad deltas are accumulated
    /// across events, so scrolling while 1007 is reset has to leave nothing
    /// behind for the first event after the mode comes back to spend.
    @MainActor @Test func suppressedScrollingDoesNotBankMotionForLater() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let delegate = WheelCapturingDelegate()
        view.terminalDelegate = delegate
        view.terminal.feed(text: "\u{1b}[?1049h\u{1b}[?1007l")

        guard let cellHeight = view.cellDimension?.height, cellHeight > 2 else {
            Issue.record("no cell metrics to build a sub-line delta from")
            return
        }
        // Just under one line, so on its own this event can never move the cursor.
        let subLine = Int32((cellHeight * 0.9).rounded())
        guard let wheel = Self.makePreciseWheelEvent(pixels: -subLine) else {
            Issue.record("could not synthesize a precise scroll wheel event")
            return
        }

        for _ in 0..<5 {
            view.scrollWheel(with: wheel)
        }
        #expect(delegate.sent.isEmpty, "mode reset: nothing may be sent while suppressed")

        view.terminal.feed(text: "\u{1b}[?1007h")
        view.scrollWheel(with: wheel)
        #expect(delegate.sent.isEmpty, "a single sub-line delta must not move the cursor on its own")
    }

    @MainActor @Test func classicMouseWheelEventSendsOneReport() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let delegate = WheelCapturingDelegate()
        view.terminalDelegate = delegate
        view.terminal.feed(text: "\u{1b}[?1000h")
        guard let wheel = Self.makeWheelEvent(lines: -40) else {
            Issue.record("could not synthesize a scroll wheel event")
            return
        }

        view.scrollWheel(with: wheel)
        await drainMainQueue()

        #expect(delegate.sent.count == 1)
    }

    @MainActor @Test func preciseMouseWheelEventIsLimitedToTheInitialBurst() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let delegate = WheelCapturingDelegate()
        view.terminalDelegate = delegate
        view.terminal.feed(text: "\u{1b}[?1000h")
        guard let cellHeight = view.cellDimension?.height,
              let wheel = Self.makePreciseWheelEvent(
                pixels: Int32((cellHeight * 40).rounded())) else {
            Issue.record("could not synthesize a precise scroll wheel event")
            return
        }

        view.scrollWheel(with: wheel)
        await drainMainQueue()

        #expect(delegate.sent.count == WheelReportBudget.burst)
    }

    /// Cursor keys are not notches: an accelerated classic event keeps its line count.
    @MainActor @Test func classicWheelEventOnTheAlternateScreenKeepsItsLineCount() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let delegate = WheelCapturingDelegate()
        view.terminalDelegate = delegate
        view.terminal.feed(text: "\u{1b}[?1049h")
        guard let wheel = Self.makeWheelEvent(lines: -4) else {
            Issue.record("could not synthesize a scroll wheel event")
            return
        }

        view.scrollWheel(with: wheel)

        #expect(delegate.sent == Array(repeating: Array(EscapeSequences.moveDownNormal), count: 4))
    }

    /// The same flick that is bounded as mouse reports is bounded as cursor keys.
    @MainActor @Test func preciseWheelEventOnTheAlternateScreenIsLimitedToTheInitialBurst() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let delegate = WheelCapturingDelegate()
        view.terminalDelegate = delegate
        view.terminal.feed(text: "\u{1b}[?1049h")
        guard let cellHeight = view.cellDimension?.height,
              let wheel = Self.makePreciseWheelEvent(
                pixels: -Int32((cellHeight * 40).rounded())) else {
            Issue.record("could not synthesize a precise scroll wheel event")
            return
        }

        view.scrollWheel(with: wheel)

        #expect(delegate.sent.count == WheelReportBudget.burst)
        #expect(delegate.sent.allSatisfy { $0 == Array(EscapeSequences.moveDownNormal) })
    }

    @MainActor @Test func optionWheelUsesLocalScrollbackDuringMouseTracking() {
        let view = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 160),
            font: nil,
            options: TerminalOptions(cols: 40, rows: 5, scrollback: 100))
        let delegate = WheelCapturingDelegate()
        view.terminalDelegate = delegate
        for index in 1...20 {
            view.terminal.feed(text: "line-\(index)\r\n")
        }
        view.terminal.feed(text: "\u{1b}[?1000h")
        let before = view.terminal.displayBuffer.yDisp
        guard let wheel = Self.makeWheelEvent(lines: 1, modifiers: .maskAlternate) else {
            Issue.record("could not synthesize an option scroll wheel event")
            return
        }

        view.scrollWheel(with: wheel)

        #expect(delegate.sent.isEmpty)
        #expect(view.terminal.displayBuffer.yDisp < before)
    }

    @MainActor @Test func localHandlingModifiersDoNotBecomeAlternateScrollInput() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let delegate = WheelCapturingDelegate()
        view.terminalDelegate = delegate
        view.terminal.feed(text: "\u{1b}[?1049h\u{1b}[?1000h")

        for (name, modifier) in [
            ("Option", CGEventFlags.maskAlternate),
            ("Shift", CGEventFlags.maskShift),
        ] {
            delegate.sent = []
            guard let wheel = Self.makeWheelEvent(lines: 1, modifiers: modifier) else {
                Issue.record("could not synthesize a \(name) scroll wheel event")
                return
            }

            view.scrollWheel(with: wheel)

            #expect(delegate.sent.isEmpty,
                    "\(name)-wheel requested local handling and must not send cursor keys")
        }
    }

    private static func makeWheelEvent(
        lines: Int32,
        modifiers: CGEventFlags = []
    ) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .line,
                               wheelCount: 1,
                               wheel1: lines,
                               wheel2: 0,
                               wheel3: 0) else {
            return nil
        }
        cg.location = CGPoint(x: 10, y: 10)
        cg.flags = modifiers
        return NSEvent(cgEvent: cg)
    }

    /// Pixel units give `hasPreciseScrollingDeltas`, i.e. the accumulating path.
    private static func makePreciseWheelEvent(
        pixels: Int32,
        modifiers: CGEventFlags = []
    ) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .pixel,
                               wheelCount: 1,
                               wheel1: pixels,
                               wheel2: 0,
                               wheel3: 0) else {
            return nil
        }
        cg.location = CGPoint(x: 10, y: 10)
        cg.flags = modifiers
        return NSEvent(cgEvent: cg)
    }

    /// A mouse-tracking view over twenty lines of scrollback, with precise events worth three
    /// quarters and half of a cell in each route. Either pair crosses a cell only if the bank
    /// leaks between routes.
    @MainActor private static func makeRouteBoundaryFixture() -> (
        view: TerminalView,
        delegate: WheelCapturingDelegate,
        reportedMost: NSEvent, reportedHalf: NSEvent,
        localMost: NSEvent, localHalf: NSEvent
    )? {
        let view = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 160),
            font: nil,
            options: TerminalOptions(cols: 40, rows: 5, scrollback: 100))
        let delegate = WheelCapturingDelegate()
        view.terminalDelegate = delegate
        for index in 1...20 {
            view.terminal.feed(text: "line-\(index)\r\n")
        }
        view.terminal.feed(text: "\u{1b}[?1000h")
        guard let cellHeight = view.cellDimension?.height, cellHeight > 4 else { return nil }
        let most = Int32((cellHeight * 0.75).rounded())
        let half = Int32((cellHeight * 0.5).rounded())
        guard let reportedMost = makePreciseWheelEvent(pixels: most),
              let reportedHalf = makePreciseWheelEvent(pixels: half),
              let localMost = makePreciseWheelEvent(pixels: most, modifiers: .maskAlternate),
              let localHalf = makePreciseWheelEvent(pixels: half, modifiers: .maskAlternate) else {
            return nil
        }
        return (view, delegate, reportedMost, reportedHalf, localMost, localHalf)
    }

    /// Travel banked for a mouse report belongs to the application. Holding Option to scroll
    /// the scrollback starts from nothing rather than spending it locally.
    @MainActor @Test func subCellMouseReportingTravelDoesNotBecomeLocalScrolling() async {
        guard let fixture = Self.makeRouteBoundaryFixture() else {
            Issue.record("could not build the route boundary fixture")
            return
        }
        let before = fixture.view.terminal.displayBuffer.yDisp

        fixture.view.scrollWheel(with: fixture.reportedMost)
        await drainMainQueue()
        #expect(fixture.delegate.sent.isEmpty, "three quarters of a cell is not a report yet")

        fixture.view.scrollWheel(with: fixture.localHalf)
        #expect(fixture.view.terminal.displayBuffer.yDisp == before,
                "half a cell under Option must not add the reported three quarters and scroll")

        fixture.view.scrollWheel(with: fixture.localMost)
        #expect(fixture.view.terminal.displayBuffer.yDisp < before,
                "the Option half and three quarters add up to one local line")
        #expect(fixture.delegate.sent.isEmpty)
    }

    /// The reverse: travel scrolled locally under Option stays local. Releasing Option must not
    /// hand the application a report that includes it.
    @MainActor @Test func subCellLocalScrollingDoesNotBecomeAMouseReport() async {
        guard let fixture = Self.makeRouteBoundaryFixture() else {
            Issue.record("could not build the route boundary fixture")
            return
        }
        let before = fixture.view.terminal.displayBuffer.yDisp

        fixture.view.scrollWheel(with: fixture.localMost)
        #expect(fixture.view.terminal.displayBuffer.yDisp == before,
                "three quarters of a cell is not a local line yet")

        fixture.view.scrollWheel(with: fixture.reportedHalf)
        await drainMainQueue()
        #expect(fixture.delegate.sent.isEmpty,
                "half a cell without Option must not add the local three quarters and report")

        fixture.view.scrollWheel(with: fixture.reportedMost)
        await drainMainQueue()
        #expect(fixture.delegate.sent.count == 1,
                "the reported half and three quarters add up to one report")
        #expect(fixture.view.terminal.displayBuffer.yDisp == before)
    }

    @MainActor private static func waitForTerminalViewCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
#endif
}

#if os(macOS)
private final class WheelCapturingDelegate: TerminalViewDelegate {
    var sent: [[UInt8]] = []

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(Array(data)) }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
#endif
