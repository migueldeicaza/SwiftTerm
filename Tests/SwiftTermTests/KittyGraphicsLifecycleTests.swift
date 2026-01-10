//
//  KittyGraphicsLifecycleTests.swift
//
#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

final class KittyGraphicsLifecycleTests {
    private func makeHeadlessTerminal() -> HeadlessTerminal {
        HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 10, rows: 5)) { _ in }
    }

    private func sendKitty(terminal: Terminal, control: String, payload: [UInt8]) {
        let base64 = Data(payload).base64EncodedString()
        let sequence = "\u{1b}_G\(control);\(base64)\u{1b}\\"
        terminal.feed(text: sequence)
    }

    @Test func testKittyImagesClearedOnReset() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=1,U=1",
                  payload: [1, 2, 3])

        #expect(t.kittyGraphicsState.imagesById[1] != nil)
        #expect(!t.kittyGraphicsState.placementsByKey.isEmpty)

        t.feed(text: "\u{1b}c")

        #expect(t.kittyGraphicsState.imagesById.isEmpty)
        #expect(t.kittyGraphicsState.imageNumbers.isEmpty)
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
    }

    @Test func testKittyImagesClearedWhenEnteringAltBuffer() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        t.feed(text: "\u{1b}[?1049h")
        #expect(t.isCurrentBufferAlternate)

        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=1,U=1",
                  payload: [1, 2, 3])

        #expect(t.kittyGraphicsState.imagesById[1] != nil)
        #expect(!t.kittyGraphicsState.placementsByKey.isEmpty)

        t.feed(text: "\u{1b}[?47l")
        #expect(!t.isCurrentBufferAlternate)

        #expect(t.kittyGraphicsState.imagesById[1] != nil)
        #expect(!t.kittyGraphicsState.placementsByKey.isEmpty)

        t.feed(text: "\u{1b}[?1049h")
        #expect(t.isCurrentBufferAlternate)

        #expect(t.kittyGraphicsState.imagesById.isEmpty)
        #expect(t.kittyGraphicsState.imageNumbers.isEmpty)
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
    }
}
#endif
