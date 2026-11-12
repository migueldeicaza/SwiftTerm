import Testing
@testable import SwiftTerm

/// OSC 110 and OSC 111, TAB at a pending wrap, and DECSET 41 (more(1) fix).
final class EmulationGapTests {
    let esc = "\u{1b}"

    @Test func osc110And111RestoreTheHostColors() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        let hostForeground = terminal.foregroundColor
        let hostBackground = terminal.backgroundColor
        terminal.feed(text: "\(esc)]10;#aaaabbbbcccc\(esc)\\\(esc)]11;#111122223333\(esc)\\")
        #expect(terminal.foregroundColor == Color(red: 0xaaaa, green: 0xbbbb, blue: 0xcccc))
        #expect(terminal.backgroundColor == Color(red: 0x1111, green: 0x2222, blue: 0x3333))

        // A second OSC 10 keeps the host color.
        terminal.feed(text: "\(esc)]10;#000011112222\(esc)\\")
        terminal.feed(text: "\(esc)]110\(esc)\\\(esc)]111\(esc)\\")
        #expect(terminal.foregroundColor == hostForeground)
        #expect(terminal.backgroundColor == hostBackground)
    }

    @Test func osc110KeepsAColorTheHostSetLater() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "\(esc)]10;#aaaabbbbcccc\(esc)\\")
        let hostColor = Color(red: 0x1000, green: 0x2000, blue: 0x3000)
        terminal.foregroundColor = hostColor
        terminal.feed(text: "\(esc)]110\(esc)\\")
        #expect(terminal.foregroundColor == hostColor)
    }

    @Test func osc110WithNoOsc10ChangesNothing() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        let hostForeground = terminal.foregroundColor
        terminal.feed(text: "\(esc)]110\(esc)\\")
        #expect(terminal.foregroundColor == hostForeground)
    }

    @Test func moreFixWrapsBeforeTheTab() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "\(esc)[?41$p\(esc)[?41h\(esc)[?41$p")
        #expect(delegate.sentData.map { String(decoding: $0, as: UTF8.self) } == [
            "\(esc)[?41;2$y", "\(esc)[?41;1$y",
        ])
        terminal.feed(text: String(repeating: "x", count: 20) + "\t1")
        #expect(terminal.buffer.y == 1)
        #expect(terminal.getCharacter(col: 8, row: 1) == "1")
        #expect(terminal.buffer.lines[terminal.buffer.yBase + 1].isWrapped)
    }

    @Test func tabKeepsThePendingWrap() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        // Without DECSET 41, TAB keeps the pending wrap, so the next character
        // goes to the start of the next line, as in xterm.
        terminal.feed(text: String(repeating: "y", count: 20) + "\t")
        #expect(terminal.buffer.y == 0)
        #expect(terminal.buffer.x == 19)
        #expect(terminal.buffer.pendingWrap)
        #expect(terminal.getCharacter(col: 19, row: 0) == "y")
        terminal.feed(text: "2")
        #expect(terminal.buffer.y == 1)
        #expect(terminal.getCharacter(col: 0, row: 1) == "2")
    }

    @Test func moreFixWithoutAutowrapKeepsTheCursor() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "\(esc)[?41h" + String(repeating: "z", count: 20) + "\(esc)[?7l\t")
        #expect(terminal.buffer.y == 0)
        #expect(terminal.buffer.x == 19)
    }

    @Test func risResetsMoreFix() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "\(esc)[?41h\(esc)c\(esc)[?41$p")
        #expect(delegate.sentData.last.map { String(decoding: $0, as: UTF8.self) } == "\(esc)[?41;2$y")
    }
}
