//
//  OscTests.swift
//  
//
//  Created by Miguel de Icaza on 4/13/20.
//
#if os(macOS)
import Foundation
import XCTest

@testable import SwiftTerm

final class SwiftTermOsc: XCTestCase {
    
    func testOscTerminalTitle ()
    {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        
        let t = h.terminal!
        
        t.feed (text: "\u{39b}\u{30a}\nv\u{307}\nr\u{308}\na\u{20d1}\nb\u{20d1}")
        
        XCTAssertEqual(t.hostCurrentDirectory, nil)
        t.feed (text: "\u{1b}]7;file:///localhost/usr/bin\u{7}")
        XCTAssertEqual(t.hostCurrentDirectory!, "file:///localhost/usr/bin")
    }
    
    static var allTests = [
        ("testOscTerminalTitle", testOscTerminalTitle),
    ]

}
#endif
