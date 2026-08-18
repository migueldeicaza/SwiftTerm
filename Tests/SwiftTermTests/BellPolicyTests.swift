//
//  BellPolicyTests.swift
//  SwiftTermTests
//
//  Covers the bell gate that keeps binary data from flooding the main queue.
//

import Foundation
import Testing
@testable import SwiftTerm

#if os(macOS) || os(iOS) || os(visionOS)
@Suite("BellPolicy")
struct BellPolicyTests {
    @Test func disabledBellNeverDelivers() {
        let policy = BellPolicy()
        policy.setStyle(.none)
        for index in 0..<1000 {
            #expect(policy.shouldDeliver(now: UInt64(index) * 1_000_000_000) == false)
        }
        #expect(policy.suppressed == 1000)
    }

    @Test func firstBellAlwaysDelivers() {
        let policy = BellPolicy()
        policy.setStyle(.sound)
        #expect(policy.shouldDeliver(now: 1) == true)
    }

    /// The case that motivated this: a BEL roughly every 256 bytes of random
    /// data. Only the rate-limited few may reach the main queue.
    @Test func burstIsRateLimited() {
        let policy = BellPolicy()
        policy.setStyle(.sound)
        var delivered = 0
        // 10 000 bells spaced 10 us apart: 100 ms of wall time.
        for index in 0..<10_000 {
            if policy.shouldDeliver(now: UInt64(index) * 10_000) {
                delivered += 1
            }
        }
        // First one, plus at most one more at the 100 ms boundary.
        #expect(delivered <= 2)
        #expect(policy.suppressed >= 9_998)
    }

    @Test func spacedBellsAllDeliver() {
        let policy = BellPolicy()
        policy.setStyle(.sound)
        var delivered = 0
        for index in 0..<10 {
            let now = UInt64(index) * (BellPolicy.minimumIntervalNs + 1_000_000)
            if policy.shouldDeliver(now: now) {
                delivered += 1
            }
        }
        #expect(delivered == 10)
    }

    @Test func styleChangeTakesEffect() {
        let policy = BellPolicy()
        policy.setStyle(.none)
        #expect(policy.shouldDeliver(now: 1_000_000_000) == false)
        policy.setStyle(.visual)
        #expect(policy.shouldDeliver(now: 2_000_000_000) == true)
    }

    /// A style change clears the throttle, so the host can verify a new
    /// setting immediately. Guards the behaviour `BellDispatchTests
    /// .bellStyleGatesDelegate` depends on.
    @Test func styleChangeClearsThrottle() {
        let policy = BellPolicy()
        policy.setStyle(.sound)
        #expect(policy.shouldDeliver(now: 1_000_000) == true)
        // Immediately after, the throttle blocks a second bell.
        #expect(policy.shouldDeliver(now: 1_000_001) == false)
        // But a style change lets the next one through.
        policy.setStyle(.soundAndVisual)
        #expect(policy.shouldDeliver(now: 1_000_002) == true)
    }

    /// Re-setting the same style must not become a throttle bypass, or a host
    /// that assigns bellStyle in a loop would defeat the rate limit.
    @Test func redundantStyleAssignmentKeepsThrottle() {
        let policy = BellPolicy()
        policy.setStyle(.sound)
        #expect(policy.shouldDeliver(now: 1_000_000) == true)
        policy.setStyle(.sound)
        #expect(policy.shouldDeliver(now: 1_000_001) == false)
    }

    /// A BEL that terminates an OSC or APC string is consumed by the parser
    /// and must not ring. Ghostty relies on the same property
    /// (`terminal/stream.zig`); pinning it here so a parser table change cannot
    /// silently turn every window-title update into a bell.
    @Test func oscTerminatingBellDoesNotRing() {
        final class Counter: TerminalDelegate {
            var bells = 0
            func send (source: Terminal, data: ArraySlice<UInt8>) {}
            func bell (source: Terminal) { bells += 1 }
        }
        let delegate = Counter()
        let terminal = Terminal(delegate: delegate)

        // OSC 0 sets the title, terminated by BEL.
        terminal.feed(text: "\u{1b}]0;hello\u{07}")
        #expect(delegate.bells == 0)
        #expect(terminal.terminalTitle == "hello")

        // A bare BEL in ground state still rings.
        terminal.feed(text: "\u{07}")
        #expect(delegate.bells == 1)
    }

    @Test func resetClearsSuppressionCount() {
        let policy = BellPolicy()
        policy.setStyle(.none)
        _ = policy.shouldDeliver(now: 1)
        #expect(policy.suppressed == 1)
        policy.resetCounters()
        #expect(policy.suppressed == 0)
    }
}
#endif
