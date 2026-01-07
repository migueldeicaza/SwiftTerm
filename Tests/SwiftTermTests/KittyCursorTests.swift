//
//  KittyCursorTests.swift
//
#if os(macOS)
import XCTest

@testable import SwiftTerm

final class KittyCursorTests: XCTestCase {
    private func makeHeadlessTerminal() -> HeadlessTerminal {
        HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 10, rows: 5)) { _ in }
    }

    private func sendKitty(terminal: Terminal, control: String, payload: [UInt8]) {
        let base64 = Data(payload).base64EncodedString()
        let sequence = "\u{1b}_G\(control);\(base64)\u{1b}\\"
        terminal.feed(text: sequence)
    }

    func testKittyCursorMovesAfterPlacement() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=3,r=2,i=1",
                  payload: [1, 2, 3])

        XCTAssertEqual(t.buffer.x, 3)
        XCTAssertEqual(t.buffer.y, 2)
    }

    func testKittyCursorStaysWithC1() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=3,r=2,C=1,i=1",
                  payload: [1, 2, 3])

        XCTAssertEqual(t.buffer.x, 0)
        XCTAssertEqual(t.buffer.y, 0)
    }

    func testKittyCursorMovesFromColumn() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!
        t.feed(text: "AB")

        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=2,r=1,i=1",
                  payload: [1, 2, 3])

        XCTAssertEqual(t.buffer.x, 4)
        XCTAssertEqual(t.buffer.y, 1)
    }
}
#endif
