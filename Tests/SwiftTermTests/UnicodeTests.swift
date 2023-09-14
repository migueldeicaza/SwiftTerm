//
//  UnicodeTests.swift
//  
// Tests for assorted rendering capabilities
//
#if os(macOS)
import Foundation
import XCTest

@testable import SwiftTerm

final class SwiftTermUnicode: XCTestCase {
    
    func testCombiningCharacters ()
    {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        
        let t = h.terminal!
        // Feed combining characters:
        // "Λ" and COMBINING RING ABOVE to produce the single character Λ̊
        // "v" and COMBINING DOT ABOVE
        // "r" and COMBINING DIAERESIS
        // "a" and COMBINING RIGHT HARPOON ABOVE
        //
        t.feed (text: "\u{39b}\u{30a}\r\nv\u{307}\r\nr\u{308}\r\na\u{20d1}\r\nb\u{20d1}")
        
        XCTAssertEqual(t.getCharacter (col:0, row: 0), "Λ̊")
        XCTAssertEqual(t.getCharacter (col:0, row: 1), "v̇")
        XCTAssertEqual(t.getCharacter (col:0, row: 2), "r̈")
        XCTAssertEqual(t.getCharacter (col:0, row: 3), "a⃑")
        XCTAssertEqual(t.getCharacter (col:0, row: 4), "b⃑")
        
    }
    
    func testEmoji ()
    {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // This sends emoji, and emoji with skin colors:
        t.feed (text: "👦🏻\r\n👦🏿\r\n")
        XCTAssertEqual(t.getCharacter (col:0, row: 0), "👦")
        XCTAssertEqual(t.getCharacter (col:1, row: 0), "🏻")
        XCTAssertEqual(t.getCharacter (col:0, row: 1), "👦")
        XCTAssertEqual(t.getCharacter (col:1, row: 1), "🏿")
    }
    
    static var allTests = [
        ("testCombiningCharacters", testCombiningCharacters),
    ]

}
#endif
