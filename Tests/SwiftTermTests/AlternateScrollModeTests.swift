//
//  AlternateScrollModeTests.swift
//
//  DECSET/DECRST 1007: Alternate Scroll Mode (xterm's "alternateScroll" resource).
//  SwiftTerm only tracks the mode's boolean state on Terminal.alternateScrollMode;
//  translating scroll wheel events into cursor keys while the alt screen is active
//  is the host view's responsibility.
//
import Foundation
import Testing

@testable import SwiftTerm

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
}
