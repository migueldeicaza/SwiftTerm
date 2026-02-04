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

    // MARK: - Unicode Tests Ported from Ghostty

    /// Test VS15 (text presentation) makes wide character narrow
    /// From Ghostty: "Terminal: VS15 to make narrow character"
    @Test func testVS15MakesWideCharNarrow() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Umbrella with rain drops (☔) - typically width 2
        // followed by VS15 (U+FE0E) to make it narrow (width 1)
        t.feed(text: "\u{2614}\u{FE0E}x")

        // With VS15, the umbrella should be width 1
        let umbrellaCell = t.getCharData(col: 0, row: 0)
        #expect(umbrellaCell?.width == 1)

        // 'x' should be at col 1 (not col 2)
        let xChar = t.getCharacter(col: 1, row: 0)
        #expect(xChar == "x")
    }

    /// Test VS15 on already narrow emoji doesn't change width
    /// From Ghostty: "Terminal: VS15 on already narrow emoji"
    @Test func testVS15OnAlreadyNarrowEmoji() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Thunder cloud and rain (⛈) - width 1 by default
        // VS15 should keep it at width 1
        t.feed(text: "\u{26C8}\u{FE0E}x")

        let cloudCell = t.getCharData(col: 0, row: 0)
        #expect(cloudCell?.width == 1)

        // 'x' should be at col 1
        #expect(t.getCharacter(col: 1, row: 0) == "x")
    }

    /// Test VS16 (emoji presentation) makes narrow character wide
    /// From Ghostty: "Terminal: VS16 to make wide character with mode 2027"
    @Test func testVS16MakesNarrowCharWide() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Heart (❤) - can be narrow or wide
        // VS16 (U+FE0F) should make it width 2
        t.feed(text: "\u{2764}\u{FE0F}x")

        let heartCell = t.getCharData(col: 0, row: 0)
        #expect(heartCell?.width == 2)

        // 'x' should be at col 2 (after the wide heart)
        #expect(t.getCharacter(col: 2, row: 0) == "x")
    }

    /// Test invalid VS15 following emoji that doesn't support it stays wide
    /// From Ghostty: "Terminal: print invalid VS15 following emoji is wide"
    @Test func testInvalidVS15EmojiStaysWide() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Brain emoji (🧠) doesn't support VS15
        // It should remain width 2
        t.feed(text: "\u{1F9E0}\u{FE0E}x")

        let brainCell = t.getCharData(col: 0, row: 0)
        #expect(brainCell?.width == 2)

        // 'x' should be at col 2
        #expect(t.getCharacter(col: 2, row: 0) == "x")
    }

    /// Test VS15 in ZWJ sequence (invalid placement) is handled
    /// From Ghostty: "Terminal: print invalid VS15 in emoji ZWJ sequence"
    @Test func testInvalidVS15InZWJSequence() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Woman emoji + invalid VS15 + ZWJ + Boy emoji
        // The sequence should still render as a combined character
        t.feed(text: "\u{1F469}\u{FE0E}\u{200D}\u{1F466}x")

        // The combined emoji should be width 2
        let emojiCell = t.getCharData(col: 0, row: 0)
        #expect(emojiCell?.width == 2)
    }

    /// Test multiple Fitzpatrick skin tone modifiers
    /// From Ghostty: comprehensive skin tone testing
    @Test func testFitzpatrickModifiers() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Thumbs up with different skin tones
        // 🏻 Light, 🏼 Medium-Light, 🏽 Medium, 🏾 Medium-Dark, 🏿 Dark
        t.feed(text: "👍🏻\r\n👍🏼\r\n👍🏽\r\n👍🏾\r\n👍🏿\r\n")

        // All should be combined into single grapheme clusters
        #expect(t.getCharacter(col: 0, row: 0) == "👍🏻")
        #expect(t.getCharacter(col: 0, row: 1) == "👍🏼")
        #expect(t.getCharacter(col: 0, row: 2) == "👍🏽")
        #expect(t.getCharacter(col: 0, row: 3) == "👍🏾")
        #expect(t.getCharacter(col: 0, row: 4) == "👍🏿")

        // All should be width 2
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        #expect(t.getCharData(col: 0, row: 1)?.width == 2)
        #expect(t.getCharData(col: 0, row: 2)?.width == 2)
        #expect(t.getCharData(col: 0, row: 3)?.width == 2)
        #expect(t.getCharData(col: 0, row: 4)?.width == 2)
    }

    /// Test flag emoji (regional indicator symbols)
    /// From Ghostty: regional indicator handling
    /// Note: SwiftTerm currently doesn't combine regional indicators into flags
    @Test func testFlagEmoji() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Flag emojis are two regional indicator letters
        // US flag: 🇺🇸 = U+1F1FA (Regional Indicator U) + U+1F1F8 (Regional Indicator S)
        t.feed(text: "\u{1F1FA}\u{1F1F8}x")

        // Get the character at position 0
        let char0 = t.getCharacter(col: 0, row: 0)
        #expect(char0 != nil)

        // SwiftTerm currently treats each regional indicator as separate
        // TODO: Implement regional indicator combining for flag emoji
        // For now, verify no crash and basic processing
        let char0Data = t.getCharData(col: 0, row: 0)
        #expect(char0Data != nil)
    }

    /// Test keycap emoji sequences (digit + VS16 + combining enclosing keycap)
    /// From Ghostty: keycap sequence handling
    @Test func testKeycapEmoji() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Keycap 1: 1️⃣ = '1' + VS16 + U+20E3 (Combining Enclosing Keycap)
        t.feed(text: "1\u{FE0F}\u{20E3}x")

        // The keycap should be a single grapheme cluster
        let keycapChar = t.getCharacter(col: 0, row: 0)
        #expect(keycapChar?.unicodeScalars.contains { $0 == "1" } == true)

        // Keycap should be width 2 (with VS16)
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
    }

    /// Test keycap with VS15 (text style, narrow)
    /// From Ghostty: "Terminal: keypad sequence VS15"
    @Test func testKeycapEmojiVS15() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Keycap with VS15: '1' + VS15 + U+20E3
        // Should be narrow (width 1)
        t.feed(text: "1\u{FE0E}\u{20E3}x")

        let keycapChar = t.getCharacter(col: 0, row: 0)
        #expect(keycapChar != nil)

        // With VS15, should be width 1
        #expect(t.getCharData(col: 0, row: 0)?.width == 1)

        // 'x' should be at col 1
        #expect(t.getCharacter(col: 1, row: 0) == "x")
    }

    /// Test tag sequences (e.g., subdivision flags)
    /// From Ghostty: tag sequence handling
    @Test func testTagSequenceFlags() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Scotland flag: 🏴󠁧󠁢󠁳󠁣󠁴󠁿 = black flag + tag_g + tag_b + tag_s + tag_c + tag_t + cancel_tag
        t.feed(text: "🏴󠁧󠁢󠁳󠁣󠁴󠁿x")

        // Should be a single grapheme cluster
        let flagChar = t.getCharacter(col: 0, row: 0)
        #expect(flagChar != nil)

        // Should be width 2
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
    }

    /// Test multiple combining characters on single base
    /// From Ghostty: grapheme cluster handling
    @Test func testMultipleCombiningCharacters() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // 'e' with multiple combining diacriticals
        // e + acute + tilde = ḗ (approximately)
        t.feed(text: "e\u{0301}\u{0303}x")

        // Should combine into single grapheme
        let combinedChar = t.getCharacter(col: 0, row: 0)
        #expect(combinedChar?.unicodeScalars.count == 3)

        // Should be width 1
        #expect(t.getCharData(col: 0, row: 0)?.width == 1)

        // 'x' should be at col 1
        #expect(t.getCharacter(col: 1, row: 0) == "x")
    }

    /// Test emoji with multiple modifiers (skin tone + ZWJ + profession)
    /// From Ghostty: complex ZWJ sequences
    @Test func testComplexEmojiZWJWithModifiers() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Woman technologist with skin tone: 👩🏻‍💻
        t.feed(text: "👩🏻‍💻x")

        // Should be single grapheme cluster
        let emojiChar = t.getCharacter(col: 0, row: 0)
        #expect(emojiChar == "👩🏻‍💻")

        // Should be width 2
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)

        // 'x' should be at col 2
        #expect(t.getCharacter(col: 2, row: 0) == "x")
    }

    /// Test Korean Hangul syllable blocks (composed characters)
    /// From Ghostty: Korean character handling
    @Test func testKoreanHangul() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Korean text: 한글 (Hangul)
        t.feed(text: "한글x")

        // Each Hangul syllable should be width 2
        #expect(t.getCharacter(col: 0, row: 0) == "한")
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        #expect(t.getCharacter(col: 2, row: 0) == "글")
        #expect(t.getCharData(col: 2, row: 0)?.width == 2)
        #expect(t.getCharacter(col: 4, row: 0) == "x")
    }

    /// Test that overwriting wide character clears spacer cell
    /// From Ghostty: wide character overwrite handling
    @Test func testOverwriteWideCharacter() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Write a wide character
        t.feed(text: "あ")
        #expect(t.getCharacter(col: 0, row: 0) == "あ")
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)

        // Move cursor back and overwrite with narrow character
        t.feed(text: "\u{1b}[1Gx")  // Move to col 1, write 'x'

        // The wide character should be replaced
        #expect(t.getCharacter(col: 0, row: 0) == "x")
        #expect(t.getCharData(col: 0, row: 0)?.width == 1)
    }

    /// Test wide character at end of line wraps correctly
    /// From Ghostty: wide character wrapping at line end
    @Test func testWideCharacterWrapping() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Use a narrow terminal
        let cols = t.cols

        // Fill line to leave only 1 cell, then insert wide character
        let fillCount = cols - 1
        let fill = String(repeating: "x", count: fillCount)
        t.feed(text: fill)
        t.feed(text: "あ")  // Wide character that needs 2 cells

        // Wide character should wrap to next line since it needs 2 cells
        // but only 1 is available
        #expect(t.getCharacter(col: 0, row: 1) == "あ")
        #expect(t.buffer.y == 1)  // Should be on second line
    }

}
#endif
