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

    func testCombinedPositioning() {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // Baseline, we know that "\u{1100}" will always use 2-columns
        // This inserts a simple 2-column value, and then a 1-column value
        t.feed (text: "\u{1100}x\n\r")
        let char0_0 = t.getCharacter (col: 0, row: 0)
        let char1_0 = t.getCharacter (col: 1, row: 0)
        let char2_0 = t.getCharacter (col: 2, row: 0)
        XCTAssertEqual(char0_0, "\u{1100}")
        XCTAssertEqual(char1_0, "\u{0}")
        XCTAssertEqual(char2_0, "x")

        // Here we insert a value that upgrades from 1-column to 2-column when we see the
        // \u{fe0f}, so we need to make sure that the character after that has its position updated.
        t.feed (text: "\u{026e9}\u{0fe0f}x")
        let char0_1 = t.getCharacter (col: 0, row: 1)
        let char1_1 = t.getCharacter (col: 1, row: 1)
        let char2_1 = t.getCharacter (col: 2, row: 1)
        print("Got \(char0_1) \(char1_1) \(char2_1)")
        XCTAssertEqual(char0_1, "\u{026e9}\u{0fe0f}")
        XCTAssertEqual(char1_1, "\u{0}")
        XCTAssertEqual(char2_1, "x")

    }

    func testEmoji ()
    {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // This sends emoji with skin tone modifiers
        // The base emoji and skin tone modifier should combine into a single character
        t.feed (text: "👦🏻x\r\n👦🏿x\r\n")

        let char0_0 = t.getCharacter (col:0, row: 0)
        let char1_0 = t.getCharacter (col:1, row: 0)
        let char2_0 = t.getCharacter (col:2, row: 0)

        let char0_1 = t.getCharacter (col:0, row: 1)
        let char1_1 = t.getCharacter (col:1, row: 1)
        let char2_1 = t.getCharacter (col:2, row: 1)

        // Emoji with skin tone modifiers should be combined into a single grapheme cluster
        XCTAssertEqual(char0_0, "👦🏻")
        XCTAssertEqual(char1_0, "\u{0}")
        XCTAssertEqual(char2_0, "x")
        XCTAssertEqual(char0_1, "👦🏿")
        XCTAssertEqual(char1_1, "\u{0}")
        XCTAssertEqual(char2_1, "x")
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

    func testCJKCharacterPositioning ()
    {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // Test Japanese hiragana (double-width characters)
        // Each character should occupy 2 columns
        t.feed (text: "あいう")

        // Verify character positions
        XCTAssertEqual(t.getCharacter(col: 0, row: 0), "あ")
        XCTAssertEqual(t.getCharacter(col: 1, row: 0), "\u{0}")  // placeholder
        XCTAssertEqual(t.getCharacter(col: 2, row: 0), "い")
        XCTAssertEqual(t.getCharacter(col: 3, row: 0), "\u{0}")  // placeholder
        XCTAssertEqual(t.getCharacter(col: 4, row: 0), "う")
        XCTAssertEqual(t.getCharacter(col: 5, row: 0), "\u{0}")  // placeholder

        // Verify character widths
        XCTAssertEqual(t.getCharData(col: 0, row: 0)?.width, 2)
        XCTAssertEqual(t.getCharData(col: 2, row: 0)?.width, 2)
        XCTAssertEqual(t.getCharData(col: 4, row: 0)?.width, 2)

        // Cursor should be at column 6 after 3 double-width characters
        XCTAssertEqual(t.buffer.x, 6)
    }

    func testCJKMixedWithAscii ()
    {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // Test mixed ASCII and CJK characters
        t.feed (text: "aあbいc")

        // 'a' at col 0 (width 1)
        XCTAssertEqual(t.getCharacter(col: 0, row: 0), "a")
        XCTAssertEqual(t.getCharData(col: 0, row: 0)?.width, 1)

        // 'あ' at col 1 (width 2)
        XCTAssertEqual(t.getCharacter(col: 1, row: 0), "あ")
        XCTAssertEqual(t.getCharData(col: 1, row: 0)?.width, 2)

        // 'b' at col 3 (width 1)
        XCTAssertEqual(t.getCharacter(col: 3, row: 0), "b")
        XCTAssertEqual(t.getCharData(col: 3, row: 0)?.width, 1)

        // 'い' at col 4 (width 2)
        XCTAssertEqual(t.getCharacter(col: 4, row: 0), "い")
        XCTAssertEqual(t.getCharData(col: 4, row: 0)?.width, 2)

        // 'c' at col 6 (width 1)
        XCTAssertEqual(t.getCharacter(col: 6, row: 0), "c")
        XCTAssertEqual(t.getCharData(col: 6, row: 0)?.width, 1)

        // Cursor should be at column 7
        XCTAssertEqual(t.buffer.x, 7)
    }

    func testChineseCharacterPositioning ()
    {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // Test Chinese characters (also double-width)
        t.feed (text: "中文字")

        XCTAssertEqual(t.getCharacter(col: 0, row: 0), "中")
        XCTAssertEqual(t.getCharacter(col: 2, row: 0), "文")
        XCTAssertEqual(t.getCharacter(col: 4, row: 0), "字")

        // All should be width 2
        XCTAssertEqual(t.getCharData(col: 0, row: 0)?.width, 2)
        XCTAssertEqual(t.getCharData(col: 2, row: 0)?.width, 2)
        XCTAssertEqual(t.getCharData(col: 4, row: 0)?.width, 2)

        XCTAssertEqual(t.buffer.x, 6)
    }

    static var allTests = [
        ("testCombiningCharacters", testCombiningCharacters),
        ("testEmoji", testEmoji),
        ("testEmojiWithModifierBase", testEmojiWithModifierBase),
        ("testEmojiZWJSequence", testEmojiZWJSequence),
        ("testEmojiZWJSequenceSimple", testEmojiZWJSequenceSimple),
        ("testCJKCharacterPositioning", testCJKCharacterPositioning),
        ("testCJKMixedWithAscii", testCJKMixedWithAscii),
        ("testChineseCharacterPositioning", testChineseCharacterPositioning),
    ]

}
#endif
