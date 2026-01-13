//
//  PerformanceTest.swift
//
//
//  Created by Miguel de Icaza on 4/17/20.
//
#if os(macOS)
import Foundation
import Testing
import os
@testable import SwiftTerm

final class PerformaceTests {
    let signposter = OSSignposter(subsystem: "SwiftTerm", category: .pointsOfInterest)

    @Test func testPerformance() {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // 5.164 before the changes
        t.feed (text: "\u{1b}[38;2;19;49;174;48;2;23;56;179mStringThis is a very long line\n\r")
        for _ in 0..<20000 {
            t.feed(text: "pointless repetition\n")
        }
    }

    @Test func testPerformance2() {
        testFeed(
            tag: "insertCharacter",
            data: [UInt8]("pointless repetition\n".utf8),
            duration: Duration(secondsComponent: 10, attosecondsComponent: 0))
    }

    func testFeed(tag: StaticString, data: [UInt8], duration: Duration) {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        var now = ContinuousClock.now
        var outerIterations = 0
        let interval = signposter.beginInterval(tag)
        let start = ContinuousClock.now

        t.feed (text: "\u{1b}[38;2;19;49;174;48;2;23;56;179mStringThis is a very long line\n\r")

        repeat {
            t.feed(text: "pointless repetition\n")
            outerIterations += 1
            now = .now
        } while (start.duration(to: now) < duration)
        let elapsed = start.duration(to: now)
        let attoseconds = Double(elapsed.components.attoseconds)
        let seconds = Double(elapsed.components.seconds)
        let throughput = Double(outerIterations) / (seconds + attoseconds / 1e18)
        signposter.endInterval(tag, interval, "\(throughput) throughput calls/s")
        print("\(tag): \(throughput) throughput calls/s")
    }

    @Test func measureBigBlogFeed() {
        guard let d = try? Data(contentsOf: URL(filePath: "/Users/miguel/cvs/vtebench/x")) else {
            print("Skipping test, we do not have the data")
            return
        }
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        let internval = signposter.beginInterval("FeedPerf")
        let start = ContinuousClock.now

        for _ in 0..<10 {
            t.feed(byteArray: [UInt8](d))
        }

        let elapsed = start.duration(to: ContinuousClock.now)
        signposter.endInterval("FeedPerf", internval, "Time \(elapsed)")
        print("measureBigBlogFeed: \(elapsed) elapsed")

    }

    @Test func repeatBigBlob() {
        // This file is generated with:
        // vtebench:
        // target/release/vtebench --max-samples 1 -b benchmarks/medium_cells/
        guard let d = try? Data(contentsOf: URL(filePath: "/Users/miguel/cvs/vtebench/x")) else {
            print("Skipping test, we do not have the data")
            return
        }

        testFeed(
            tag: "VteBenchPerf",
            data: [UInt8](d),
            duration: Duration(secondsComponent: 10, attosecondsComponent: 0))
    }

}
#endif

