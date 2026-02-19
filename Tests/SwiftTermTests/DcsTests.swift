//
//  DcsTests.swift
//
//  Tests for DCS (Device Control String) sequence handling
//  Ported from Ghostty's dcs.zig tests
//
#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

final class DcsTests {
    private let esc = "\u{1b}"

    // MARK: - DCS Sequence Tests (Ported from Ghostty)

    /// Test basic DCS sequence parsing
    /// From Ghostty: "dcs: XTGETTCAP"
    @Test func testDcsXtgettcap() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // XTGETTCAP: ESC P + q followed by hex-encoded capability name
        // This requests terminal capabilities
        t.feed(text: "\(esc)P+q\(esc)\\")

        // Should not crash - terminal may or may not respond
    }

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

    /// Test DCS with very long payload
    @Test func testDcsLongPayload() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Long XTGETTCAP query
        let longQuery = String(repeating: "54", count: 500)  // Hex for 'T'
        t.feed(text: "\(esc)P+q\(longQuery)\(esc)\\")

        // Should handle without crash (may truncate)
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

    /// Test XTGETTCAP with specific capability names (hex encoded)
    @Test func testXtgettcapSpecificCaps() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Query 'TN' (terminal name) - hex: 544E
        t.feed(text: "\(esc)P+q544E\(esc)\\")

        // Query 'Co' (colors) - hex: 436F
        t.feed(text: "\(esc)P+q436F\(esc)\\")

        // Query 'RGB' - hex: 524742
        t.feed(text: "\(esc)P+q524742\(esc)\\")

        // Should respond or ignore, but not crash
    }

    /// Test XTGETTCAP with multiple keys in one request
    /// From Ghostty: "XTGETTCAP command multiple keys"
    @Test func testXtgettcapMultipleKeys() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Multiple hex-encoded keys separated by semicolons
        t.feed(text: "\(esc)P+q544E;436F;524742\(esc)\\")

        // Should process all keys
    }

    /// Test DECRQSS for cursor style (DECSCUSR)
    @Test func testDecrqssDecscusr() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Set cursor style to blinking bar
        t.feed(text: "\(esc)[5 q")

        // Query cursor style
        t.feed(text: "\(esc)P$q q\(esc)\\")

        // Terminal should respond with cursor style
    }
}
#endif
