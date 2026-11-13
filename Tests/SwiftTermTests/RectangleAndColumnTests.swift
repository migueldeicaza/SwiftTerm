import Testing
@testable import SwiftTerm

/// DECCRA in origin mode, and DECFI in the pending-wrap position.
final class RectangleAndColumnTests {
    let esc = "\u{1b}"

    private func row(_ terminal: Terminal, _ y: Int, _ count: Int) -> String {
        String((0..<count).map { x -> Character in
            let c = terminal.getCharacter(col: x, row: y) ?? " "
            return c == "\u{0}" ? " " : c
        })
    }

    @Test func deccraDestinationFollowsOriginMode() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)
        terminal.feed(text: "abcdefgh\r\nijklmnop\r\nqrstuvwx\r\nyz012345\r\nABCDEFGH\r\nIJKLMNOP")
        terminal.feed(text: "\(esc)[?69h\(esc)[2;9s\(esc)[2;9r\(esc)[?6h")
        terminal.feed(text: "\(esc)[1;1;3;3;1;4;4;1$v")
        terminal.feed(text: "\(esc)[?69l\(esc)[r\(esc)[?6l")
        #expect(row(terminal, 3, 8) == "yz012345")
        #expect(row(terminal, 4, 8) == "ABCDjklH")
        #expect(row(terminal, 5, 8) == "IJKLrstP")
    }

    @Test func decfiInThePendingWrapPositionScrolls() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "\(esc)[1;20Hx\(esc)9")
        #expect(row(terminal, 0, 20) == String(repeating: " ", count: 18) + "x ")
        #expect(terminal.buffer.x == 19)
    }
}
