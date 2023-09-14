//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 4/29/21.
//
//
#if os(macOS)
import XCTest
import Foundation

@testable import SwiftTerm

final class ColorTests: XCTestCase {

    func testExtendedColor ()
    {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        
        let t = h.terminal!
        
        // This tests that we are setting both foreground and background colors
        // using the semicolon style (there was some ambiguity that I had to deal with).
        t.feed (text: "\u{1b}[38;2;19;49;174;48;2;23;56;179mString\n\r")
        var chattr = t.buffer.getChar(at: Position (col: 0, row: 0))
        XCTAssertEqual(chattr.code, Int32(UInt8(ascii: "S")))
        XCTAssertEqual(chattr.attribute.fg, .trueColor(red: 19, green: 49, blue: 174))
        XCTAssertEqual(chattr.attribute.bg, .trueColor(red: 23, green: 56, blue: 179))
        
        // This is the new style
        t.feed (text: "\u{1b}[38:2::255:10:255mHello\n\r")
        chattr = t.buffer.getChar(at: Position (col: 0, row: 1))
        XCTAssertEqual(chattr.code, Int32(UInt8(ascii: "H")))
        XCTAssertEqual(chattr.attribute.fg, .trueColor(red: 255, green: 10, blue: 255))
        XCTAssertEqual(chattr.attribute.bg, .trueColor(red: 23, green: 56, blue: 179))
        
        // Partial sequences do not get parsed
        t.feed (text: "\u{1b}[38:2::255mPartial\n\r")
        chattr = t.buffer.getChar(at: Position (col: 0, row: 2))
        XCTAssertEqual(chattr.code, Int32(UInt8(ascii: "P")))
        XCTAssertEqual(chattr.attribute.bg, .defaultColor)
        XCTAssertEqual(chattr.attribute.fg, .defaultColor)
    }
    
    static var allTests = [
        ("testColors", testExtendedColor)
    ]
}
#endif
