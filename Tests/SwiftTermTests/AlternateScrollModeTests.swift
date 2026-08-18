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

    private static func makeWheelEvent(lines: Int32) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .line,
                               wheelCount: 1,
                               wheel1: lines,
                               wheel2: 0,
                               wheel3: 0) else {
            return nil
        }
        cg.location = CGPoint(x: 10, y: 10)
        return NSEvent(cgEvent: cg)
    }

    /// Pixel units give `hasPreciseScrollingDeltas`, i.e. the accumulating path.
    private static func makePreciseWheelEvent(pixels: Int32) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .pixel,
                               wheelCount: 1,
                               wheel1: pixels,
                               wheel2: 0,
                               wheel3: 0) else {
            return nil
        }
        cg.location = CGPoint(x: 10, y: 10)
        return NSEvent(cgEvent: cg)
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
