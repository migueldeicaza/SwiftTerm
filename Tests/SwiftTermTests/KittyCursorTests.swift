//
//  KittyCursorTests.swift
//
#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

final class KittyCursorTests {
    private func makeHeadlessTerminal() -> HeadlessTerminal {
        HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 10, rows: 5)) { _ in }
    }

    private func sendKitty(terminal: Terminal, control: String, payload: [UInt8]) {
        let base64 = Data(payload).base64EncodedString()
        let sequence = "\u{1b}_G\(control);\(base64)\u{1b}\\"
        terminal.feed(text: sequence)
    }

    @Test func testKittyCursorMovesAfterPlacement() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=3,r=2,i=1",
                  payload: [1, 2, 3])

        #expect(t.buffer.x == 3)
        #expect(t.buffer.y == 2)
    }

    @Test func testKittyCursorStaysWithC1() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=3,r=2,C=1,i=1",
                  payload: [1, 2, 3])

        #expect(t.buffer.x == 0)
        #expect(t.buffer.y == 0)
    }

    @Test func testKittyCursorMovesFromColumn() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!
        t.feed(text: "AB")

        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=2,r=1,i=1",
                  payload: [1, 2, 3])

        #expect(t.buffer.x == 4)
        #expect(t.buffer.y == 1)
    }
}
#endif
