//
//  UnicodeTests.swift
//  
// Tests for assorted rendering capabilities
//
#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

private enum UnicodeColumnWidthReference {
    static func columnWidth (_ rune: Unicode.Scalar) -> Int
    {
        let value = rune.value
        if value == 0 {
            return 0
        }
        if value < 0x20 {
            return -1
        }
        if value < 0x7F {
            return 1
        }
        if value < 0xA0 {
            return -1
        }
        if isIndicConjunctLinker(value) {
            return 0
        }

        switch rune.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return 0
        case .format:
            if value == 0x00AD || isGraphemePrepend(value) {
                return 1
            }
            return 0
        case .lineSeparator, .paragraphSeparator:
            return 0
        case .modifierSymbol:
            if rune.properties.isEmojiModifier {
                return 2
            }
            if value == 0xFF3E || value == 0xFF40 || value == 0xFFE3 {
                return 2
            }
        default:
            break
        }

        if (0x1160...0x11FF).contains (value) || (0xD7B0...0xD7FF).contains (value) {
            return 0
        }
        if (0x1F1E6...0x1F1FF).contains (value) {
            return 2
        }
        if isEastAsianWide (value) {
            return 2
        }
        return 1
    }

    private static func isEastAsianWide (_ value: UInt32) -> Bool
    {
        let ranges = UnicodeWidthData.eastAsianWide
        var lowerBound = 0
        var upperBound = ranges.count - 1
        while lowerBound <= upperBound {
            let middle = (lowerBound + upperBound) / 2
            if value < ranges [middle].lo {
                upperBound = middle - 1
            } else if value > ranges [middle].hi {
                lowerBound = middle + 1
            } else {
                return true
            }
        }
        return false
    }

    private static func isGraphemePrepend(_ value: UInt32) -> Bool {
        switch value {
        case 0x0600...0x0605, 0x06DD, 0x070F, 0x0890...0x0891,
             0x08E2, 0x110BD, 0x110CD:
            return true
        default:
            return false
        }
    }

    private static func isIndicConjunctLinker(_ value: UInt32) -> Bool {
        switch value {
        case 0x094D, 0x09CD, 0x0ACD, 0x0B4D, 0x0C4D, 0x0D4D,
             0x1039, 0x17D2, 0x1A60, 0x1B44, 0x1BAB, 0xA9C0,
             0xAAF6, 0x10A3F, 0x11133, 0x113D0, 0x1193E, 0x11A47,
             0x11A99, 0x11F42:
            return true
        default:
            return false
        }
    }
}

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

    @Test func testCombiningCharacterUsesCellBeforeCursor() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Write elsewhere after the base glyph, then restore the cursor to the
        // position after the base before sending the combining mark.
        t.feed(text: "e")
        t.feed(text: "\u{1b}[2;1Hx")
        t.feed(text: "\u{1b}[1;2H")
        t.feed(text: "\u{0300}")

        #expect(t.getCharacter(col: 0, row: 0) == "e\u{0300}")
        #expect(t.getCharacter(col: 0, row: 1) == "x")
    }

    @Test func testCombiningCharacterFindsWideCellBeforeCursor() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        t.feed(text: "\u{1100}")
        t.feed(text: "\u{1b}[2;1Hx")
        t.feed(text: "\u{1b}[1;3H")
        t.feed(text: "\u{0300}")

        #expect(t.getCharacter(col: 0, row: 0) == "\u{1100}\u{0300}")
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        #expect(t.getCharacter(col: 0, row: 1) == "x")
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

    @Test func testIndicZWJConjunctUsesOneCell() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        let conjunct = "\u{0915}\u{094D}\u{200D}\u{0937}"
        t.feed(text: "\(conjunct)x")

        #expect(t.getCharacter(col: 0, row: 0) == Character(conjunct))
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        #expect(t.getCharacter(col: 1, row: 0) == "\u{0}")
        #expect(t.getCharacter(col: 2, row: 0) == "x")
        #expect(t.buffer.x == 3)
    }

    @Test func testBengaliSpacingMarkWidensGrapheme() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!
        let grapheme = "\u{0995}\u{09BE}"

        t.feed(text: grapheme)
        t.feed(text: "x")

        #expect(t.getCharacter(col: 0, row: 0) == Character(grapheme))
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        #expect(t.getCharacter(col: 1, row: 0) == "\u{0}")
        #expect(t.getCharacter(col: 2, row: 0) == "x")
        #expect(t.buffer.x == 3)
    }

    @Test func testSpacingMarkWideningAtRightMarginWrapsWholeGrapheme() {
        let harness = TerminalTestHarness.makeTerminal(cols: 4, rows: 3)
        let t = harness.terminal
        let grapheme = "\u{0995}\u{09BE}"

        t.feed(text: "xxx\u{0995}")
        t.feed(text: "\u{09BE}x")

        #expect(t.getCharacter(col: 3, row: 0) == "\0")
        #expect(t.getCharData(col: 3, row: 0)?.width == 1)
        #expect(t.getCharData(col: 0, row: 1)?.getText() == grapheme)
        #expect(t.getCharData(col: 0, row: 1)?.width == 2)
        #expect(t.getCharData(col: 1, row: 1)?.width == 0)
        #expect(t.getCharacter(col: 2, row: 1) == "x")
        #expect(t.buffer.lines[1].isWrapped)
        #expect(t.buffer.y == 1)
        #expect(t.buffer.x == 3)
    }

    @Test func testBengaliViramaConjunctStaysTwoCellsWide() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!
        let grapheme = "\u{0995}\u{09CD}\u{09B7}\u{09CD}\u{09AF}"

        for scalar in grapheme.unicodeScalars {
            t.feed(text: String(scalar))
        }
        t.feed(text: "x")

        #expect(t.getCharacter(col: 0, row: 0) == Character(grapheme))
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        #expect(t.getCharacter(col: 1, row: 0) == "\u{0}")
        #expect(t.getCharacter(col: 2, row: 0) == "x")
        #expect(t.buffer.x == 3)
    }

    @Test func testIndicConjunctBreakLinkerAndConsonantStayInOneGrapheme() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!
        let javaneseLinker = "\u{A98F}\u{A9C0}"
        let javaneseConjunct = "\u{A98F}\u{A9C0}\u{A994}\u{A9B8}"

        t.feed(text: javaneseLinker)
        #expect(t.getCharData(col: 0, row: 0)?.getText() == javaneseLinker)
        #expect(t.getCharData(col: 0, row: 0)?.width == 1)
        #expect(t.buffer.x == 1)

        t.feed(text: "\r\n")
        for scalar in javaneseConjunct.unicodeScalars {
            t.feed(text: String(scalar))
        }
        t.feed(text: "x")

        #expect(t.getCharData(col: 0, row: 1)?.getText() == javaneseConjunct)
        #expect(t.getCharData(col: 0, row: 1)?.width == 2)
        #expect(t.getCharacter(col: 1, row: 1) == "\u{0}")
        #expect(t.getCharacter(col: 2, row: 1) == "x")
        #expect(t.buffer.x == 3)
        #expect(t.buffer.translateBufferLineToString(
            lineIndex: 1, trimRight: true,
            skipNullCellsFollowingWide: true) == "\(javaneseConjunct)x")
    }

    @Test func testRepeatedIndicConjunctBreakSequenceStaysTwoCellsWide() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!
        let khmer = "\u{179F}\u{17D2}\u{178A}\u{17D2}\u{179A}\u{17B8}"

        for scalar in khmer.unicodeScalars {
            t.feed(text: String(scalar))
        }

        #expect(t.getCharData(col: 0, row: 0)?.getText() == khmer)
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        #expect(t.buffer.x == 2)
    }

    @Test func testSpacingMarkViramaDoesNotWidenBase() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!
        let grantha = "\u{11315}\u{1134D}"

        t.feed(text: grantha)

        #expect(t.getCharData(col: 0, row: 0)?.getText() == grantha)
        #expect(t.getCharData(col: 0, row: 0)?.width == 1)
        #expect(t.buffer.x == 1)
    }

    @Test func testGraphemePrependAndStandaloneEmojiModifierWidths() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        t.feed(text: "\u{0601}\u{06F1}\r\n\u{1F3FB}x")

        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        #expect(t.getCharacter(col: 1, row: 0) == "\u{0}")
        #expect(t.getCharData(col: 0, row: 1)?.width == 2)
        #expect(t.getCharacter(col: 2, row: 1) == "x")
    }

    @Test func testStandaloneEmojiModifiersDoNotJoinTablePrefix() {
        for value in UInt32(0x1F3FB)...0x1F3FF {
            let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
            let t = h.terminal!
            let modifier = String(Unicode.Scalar(value)!)

            t.feed(text: "║ ")
            let start = t.buffer.x
            t.feed(text: modifier)

            #expect(t.buffer.x - start == 2,
                    "U+\(String(value, radix: 16, uppercase: true)) must move two columns")
            #expect(t.getCharacter(col: 1, row: 0) == " ")
            #expect(t.getCharData(col: 2, row: 0)?.getText() == modifier)
            #expect(t.getCharData(col: 2, row: 0)?.width == 2)
        }
    }

    @Test func testEmojiModifierTailoringIsIndependentOfWriteBoundary() {
        for splitWrites in [false, true] {
            let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
            let t = h.terminal!

            if splitWrites {
                t.feed(text: "\"")
                t.feed(text: "\u{1F3FF}")
                t.feed(text: "\"")
            } else {
                t.feed(text: "\"\u{1F3FF}\"")
            }

            #expect(t.buffer.x == 4)
            #expect(t.getCharacter(col: 0, row: 0) == "\"")
            #expect(t.getCharacter(col: 1, row: 0) == "\u{1F3FF}")
            #expect(t.getCharData(col: 1, row: 0)?.width == 2)
            #expect(t.getCharacter(col: 3, row: 0) == "\"")
        }
    }

    @Test func testEmojiModifierBaseStillJoinsAcrossWriteBoundary() {
        for splitWrites in [false, true] {
            let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
            let t = h.terminal!

            if splitWrites {
                t.feed(text: "\u{270B}")
                t.feed(text: "\u{1F3FD}")
            } else {
                t.feed(text: "\u{270B}\u{1F3FD}")
            }

            #expect(t.buffer.x == 2)
            #expect(t.getCharacter(col: 0, row: 0) == "\u{270B}\u{1F3FD}")
            #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        }
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
    @Test func testFlagEmoji() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // US flag: 🇺🇸 = U+1F1FA (Regional Indicator U) + U+1F1F8 (Regional Indicator S)
        t.feed(text: "\u{1F1FA}\u{1F1F8}x")

        let flagData = t.getCharData(col: 0, row: 0)
        #expect(flagData?.width == 2)

        let flagChar = t.getCharacter(col: 0, row: 0)
        #expect(flagChar == "🇺🇸")

        // 'x' should be at column 2 (flag takes 2 cells)
        let xChar = t.getCharacter(col: 2, row: 0)
        #expect(xChar == "x")
    }

    /// Test multiple flag emoji in sequence
    @Test func testMultipleFlagEmoji() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // US flag followed by GB flag: 🇺🇸🇬🇧
        t.feed(text: "\u{1F1FA}\u{1F1F8}\u{1F1EC}\u{1F1E7}x")

        // First flag at col 0
        #expect(t.getCharacter(col: 0, row: 0) == "🇺🇸")
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)

        // Second flag at col 2
        #expect(t.getCharacter(col: 2, row: 0) == "🇬🇧")
        #expect(t.getCharData(col: 2, row: 0)?.width == 2)

        // 'x' at col 4
        #expect(t.getCharacter(col: 4, row: 0) == "x")
    }

    /// Test odd number of regional indicators (3 RIs = one flag + one unpaired RI)
    @Test func testOddRegionalIndicators() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Three RIs: U+1F1FA + U+1F1F8 + U+1F1EC + 'x'
        // Should produce: 🇺🇸 (flag) + 🇬 (unpaired RI) + x
        t.feed(text: "\u{1F1FA}\u{1F1F8}\u{1F1EC}x")

        // First two RIs combine into US flag at col 0
        #expect(t.getCharacter(col: 0, row: 0) == "🇺🇸")
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)

        // Third RI is unpaired at col 2, width 2
        let thirdChar = t.getCharacter(col: 2, row: 0)
        #expect(thirdChar == "\u{1F1EC}")
        #expect(t.getCharData(col: 2, row: 0)?.width == 2)

        // 'x' at col 4
        #expect(t.getCharacter(col: 4, row: 0) == "x")
    }

    // MARK: - Narrow Regional Indicator mode (.narrow)

    /// In narrow mode, individual RI symbols are width 1, matching system wcwidth().
    @Test func testNarrowRIWidth() {
        var opts = TerminalOptions.default
        opts.regionalIndicatorWidth = .narrow
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: opts) { _ in }
        let t = h.terminal!

        t.feed(text: "\u{1F1EB}x")  // Single RI F + x
        #expect(t.getCharData(col: 0, row: 0)?.width == 1)
        #expect(t.getCharacter(col: 1, row: 0) == "x")
    }

    /// In narrow mode, two RIs combine into a width-2 flag.
    @Test func testNarrowFlagCombinedWidth() {
        var opts = TerminalOptions.default
        opts.regionalIndicatorWidth = .narrow
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: opts) { _ in }
        let t = h.terminal!

        t.feed(text: "\u{1F1EB}\u{1F1F7}x")  // 🇫🇷 + x
        #expect(t.getCharacter(col: 0, row: 0) == "🇫🇷")
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        #expect(t.getCharData(col: 1, row: 0)?.width == 0)  // padding
        #expect(t.getCharacter(col: 2, row: 0) == "x")
    }

    /// In narrow mode, cursor position matches wcwidth()-based expectations.
    @Test func testNarrowFlagCursorPosition() {
        var opts = TerminalOptions.default
        opts.regionalIndicatorWidth = .narrow
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: opts) { _ in }
        let t = h.terminal!

        t.feed(text: "A\u{1F1E9}\u{1F1EA}B")  // A + 🇩🇪 + B
        #expect(t.buffer.x == 4)  // A(1) + flag(2) + B(1)
        #expect(t.getCharacter(col: 1, row: 0) == "🇩🇪")
        #expect(t.getCharacter(col: 3, row: 0) == "B")
    }

    /// In narrow mode, overwriting an RI at the same position does not combine.
    @Test func testNarrowRIOverwriteDoesNotCombine() {
        var opts = TerminalOptions.default
        opts.regionalIndicatorWidth = .narrow
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: opts) { _ in }
        let t = h.terminal!

        t.feed(text: "     \u{1F1EB}")  // F at col 5
        #expect(t.getCharData(col: 5, row: 0)?.width == 1)

        // Move cursor back to col 5 and write D — should overwrite, not combine
        t.feed(text: "\u{1b}[1;6H\u{1F1E9}")
        #expect(t.getCharacter(col: 5, row: 0) == "\u{1F1E9}")
        #expect(t.getCharData(col: 5, row: 0)?.width == 1)
    }

    /// In narrow mode, flags on different lines combine correctly after cursor repositioning.
    @Test func testNarrowFlagCombiningWithCursorRepositioning() {
        var opts = TerminalOptions.default
        opts.regionalIndicatorWidth = .narrow
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: opts) { _ in }
        let t = h.terminal!

        t.feed(text: "\u{1F1EB}\u{1F1F7}")  // 🇫🇷 on line 0
        #expect(t.getCharacter(col: 0, row: 0) == "🇫🇷")

        t.feed(text: "\r\n\u{1F1E9}\u{1F1EA}")  // 🇩🇪 on line 1
        #expect(t.getCharacter(col: 0, row: 1) == "🇩🇪")

        // Move back to line 0, repaint 🇫🇷
        t.feed(text: "\u{1b}[1;1H\u{1F1EB}\u{1F1F7}")
        #expect(t.getCharacter(col: 0, row: 0) == "🇫🇷")
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
    }

    /// In narrow mode, odd number of RIs: flag + unpaired RI (width 1).
    @Test func testNarrowOddRegionalIndicators() {
        var opts = TerminalOptions.default
        opts.regionalIndicatorWidth = .narrow
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: opts) { _ in }
        let t = h.terminal!

        t.feed(text: "\u{1F1FA}\u{1F1F8}\u{1F1EC}x")
        #expect(t.getCharacter(col: 0, row: 0) == "🇺🇸")
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        #expect(t.getCharacter(col: 2, row: 0) == "\u{1F1EC}")
        #expect(t.getCharData(col: 2, row: 0)?.width == 1)
        #expect(t.getCharacter(col: 3, row: 0) == "x")
    }

    /// Default (wide) mode is unchanged — individual RIs are still width 2.
    @Test func testDefaultWideRIUnchanged() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        t.feed(text: "\u{1F1EB}x")
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        #expect(t.getCharacter(col: 2, row: 0) == "x")
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

    @Test func testHangulGraphemeDoesNotDependOnInputChunking() {
        for sequence in ["\u{1100}\u{1100}", "\u{1100}\u{AC01}"] {
            let singleWrite = TerminalTestHarness.makeTerminal().terminal
            let splitWrite = TerminalTestHarness.makeTerminal().terminal

            singleWrite.feed(text: sequence)
            for scalar in sequence.unicodeScalars {
                splitWrite.feed(text: String(scalar))
            }

            #expect(singleWrite.getCharData(col: 0, row: 0)?.getText() == sequence)
            #expect(singleWrite.getCharData(col: 0, row: 0)?.width == 2)
            #expect(singleWrite.getCharData(col: 1, row: 0)?.width == 0)
            #expect(singleWrite.buffer.x == 2)
            #expect(splitWrite.getCharData(col: 0, row: 0)?.getText() == sequence)
            #expect(splitWrite.getCharData(col: 0, row: 0)?.width == 2)
            #expect(splitWrite.getCharData(col: 1, row: 0)?.width == 0)
            #expect(splitWrite.buffer.x == singleWrite.buffer.x)
        }
    }

    /// `handlePrintSlow` caches the last scalar of the cell before the cursor
    /// instead of re-reading the buffer for every incoming scalar. A stale
    /// cache would show up as a screen that depends on how the bytes arrive,
    /// so feed the same corpus whole, one scalar at a time, and one byte at a
    /// time, and require the three screens to agree.
    @Test func testCombiningIsIndependentOfInputChunking() {
        let corpus = [
            "e\u{0301}cole",                              // base + Extend
            "\u{0915}\u{094D}\u{0937}\u{093F}",           // Indic conjunct
            "\u{0600}9\u{0601}8",                         // Prepend
            "\u{1100}\u{1161}\u{11A8}\u{AC00}\u{11A8}",   // Hangul jamo
            "\u{1F1E6}\u{1F1E7}\u{1F1E8}",                // regional indicators
            "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F466}", // emoji ZWJ
            "\u{270B}\u{1F3FD}\u{2764}\u{FE0F}\u{2764}\u{FE0E}",
            "a\u{200B}b\u{00AD}\u{0301}c",                // controls
            "\u{0E01}\u{0E33}\u{0E34}",                   // Thai
            "\u{4E00}\u{AC01}\u{1F600}x",                 // wide runs
        ].joined()

        func screen(feeding chunks: [[UInt8]]) -> [String] {
            let terminal = TerminalTestHarness.makeTerminal().terminal
            for chunk in chunks {
                terminal.feed(byteArray: chunk)
            }
            var rows: [String] = []
            for row in 0..<3 {
                var line = ""
                for col in 0..<terminal.cols {
                    line += terminal.getText(col: col, row: row) ?? "?"
                }
                rows.append(line)
            }
            rows.append("cursor=\(terminal.buffer.x),\(terminal.buffer.y)")
            return rows
        }

        let whole = screen(feeding: [Array(corpus.utf8)])
        let perScalar = screen(feeding: corpus.unicodeScalars.map {
            Array(String($0).utf8)
        })
        let perByte = screen(feeding: Array(corpus.utf8).map { [$0] })

        #expect(whole == perScalar)
        #expect(whole == perByte)
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

    // SwiftTerm uses Unicode 17 data. Swift 6.2 has older Unicode properties,
    // so an equality test against that standard library gives false failures
    // for Unicode 17 scalars. Run the parity tests only when the compiler has
    // Unicode 17 data. The generated-data checksum and boundary tests still
    // run with older compilers.
#if compiler(>=6.4)
    // UnicodeUtil.isVariationSelector/isEmojiModifier/isCombining are range
    // tests used in the hot parse path. Unicode has extended these property
    // sets before (U+180F joined Variation_Selector in Unicode 14), so verify
    // the ranges against the stdlib's Unicode tables for every scalar; this
    // fails when a toolchain update ships data the ranges do not cover.
    @Test func testScalarPropertyRangesMatchStdlib() {
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else {
                continue
            }
            let properties = scalar.properties
            #expect(UnicodeUtil.isVariationSelector(value) == properties.isVariationSelector,
                    "isVariationSelector mismatch at U+\(String(value, radix: 16, uppercase: true))")
            #expect(UnicodeUtil.isEmojiModifier(value) == properties.isEmojiModifier,
                    "isEmojiModifier mismatch at U+\(String(value, radix: 16, uppercase: true))")
            #expect(UnicodeUtil.isCombining(value) == (properties.canonicalCombiningClass != .notReordered),
                    "isCombining mismatch at U+\(String(value, radix: 16, uppercase: true))")
        }
    }
