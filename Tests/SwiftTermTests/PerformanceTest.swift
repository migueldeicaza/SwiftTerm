//
//  PerformanceTest.swift
//
//
//  Created by Miguel de Icaza on 4/17/20.
//
#if os(macOS)
import Foundation
import XCTest

@testable import SwiftTerm

final class PerformaceTests: XCTestCase {

    func testPerformance() {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!
        
        // 5.164 before the changes
        measure {
            t.feed (text: "\u{1b}[38;2;19;49;174;48;2;23;56;179mStringThis is a very long line\n\r")
            for x in 0..<20000 {
                t.feed(text: "pointless repetition\n")
            }
        }
    }
    
    static var allTests = [
        ("testPerformance", testPerformance)
    ]
}
#endif
