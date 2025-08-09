//
//  PerformanceTest.swift
//
//
//  Created by Miguel de Icaza on 4/17/20.
//
#if os(macOS)
import Foundation
import XCTest
import os
@testable import SwiftTerm

final class PerformaceTests: XCTestCase {
    let signposter = OSSignposter(subsystem: "SwiftTerm", category: .pointsOfInterest)

    func testPerformance() {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!
        
        // 5.164 before the changes
        measure {
            t.feed (text: "\u{1b}[38;2;19;49;174;48;2;23;56;179mStringThis is a very long line\n\r")
            for _ in 0..<20000 {
                t.feed(text: "pointless repetition\n")
            }
        }
    }
    
    func testPerformance2() {
        testFeed(duration: Duration(secondsComponent: 10, attosecondsComponent: 0))
    }
    
    func testFeed(duration: Duration) {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        var now = ContinuousClock.now
        var outerIterations = 0
        let internval = signposter.beginInterval("insertCharacter")
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
        signposter.endInterval("insertCharacter", internval, "\(throughput) throughput calls/s")
        print("insertCharacter: \(throughput) throughput calls/s")
    }
    static var allTests = [
        ("testPerformance", testPerformance),
        ("testPerformance2", testPerformance2)
    ]
}
#endif
