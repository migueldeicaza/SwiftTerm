//
//  BidiEscapeTests.swift
//
//  Terminal-wg BiDi escape sequences: BDSM (SM/RM 8), SPD (CSI Ps SP S),
//  DECSET/DECRST 2500 (box mirroring) and 2501 (direction autodetect).
//  https://terminal-wg.pages.freedesktop.org/bidi/
//
import Foundation
import Testing

@testable import SwiftTerm

final class BidiEscapeTests: TerminalDelegate {
    var sent: [UInt8] = []

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        sent.append(contentsOf: data)
    }

    var sentString: String {
        String(decoding: sent, as: UTF8.self)
    }

    func makeTerminal() -> Terminal {
        Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))
    }

    @Test func defaultsMatchTheAppBehavior() {
        let terminal = makeTerminal()
        #expect(terminal.bidiSupportEnabled, "implicit BDSM by default")
        #expect(terminal.bidiAutodetectDirection, "autodetect on by default (RTL-first app policy)")
        #expect(!terminal.bidiRTLPreference, "SPD default direction is LTR")
        #expect(!terminal.bidiBoxMirroring, "box mirroring off by default")
    }

    @Test func bdsmTogglesImplicitBidi() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[8l")
        #expect(!terminal.bidiSupportEnabled, "RM 8 selects explicit mode (app-side BiDi)")
        terminal.feed(text: "\u{1b}[8h")
        #expect(terminal.bidiSupportEnabled, "SM 8 selects implicit mode")
    }

    @Test func spdSelectsPresentationDirection() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[3 S")
        #expect(terminal.bidiRTLPreference, "SPD 3 selects RTL")
        terminal.feed(text: "\u{1b}[0 S")
        #expect(!terminal.bidiRTLPreference, "SPD 0 selects LTR")
        terminal.feed(text: "\u{1b}[3 S")
        terminal.feed(text: "\u{1b}[ S")
        #expect(!terminal.bidiRTLPreference, "SPD with no parameter defaults to 0 (LTR)")
    }

    @Test func spdIgnoresUnsupportedDirections() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[3 S")
        terminal.feed(text: "\u{1b}[1 S")
        #expect(terminal.bidiRTLPreference, "vertical directions (1, 2) are ignored")
        terminal.feed(text: "\u{1b}[7 S")
        #expect(terminal.bidiRTLPreference)
    }

    @Test func spdDoesNotSwallowScrollUp() {
        let terminal = makeTerminal()
        terminal.feed(text: "hello\r\nworld")
        // Plain CSI 2 S (no space intermediate) must still scroll, not hit SPD.
        terminal.feed(text: "\u{1b}[2S")
        #expect(!terminal.bidiRTLPreference)
        let firstRow = terminal.getLine(row: 0)?.translateToString(trimRight: true)
        #expect(firstRow == "", "content scrolled away by CSI 2 S")
    }

    @Test func decModesToggleAutodetectAndBoxMirroring() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[?2501l")
        #expect(!terminal.bidiAutodetectDirection)
        terminal.feed(text: "\u{1b}[?2501h")
        #expect(terminal.bidiAutodetectDirection)
        terminal.feed(text: "\u{1b}[?2500h")
        #expect(terminal.bidiBoxMirroring)
        terminal.feed(text: "\u{1b}[?2500l")
        #expect(!terminal.bidiBoxMirroring)
    }

    @Test func decrqmReportsBidiModes() {
        let terminal = makeTerminal()

        sent.removeAll()
        terminal.feed(text: "\u{1b}[8$p")
        #expect(sentString == "\u{1b}[8;1$y", "BDSM set by default")

        sent.removeAll()
        terminal.feed(text: "\u{1b}[8l\u{1b}[8$p")
        #expect(sentString == "\u{1b}[8;2$y", "BDSM reports reset after RM 8")

        sent.removeAll()
        terminal.feed(text: "\u{1b}[?2501$p")
        #expect(sentString == "\u{1b}[?2501;1$y", "autodetect set by default")

        sent.removeAll()
        terminal.feed(text: "\u{1b}[?2500$p")
        #expect(sentString == "\u{1b}[?2500;2$y", "box mirroring reset by default")

        sent.removeAll()
        terminal.feed(text: "\u{1b}[?2500h\u{1b}[?2500$p")
        #expect(sentString == "\u{1b}[?2500;1$y")
    }

    @Test func fullResetRestoresBidiDefaults() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[8l\u{1b}[?2501l\u{1b}[3 S\u{1b}[?2500h")
        #expect(!terminal.bidiSupportEnabled)
        #expect(!terminal.bidiAutodetectDirection)
        #expect(terminal.bidiRTLPreference)
        #expect(terminal.bidiBoxMirroring)

        terminal.resetToInitialState()
        #expect(terminal.bidiSupportEnabled)
        #expect(terminal.bidiAutodetectDirection)
        #expect(!terminal.bidiRTLPreference)
        #expect(terminal.bidiBoxMirroring == false)
    }
}