#endif

    // handlePrint decides whether to combine with the previous cell from
    // chWidth == 0 alone; it does not test the combining class. That is
    // sound only while every scalar with a nonzero canonical combining
    // class is zero-width. If a Unicode update ever breaks this, the
    // combining test must return to handlePrint's shouldTryCombine.
    @Test func testCombiningScalarsAreZeroWidth() {
        var combiningCount = 0
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else {
                continue
            }
            if UnicodeUtil.isCombining(value) {
                combiningCount += 1
                #expect(UnicodeUtil.columnWidth(rune: scalar) == 0,
                        "Nonzero width for combining scalar U+\(String(value, radix: 16, uppercase: true))")
            }
        }
        #expect(combiningCount > 0)
    }

    @Test func testGeneratedColumnWidthBoundaries() {
        let expectedWidths: [(UInt32, Int)] = [
            (0x0000, 0),
            (0x001F, -1),
            (0x0020, 1),
            (0x007E, 1),
            (0x007F, -1),
            (0x009F, -1),
            (0x00A0, 1),
            (0x00AD, 1),
            (0x0600, 1),  // Grapheme prepend.
            (0x110BD, 1), // Grapheme prepend.
            (0x0300, 0),  // Nonspacing mark.
            (0x0903, 0),  // Spacing mark.
            (0x0488, 0),  // Enclosing mark.
            (0x2028, 0),  // Line separator.
            (0x2029, 0),  // Paragraph separator.
            (0xFF3E, 2),
            (0xFF40, 2),
            (0xFFE3, 2),
            (0x1160, 0),
            (0x11FF, 0),
            (0xD7B0, 0),
            (0xD7FF, 0),
            (0x1F1E6, 2),
            (0x1F1FF, 2),
            (0x2319, 1),  // Before the U+231A...U+231B wide range.
            (0x231A, 2),
            (0x231B, 2),
            (0x231C, 1),  // After the U+231A...U+231B wide range.
            (0x1F3FB, 2), // Standalone emoji modifier.
            (0x10000, 1),
            (0x10FFFF, 1),
        ]

        for (value, expectedWidth) in expectedWidths {
            let scalar = Unicode.Scalar (value)!
            #expect(UnicodeUtil.columnWidth (rune: scalar) == expectedWidth,
                    "Unexpected width at U+\(String(format: "%04X", value))")
        }

        // Unicode.Scalar cannot contain surrogate values. Test the generated
        // lookup directly to make sure that these table positions are safe.
        #expect(UnicodeWidthData.columnWidth (0xD800) == 1)
        #expect(UnicodeWidthData.columnWidth (0xDFFF) == 1)
    }

    @Test func testGeneratedGraphemePropertiesUsedByBatching() {
        let ordinary = UnicodeUtil.graphemeProperties(0x0061)
        let prepend = UnicodeUtil.graphemeProperties(0x0600)
        let spacingMark = UnicodeUtil.graphemeProperties(0x0903)
        let consonant = UnicodeUtil.graphemeProperties(0x0995)
        let hangul = UnicodeUtil.graphemeProperties(0x1100)

        #expect(ordinary == 0)
        #expect(prepend & UnicodeWidthData.graphemePrependMask != 0)
        #expect(spacingMark & UnicodeWidthData.graphemeSpacingMarkMask != 0)
        #expect(UnicodeUtil.graphemeProperties(0x09BE) &
                UnicodeWidthData.graphemeExtendMask != 0)
        // The width policy and the break property are separate sets.
        #expect(UnicodeUtil.isSpacingMarkWidth(0x09BE))
        #expect(UnicodeUtil.isVirama(0x094D))
        #expect(!UnicodeUtil.isVirama(0x0915))
        #expect(UnicodeUtil.indicConjunctBreak(properties: consonant) == .consonant)
        #expect(UnicodeUtil.isHangulGraphemeComponent(properties: hangul))
        #expect(!UnicodeUtil.isHangulGraphemeComponent(properties: ordinary))
        #expect(UnicodeUtil.isEmojiModifierBase(0x270B))
        #expect(UnicodeUtil.isEmojiModifierBase(0x1F44D))
        #expect(!UnicodeUtil.isEmojiModifierBase(0x0020))
        #expect(!UnicodeUtil.isEmojiModifierBase(0x1F3FB))
    }

    /// Every scalar in the corpus below carries the Hangul class that the
    /// join table indexes with.
    @Test func testGeneratedHangulClasses() {
        func hangulClass(_ value: UInt32) -> UInt8 {
            UnicodeUtil.graphemeClass(
                properties: UnicodeUtil.graphemeProperties(value))
        }

        #expect(hangulClass(0x1100) == 1)   // L
        #expect(hangulClass(0xA960) == 1)   // L
        #expect(hangulClass(0x1160) == 2)   // V
        #expect(hangulClass(0xD7B0) == 2)   // V
        #expect(hangulClass(0x11A8) == 3)   // T
        #expect(hangulClass(0xD7CB) == 3)   // T
        #expect(hangulClass(0xAC00) == 4)   // LV
        #expect(hangulClass(0xAC01) == 5)   // LVT
        #expect(hangulClass(0x0061) == 0)
        #expect(hangulClass(0x200B) == UnicodeWidthData.graphemeClassControl)
        #expect(!UnicodeUtil.isHangulGraphemeComponent(
            properties: UnicodeUtil.graphemeProperties(0x200B)))
    }

    /// `Terminal.handlePrintSlow` acts on `.breaks` and `.joins` without
    /// segmenting, so both must agree with the standard library. Only
    /// `.undecided` may disagree, and it always defers.
    @Test func testGraphemeMayJoinMatchesSegmentation() {
        func hex(_ value: UInt32) -> String {
            "U+" + String(format: "%04X", value)
        }

        func join(_ previous: UInt32, _ incoming: UInt32) -> UnicodeUtil.GraphemeJoin {
            guard let incomingScalar = Unicode.Scalar(incoming) else {
                return .undecided
            }
            if UnicodeUtil.isEmojiModifier(incoming) {
                return UnicodeUtil.isEmojiModifierBase(previous) ? .joins : .breaks
            }
            return UnicodeUtil.graphemeJoinNonEmojiModifier(
                previous: previous,
                previousProperties: UnicodeUtil.graphemeProperties(previous),
                incoming: incoming,
                incomingProperties: UnicodeUtil.graphemeProperties(incoming),
                incomingWidth: UnicodeUtil.columnWidth(rune: incomingScalar))
        }

        func mayJoin(_ previous: UInt32, _ incoming: UInt32) -> Bool {
            join(previous, incoming) != .breaks
        }

        // Pairs that Swift joins into one Character must never read false.
        let joining: [(UInt32, UInt32)] = [
            (0x0041, 0x0301),           // A + combining acute
            (0x1F468, 0x200D),          // man + ZWJ
            (0x200D, 0x1F469),          // ZWJ + woman
            (0x270B, 0x1F3FD),          // raised hand + skin tone
            (0x2764, 0xFE0F),           // heart + VS16
            (0x1F1E6, 0x1F1E7),         // regional indicator pair
            (0x1100, 0x1100),           // L x L
            (0x1100, 0x1161),           // L x V
            (0xAC00, 0x11A8),           // LV x T
            (0xAC01, 0x11A8),           // LVT x T
            (0x1161, 0x1161),           // V x V
            (0x0600, 0x0041),           // Prepend x A
            (0x094D, 0x0915),           // virama x consonant
        ]
        for (previous, incoming) in joining {
            #expect(mayJoin(previous, incoming),
                    "\(hex(previous)) + \(hex(incoming)) must stay joinable")
        }

        // Runs of the vtebench unicode corpus that must stay on the fast path.
        let breaking: [(UInt32, UInt32)] = [
            (0xAC00, 0xAC01),           // LV x LV
            (0xAC01, 0xAC02),           // LVT x LVT
            (0xD7A3, 0xAC00),
            (0x4E00, 0x4E01),           // CJK
            (0x0915, 0x0916),           // consonant x consonant
            (0x1161, 0x1100),           // V x L
            (0x11A8, 0x1100),           // T x L
            (0x0041, 0x0042),
            (0x0020, 0x1F3FB),          // space x standalone emoji modifier
            (0x0022, 0x1F3FF),          // quote x standalone emoji modifier
        ]
        for (previous, incoming) in breaking {
            #expect(!mayJoin(previous, incoming),
                    "\(hex(previous)) + \(hex(incoming)) must break")
        }

        typealias OracleAliasGroup = (
            scalars: [UInt32], representative: Unicode.Scalar, expectedGCB: UInt8)

        // Unicode 17 changed these 43 GCB assignments. Normalize only the host
        // oracle to equivalent, long-established classes; the classifier still
        // receives every original scalar, property byte, and width.
        let unicode17ExtendRanges: [ClosedRange<UInt32>] = [
            0x1ACF...0x1ADD, 0x1AE0...0x1AEB, 0x10EFA...0x10EFB,
            0x11B60...0x11B60, 0x11B62...0x11B64, 0x11B66...0x11B66,
            0x1E6E3...0x1E6E3, 0x1E6E6...0x1E6E6, 0x1E6EE...0x1E6EF,
            0x1E6F5...0x1E6F5,
        ]
        let ucdVersionSkew: [OracleAliasGroup] = [
            (unicode17ExtendRanges.flatMap { Array($0) }, "\u{0301}", UnicodeWidthData.graphemeExtendMask),
            ([0x11B61, 0x11B65, 0x11B67], "\u{0903}", UnicodeWidthData.graphemeSpacingMarkMask),
            ([0x11A3A], "A", 0), // Prepend in Unicode 16, Other in Unicode 17.
        ]

        // Kirat Rai already has GCB=V in Unicode 16, but host segmenters can
        // restrict GB6-8 to Hangul blocks. This is a UAX #29 conformance proxy,
        // not version skew or an assertion that the host handles these letters.
        let hostSegmenterDivergence: [OracleAliasGroup] = [
            ([0x16D63, 0x16D67, 0x16D68, 0x16D69, 0x16D6A], "\u{1161}", 2), // GCB V.
        ]
        #expect(ucdVersionSkew.map { $0.scalars.count } == [39, 3, 1])
        #expect(hostSegmenterDivergence[0].scalars.count == 5)
        let gcbMask = UnicodeWidthData.graphemeClassMask |
            UnicodeWidthData.graphemePrependMask |
            UnicodeWidthData.graphemeExtendMask |
            UnicodeWidthData.graphemeSpacingMarkMask
        var hostOracleAliases: [UInt32: Unicode.Scalar] = [:]
        for group in ucdVersionSkew + hostSegmenterDivergence {
            #expect(UnicodeUtil.graphemeProperties(group.representative.value) & gcbMask == group.expectedGCB)
            for value in group.scalars {
                #expect(UnicodeUtil.graphemeProperties(value) & gcbMask == group.expectedGCB,
                        "\(hex(value)) has the expected pinned GCB assignment")
                #expect(value != 0x200D && !UnicodeUtil.isRegionalIndicator(value) &&
                        !UnicodeUtil.isEmojiModifier(value) && !UnicodeUtil.isEmojiModifierBase(value))
                hostOracleAliases[value] = group.representative
            }
        }
        #expect(hostOracleAliases.count == 48)

        // A decided answer must match this two-scalar oracle, except for the
        // documented UTS #51 tailoring below. Context-sensitive `.undecided`
        // answers always defer to segmentation.
        var decided = 0
        var undecided = 0
        var mismatches: [String] = []

        func check(_ previous: UInt32, _ incoming: UInt32) {
            guard let previousScalar = Unicode.Scalar(previous),
                  let scalar = Unicode.Scalar(incoming) else { return }
            let answer = join(previous, incoming)
            guard answer != .undecided else {
                undecided += 1
                return
            }
            decided += 1
            var text = String(hostOracleAliases[previous] ?? previousScalar)
            text.unicodeScalars.append(hostOracleAliases[incoming] ?? scalar)
            // Swift follows the default GB9 rule. SwiftTerm tailors emoji
            // modifiers to UTS #51 so that a modifier after a non-base stays
            // visible as a standalone grapheme.
            if UnicodeUtil.isEmojiModifier(incoming) &&
               !UnicodeUtil.isEmojiModifierBase(previous) {
                if answer != .breaks {
                    mismatches.append("\(hex(previous)) + \(hex(incoming)) is \(answer)")
                }
                return
            }
            if (text.count == 1) != (answer == .joins) {
                mismatches.append("\(hex(previous)) + \(hex(incoming)) is \(answer)")
            }
        }

        // A linear sweep over every scalar, on both sides of a set of probes
        // chosen to exercise one rule each.
        let probes: [UInt32] = [
            0x0041,     // ordinary base
            0x0301,     // Extend
            0x0903,     // SpacingMark
            0x200D,     // ZWJ
            0x200B,     // Control
            0x0600,     // Prepend
            0x1100, 0x1161, 0x11A8, 0xAC00, 0xAC01,     // L, V, T, LV, LVT
            0x0915, 0x094D,                             // consonant, linker
            0x1F1E6,    // regional indicator
            0x1F3FB,    // emoji modifier
            0xFE0F,     // VS16
        ]
        for value in UInt32(0x20)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let properties = UnicodeUtil.graphemeProperties(value)
            guard properties != 0 || UnicodeUtil.columnWidth(rune: scalar) <= 0 ||
                  UnicodeUtil.isRegionalIndicator(value) else {
                // A scalar with no property joins nothing and breaks nothing.
                check(0x0041, value)
                check(value, 0x0041)
                continue
            }
            for probe in probes {
                check(probe, value)
                check(value, probe)
            }
        }

        // Every pair within the probe set, which no linear sweep covers.
        for previous in probes {
            for incoming in probes {
                check(previous, incoming)
            }
        }

        #expect(mismatches.isEmpty,
                "\(mismatches.count) mismatches, first: \(mismatches.first ?? "")")
        if !mismatches.isEmpty {
            for entry in mismatches.prefix(20) { print("  " + entry) }
        }
        #expect(decided > undecided * 20)
    }

#if compiler(>=6.4)
    @Test func testGeneratedColumnWidthsMatchReference() {
        var scalarCount = 0
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar (value) else {
                continue
            }
            scalarCount += 1
            let generated = UnicodeUtil.columnWidth (rune: scalar)
            let reference = UnicodeColumnWidthReference.columnWidth (scalar)
            if generated != reference {
                #expect(generated == reference,
                        "Column width mismatch at U+\(String(format: "%04X", value))")
                return
            }
        }
        #expect(scalarCount == 1_112_064)
    }
#endif
}
#endif
