//
//  FocusReportTests.swift
//
//  DECSET 1004 focus reporting: enabling reports the current focus state
//  immediately (xterm behavior), then focus changes report as they happen.
//
import Foundation
import Testing

@testable import SwiftTerm

final class FocusReportTests: TerminalDelegate {
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

    @Test func enablingFocusReportingSendsCurrentState() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[?1004h")
        #expect(sentString == "\u{1b}[I", "enable while focused reports focus-in immediately")

        sent.removeAll()
        terminal.setTerminalFocus(false)
        #expect(sentString == "\u{1b}[O")

        sent.removeAll()
        terminal.setTerminalFocus(true)
        #expect(sentString == "\u{1b}[I")
    }

    @Test func enablingWhileUnfocusedReportsFocusOut() {
        let terminal = makeTerminal()
        terminal.setTerminalFocus(false)
        sent.removeAll()
        terminal.feed(text: "\u{1b}[?1004h")
        #expect(sentString == "\u{1b}[O", "enable while unfocused reports focus-out immediately")
    }

    @Test func focusChangesAreSilentWhenReportingDisabled() {
        let terminal = makeTerminal()
        terminal.setTerminalFocus(false)
        terminal.setTerminalFocus(true)
        #expect(sent.isEmpty)

        terminal.feed(text: "\u{1b}[?1004h")
        sent.removeAll()
        terminal.feed(text: "\u{1b}[?1004l")
        terminal.setTerminalFocus(false)
        #expect(sent.isEmpty, "no reports after DECRST 1004")
    }
}
