//
//  DcsTests.swift
//
//  Tests for DCS (Device Control String) sequence handling
//  Ported from Ghostty's dcs.zig tests
//
//  The XTGETTCAP reply tests live in XtgettcapTests.swift, which is not
//  restricted to macOS.
//
#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

final class DcsTests {
    private let esc = "\u{1b}"

    // MARK: - DCS Sequence Tests (Ported from Ghostty)

    /// Test DCS with parameters
    /// From Ghostty: "dcs: params"
    @Test func testDcsWithParams() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // DCS with numeric parameter
        t.feed(text: "\(esc)P1000p\(esc)\\")

        // Should not crash
    }

    /// Test DECRQSS (Request Selection or Setting Status)
    /// From Ghostty: "DECRQSS command"
    @Test func testDecrqss() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // DECRQSS for SGR: ESC P $ q m ESC \
        t.feed(text: "\(esc)P$qm\(esc)\\")

        // Terminal should respond with current SGR settings
        // Response format: DCS 1 $ r <SGR params> m ST
    }

    /// DECRQSS with a non-ASCII payload byte: the payload does not decode as
    /// ASCII, and the unknown-request branch must answer rather than crash.
    @Test func testDecrqssNonAsciiPayload() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // DECRQSS (ESC P $ q <0xA0> ESC \) with a non-ASCII payload byte.
        t.feed(byteArray: [0x1b, 0x50, 0x24, 0x71, 0xa0, 0x1b, 0x5c])

        // Should not crash.
    }

    /// Test DECRQSS for DECSTBM (scrolling region)
    @Test func testDecrqssDecstbm() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Set scroll region first
        t.feed(text: "\(esc)[5;20r")

        // Request DECSTBM status
        t.feed(text: "\(esc)P$qr\(esc)\\")

        // Terminal should respond with scroll region settings
    }

    /// Test Sixel graphics DCS sequence
    @Test func testDcsSixelBasic() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Basic Sixel: ESC P q <sixel data> ESC \
        // Simple 1-pixel sixel in default color
        t.feed(text: "\(esc)Pq#0;2;0;0;0~\(esc)\\")

        // Should process without crashing
    }

    /// A final sixel band does not need to end with '$' or '-'.
    @Test func testDcsSixelFinalBandWithoutCursorMovement() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Regression test for a zero-width allocation followed by a pixel write.
        t.feed(text: "\(esc)Pq\"1;1;1;1#0;2;100;0;0#0!1~\(esc)\\")

        #expect(h.images.count == 1)
        #expect(h.images[0].1 == 1)
        #expect(h.images[0].2 == 6)
        #expect(h.images[0].0.count == 24)
    }

    /// Test Sixel with parameters (aspect ratio, background)
    @Test func testDcsSixelWithParams() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Sixel with parameters: P0;1;q = transparent background
        t.feed(text: "\(esc)P0;1;q#0;2;100;100;100~\(esc)\\")

        // Should process without crashing
    }

    /// Test DCS sequence terminated by BEL (not standard but some terminals accept it)
    @Test func testDcsTerminatedByBel() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Some implementations accept BEL as DCS terminator
        t.feed(text: "\(esc)P+q\u{07}")

        // Should not crash (may or may not accept BEL terminator)
    }

    /// Test DCS sequence with C1 terminator (0x9C)
    @Test func testDcsC1Terminator() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Use raw bytes to avoid UTF-8 encoding of 0x9C (which becomes 0xC2 0x9C)
        let bytes: [UInt8] = [0x1b, 0x50, 0x2b, 0x71, 0x9c]  // ESC P + q ST
        t.feed(byteArray: bytes)

        // Should process correctly - parser returns to ground state
    }

    /// Test incomplete DCS sequence followed by valid escape
    @Test func testDcsInterruptedByEscape() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Start DCS, then interrupt with new ESC sequence
        t.feed(text: "\(esc)P+q")  // Start DCS
        t.feed(text: "\(esc)[H")    // CUP - cursor home

        // Should abort DCS and process cursor home
        #expect(t.buffer.x == 0)
        #expect(t.buffer.y == 0)
    }

    /// Test unknown DCS command is handled gracefully
    /// From Ghostty: "unknown DCS command"
    @Test func testDcsUnknownCommand() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Unknown DCS command should be ignored
        t.feed(text: "\(esc)P999z\(esc)\\")

        // Should not crash
    }

    /// Test DCS passthrough data handling
    @Test func testDcsPassthrough() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Custom DCS with passthrough data
        t.feed(text: "\(esc)P1$rtest data here\(esc)\\")

        // Should pass through data without crash
    }

    /// Test multiple DCS sequences in succession
    @Test func testMultipleDcsSequences() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Multiple DCS sequences back to back
        t.feed(text: "\(esc)P$qm\(esc)\\")
        t.feed(text: "\(esc)P$qr\(esc)\\")
        t.feed(text: "\(esc)P+q\(esc)\\")

        // All should process without issues
    }

    /// Test DECRQSS for cursor style (DECSCUSR)
    @Test func testDecrqssDecscusr() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        // Set cursor style to blinking bar
        terminal.feed(text: "\(esc)[5 q")

        // Query cursor style
        terminal.feed(text: "\(esc)P$q q\(esc)\\")

        #expect(delegate.sentData.last == Array("\(esc)P1$r5 q\(esc)\\".utf8))
    }

    @Test func testDecscusrZeroRestoresStartupStyle() {
        let delegate = TerminalTestDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cursorStyle: .steadyUnderline)
        )

        terminal.feed(text: "\(esc)[5 q\(esc)[0 q")
        #expect(terminal.options.cursorStyle == .steadyUnderline)

        terminal.feed(text: "\(esc)P$q q\(esc)\\")
        #expect(delegate.sentData.last == Array("\(esc)P1$r4 q\(esc)\\".utf8))
    }
}
#endif
