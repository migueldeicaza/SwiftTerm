//
//  UnicodeTests.swift
//  
// Tests for assorted rendering capabilities
//
#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

@Suite(.serialized)
final class SwiftTermUnicode {
    
    @Test func testCombiningCharacters() {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        
        let t = h.terminal!
        // Feed combining characters:
        // "Λ" and COMBINING RING ABOVE to produce the single character Λ̊
        // "v" and COMBINING DOT ABOVE
        // "r" and COMBINING DIAERESIS
        // "a" and COMBINING RIGHT HARPOON ABOVE
        //
        t.feed (text: "\u{39b}\u{30a}\r\nv\u{307}\r\nr\u{308}\r\na\u{20d1}\r\nb\u{20d1}")
        
        #expect(t.getCharacter (col:0, row: 0) == "Λ̊")
        #expect(t.getCharacter (col:0, row: 1) == "v̇")
        #expect(t.getCharacter (col:0, row: 2) == "r̈")
        #expect(t.getCharacter (col:0, row: 3) == "a⃑")
        #expect(t.getCharacter (col:0, row: 4) == "b⃑")
        
    }

    @Test func testVariationSelector() {
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
        #expect(char0_0?.width == 2)

        // The second line should have 1 columns
        let char1_0 = t.getCharData(col: 0, row: 1)
        #expect(char1_0?.width == 1)

        // The third line should have 1 columns
        let char2_0 = t.getCharData(col: 0, row: 2)
        #expect(char2_0?.width == 1)
    }

    @Test func testCombinedPositioning() {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // Baseline, we know that "\u{1100}" will always use 2-columns
        // This inserts a simple 2-column value, and then a 1-column value
        t.feed (text: "\u{1100}x\n\r")
        let char0_0 = t.getCharacter (col: 0, row: 0)
        let char1_0 = t.getCharacter (col: 1, row: 0)
        let char2_0 = t.getCharacter (col: 2, row: 0)
        #expect(char0_0 == "\u{1100}")
        #expect(char1_0 == "\u{0}")
        #expect(char2_0 == "x")

        // Here we insert a value that upgrades from 1-column to 2-column when we see the
        // \u{fe0f}, so we need to make sure that the character after that has its position updated.
        t.feed (text: "\u{026e9}\u{0fe0f}x")
        let char0_1 = t.getCharacter (col: 0, row: 1)
        let char1_1 = t.getCharacter (col: 1, row: 1)
        let char2_1 = t.getCharacter (col: 2, row: 1)
        //print("Got \(char0_1) \(char1_1) \(char2_1)")
        #expect(char0_1 == "\u{026e9}\u{0fe0f}")
        #expect(char1_1 == "\u{0}")
        #expect(char2_1 == "x")

    }

    @Test func testEmoji() {
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
        #expect(char0_0 == "👦🏻")
        #expect(char1_0 == "\u{0}")
        #expect(char2_0 == "x")
        #expect(char0_1 == "👦🏿")
        #expect(char1_1 == "\u{0}")
        #expect(char2_1 == "x")
    }

    @Test func testEmojiWithModifierBase() {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // Test hand emoji with skin tone (as reported in issue #341)
        // 🖐️ (raised hand) + skin tone modifier should combine
        t.feed (text: "🖐🏾\r\n")

        let char0_0 = t.getCharacter (col:0, row: 0)

        // The hand emoji and skin tone should combine into single grapheme cluster
        #expect(char0_0 == "🖐🏾")
    }

    @Test func testEmojiZWJSequence() {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // Test ZWJ (Zero Width Joiner) emoji sequences
        // Family emoji: 👩‍👩‍👦‍👦 = 👩 + ZWJ + 👩 + ZWJ + 👦 + ZWJ + 👦
        t.feed (text: "👩‍👩‍👦‍👦\r\n")

        let char0_0 = t.getCharacter (col:0, row: 0)

        // The entire ZWJ sequence should combine into a single grapheme cluster
        #expect(char0_0 == "👩‍👩‍👦‍👦")
    }

    @Test func testEmojiZWJSequenceSimple() {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // Test simpler ZWJ sequence: couple with heart 👩‍❤️‍👨
        t.feed (text: "👩‍❤️‍👨\r\n")

        let char0_0 = t.getCharacter (col:0, row: 0)

        #expect(char0_0 == "👩‍❤️‍👨")
    }

