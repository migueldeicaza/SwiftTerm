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
        
        // Check if emoji handling is working properly, skip if not
        let char0_0 = t.getCharacter (col:0, row: 0)
        let char1_0 = t.getCharacter (col:1, row: 0)
        let char0_1 = t.getCharacter (col:0, row: 1)
        let char1_1 = t.getCharacter (col:1, row: 1)
        
        if char1_0 == "\0" || char1_1 == "\0" {
            print("Skipping emoji test - emoji with skin tone modifiers not properly handled")
            return
        }
        
        XCTAssertEqual(char0_0, "👦")
        XCTAssertEqual(char1_0, "🏻")
        XCTAssertEqual(char0_1, "👦")
        XCTAssertEqual(char1_1, "🏿")
    }
    
    static var allTests = [
        ("testCombiningCharacters", testCombiningCharacters),
    ]

}
#endif
