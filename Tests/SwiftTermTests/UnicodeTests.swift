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

    func testVariationSelector ()
    {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // This will send ⛩️ (0x26e9) is actually in a special class: it can either be one-column (⛩) or two-columns (⛩️)
        // depending on the unicode "variation selector" that follows: 0x26e9 0xfe0e = ⛩, 0x26e9 0xfe0f = ⛩️.
        // Globally, any unicode character followed by 0xfe0e will be single column, any unicode character
        // followed by 0xfe0f will be double-column:
        // https://en.wikipedia.org/wiki/Variation_Selectors_(Unicode_block)
        //
        // The first line is the unicode with the double-size modifier
        // The second line is the unicode character but we are forcing single column
        // The third line is the default
        t.feed (text: "\u{026e9}\u{0fe0f}\n\r\u{026e9}\u{0fe0e}\n\r\u{026e9}")

        // The first line should have 2 columns
        let char0_0 = t.getCharData(col: 0, row: 0)
        XCTAssertEqual(char0_0?.width, 2)

        // The second line should have 1 columns
        let char1_0 = t.getCharData(col: 0, row: 1)
        XCTAssertEqual(char1_0?.width, 1)

        // The third line should have 1 columns
        let char2_0 = t.getCharData(col: 0, row: 2)
        XCTAssertEqual(char2_0?.width, 1)
    }

    func testEmoji ()
    {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // This sends emoji with skin tone modifiers
        // The base emoji and skin tone modifier should combine into a single character
        t.feed (text: "👦🏻\r\n👦🏿\r\n")

        let char0_0 = t.getCharacter (col:0, row: 0)
        let char0_1 = t.getCharacter (col:0, row: 1)

        // Emoji with skin tone modifiers should be combined into a single grapheme cluster
        XCTAssertEqual(char0_0, "👦🏻")
        XCTAssertEqual(char0_1, "👦🏿")
    }

    func testEmojiWithModifierBase ()
    {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // Test hand emoji with skin tone (as reported in issue #341)
        // 🖐️ (raised hand) + skin tone modifier should combine
        t.feed (text: "🖐🏾\r\n")

        let char0_0 = t.getCharacter (col:0, row: 0)

        // The hand emoji and skin tone should combine into single grapheme cluster
        XCTAssertEqual(char0_0, "🖐🏾")
    }

    func testEmojiZWJSequence ()
    {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // Test ZWJ (Zero Width Joiner) emoji sequences
        // Family emoji: 👩‍👩‍👦‍👦 = 👩 + ZWJ + 👩 + ZWJ + 👦 + ZWJ + 👦
        t.feed (text: "👩‍👩‍👦‍👦\r\n")

        let char0_0 = t.getCharacter (col:0, row: 0)

        // The entire ZWJ sequence should combine into a single grapheme cluster
        XCTAssertEqual(char0_0, "👩‍👩‍👦‍👦")
    }

    func testEmojiZWJSequenceSimple ()
    {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // Test simpler ZWJ sequence: couple with heart 👩‍❤️‍👨
        t.feed (text: "👩‍❤️‍👨\r\n")

        let char0_0 = t.getCharacter (col:0, row: 0)

        XCTAssertEqual(char0_0, "👩‍❤️‍👨")
    }

    static var allTests = [
        ("testCombiningCharacters", testCombiningCharacters),
        ("testEmoji", testEmoji),
        ("testEmojiWithModifierBase", testEmojiWithModifierBase),
        ("testEmojiZWJSequence", testEmojiZWJSequence),
        ("testEmojiZWJSequenceSimple", testEmojiZWJSequenceSimple),
    ]

}
#endif