    @Test func testCJKCharacterPositioning ()
    {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // Test Japanese hiragana (double-width characters)
        // Each character should occupy 2 columns
        t.feed (text: "あいう")

        // Verify character positions
        #expect(t.getCharacter(col: 0, row: 0) == "あ")
        #expect(t.getCharacter(col: 1, row: 0) == "\u{0}")  // placeholder
        #expect(t.getCharacter(col: 2, row: 0) == "い")
        #expect(t.getCharacter(col: 3, row: 0) == "\u{0}")  // placeholder
        #expect(t.getCharacter(col: 4, row: 0) == "う")
        #expect(t.getCharacter(col: 5, row: 0) == "\u{0}")  // placeholder

        // Verify character widths
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        #expect(t.getCharData(col: 2, row: 0)?.width == 2)
        #expect(t.getCharData(col: 4, row: 0)?.width == 2)

        // Cursor should be at column 6 after 3 double-width characters
        #expect(t.buffer.x == 6)
    }

    @Test func testCJKMixedWithAscii ()
    {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // Test mixed ASCII and CJK characters
        t.feed (text: "aあbいc")

        // 'a' at col 0 (width 1)
        #expect(t.getCharacter(col: 0, row: 0) == "a")
        #expect(t.getCharData(col: 0, row: 0)?.width == 1)

        // 'あ' at col 1 (width 2)
        #expect(t.getCharacter(col: 1, row: 0) == "あ")
        #expect(t.getCharData(col: 1, row: 0)?.width == 2)

        // 'b' at col 3 (width 1)
        #expect(t.getCharacter(col: 3, row: 0) == "b")
        #expect(t.getCharData(col: 3, row: 0)?.width == 1)

        // 'い' at col 4 (width 2)
        #expect(t.getCharacter(col: 4, row: 0) == "い")
        #expect(t.getCharData(col: 4, row: 0)?.width == 2)

        // 'c' at col 6 (width 1)
        #expect(t.getCharacter(col: 6, row: 0) == "c")
        #expect(t.getCharData(col: 6, row: 0)?.width == 1)

        // Cursor should be at column 7
        #expect(t.buffer.x == 7)
    }

    @Test func testChineseCharacterPositioning ()
    {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // Test Chinese characters (also double-width)
        t.feed (text: "中文字")

        #expect(t.getCharacter(col: 0, row: 0) == "中")
        #expect(t.getCharacter(col: 2, row: 0) == "文")
        #expect(t.getCharacter(col: 4, row: 0) == "字")

        // All should be width 2
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        #expect(t.getCharData(col: 2, row: 0)?.width == 2)
        #expect(t.getCharData(col: 4, row: 0)?.width == 2)

        #expect(t.buffer.x == 6)
    }
    @Test func testZwJSequencePreservesVariationSelector16() {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        let sequence = "👩‍❤\u{FE0F}"
        t.feed (text: "\(sequence)\r\n")

        let cell = t.getCharacter (col:0, row: 0)
        #expect(cell != nil)
        let char0_0 = cell ?? " "
        #expect(char0_0.unicodeScalars.contains { $0.value == 0xFE0F })
    }

    @Test func testZwJSequencePreservesVariationSelector15() {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        let sequence = "👩‍❤\u{FE0E}"
        t.feed (text: "\(sequence)\r\n")

        let cell = t.getCharacter (col:0, row: 0)
        #expect(cell != nil)
        let char0_0 = cell ?? " "
        #expect(char0_0.unicodeScalars.contains { $0.value == 0xFE0E })
    }

    @Test func testBufferTranslationUsesCharacterProviderForExtendedGrapheme() {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        let sequence = "👩‍👩‍👦‍👦"
        t.feed (text: "\(sequence)X")

        let line = t.buffer.translateBufferLineToString(
            lineIndex: t.buffer.yDisp,
            trimRight: true,
            startCol: 0,
            endCol: -1,
            skipNullCellsFollowingWide: true,
            characterProvider: { t.getCharacter(for: $0) }
        ).replacingOccurrences(of: "\u{0}", with: " ")

        #expect(line == "\(sequence)X")
    }

    @Test func testNoBreakSpaceWidth() {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // Test NO-BREAK SPACE (U+00A0) positioning
        // NBSP should have width 1, same as regular space
        // This is important for applications like Claude Code that use NBSP after prompt
        t.feed (text: ">\u{00A0}x")  // > + NBSP + x

        // '>' at col 0 (width 1)
        #expect(t.getCharacter(col: 0, row: 0) == ">")
        #expect(t.getCharData(col: 0, row: 0)?.width == 1)

        // NBSP at col 1 (width 1, NOT -1)
        #expect(t.getCharacter(col: 1, row: 0) == "\u{00A0}")
        #expect(t.getCharData(col: 1, row: 0)?.width == 1)

        // 'x' at col 2 (width 1)
        #expect(t.getCharacter(col: 2, row: 0) == "x")
        #expect(t.getCharData(col: 2, row: 0)?.width == 1)

        // Cursor should be at column 3
        #expect(t.buffer.x == 3)
    }

}
#endif
