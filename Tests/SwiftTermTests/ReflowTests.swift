//
//  ReflowTests.swift
//  
//
//  Created by Miguel de Icaza on 4/17/20.
//
#if os(macOS)
import Foundation
import XCTest

@testable import SwiftTerm

final class ReflowTests: XCTestCase {
    
    func testDoesNotCrashWhenReflowingToTinyWidth ()
    {
        let options = TerminalOptions(cols: 10, rows: 10, scrollback: 1)
        let h = HeadlessTerminal (queue: SwiftTermTests.queue, options: options) { exitCode in }
        
        let t = h.terminal!
        
        t.feed (text: "1234567890\r\n")
        t.feed (text: "ABCDEFGH\r\n")
        t.feed (text: "abcdefghijklmnopqrstxxx\r\n")
        t.feed (text: "\r\n")
        
        // if we resize to a small column width, content is pushed back up and out the top
        // of the buffer. Ensure that this does not crash
        t.resize(cols: 3, rows: 10)
        XCTAssert(true)
    }
    
    static var allTests = [
          ("testDoesNotCrashWhenReflowingToTinyWidth", testDoesNotCrashWhenReflowingToTinyWidth),
    ]
}
#endif
