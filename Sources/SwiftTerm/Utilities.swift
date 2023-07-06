//
//  Utilities.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/4/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Foundation

struct UnicodeUtil {
    /**
     * Returns the number of expected bytes on a well-formed UTF8 string based on the first byte of the sequence
     */
    static func expectedSizeFromFirstByte (_ b: UInt8) -> Int
    {
        let x = first [Int (b)];

        // Invalid unicode codepoints, just return 1 for byte, and let higher level pass to print
        if x == xx {
            return -1
        }
        if x == a1 {
            return 1
        }
        return Int(x & 0xf)
    }

    static let xx: UInt8 = 0xF1 // invalid: size 1
    static let a1: UInt8 = 0xF0 // a1CII: size 1
    static let s1: UInt8 = 0x02 // accept 0, size 2
    static let s2: UInt8 = 0x13 // accept 1, size 3
    static let s3: UInt8 = 0x03 // accept 0, size 3
    static let s4: UInt8 = 0x23 // accept 2, size 3
    static let s5: UInt8 = 0x34 // accept 3, size 4
    static let s6: UInt8 = 0x04 // accept 0, size 4
    static let s7: UInt8 = 0x44 // accept 4, size 4

    static var first : [UInt8] =  [
        //   1   2   3   4   5   6   7   8   9   A   B   C   D   E   F
        a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, // 0x00-0x0F
        a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, // 0x10-0x1F
        a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, // 0x20-0x2F
        a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, // 0x30-0x3F
        a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, // 0x40-0x4F
        a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, // 0x50-0x5F
        a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, // 0x60-0x6F
        a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, a1, // 0x70-0x7F

        //   1   2   3   4   5   6   7   8   9   A   B   C   D   E   F
        xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, // 0x80-0x8F
        xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, // 0x90-0x9F
        xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, // 0xA0-0xAF
        xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, // 0xB0-0xBF
        xx, xx, s1, s1, s1, s1, s1, s1, s1, s1, s1, s1, s1, s1, s1, s1, // 0xC0-0xCF
        s1, s1, s1, s1, s1, s1, s1, s1, s1, s1, s1, s1, s1, s1, s1, s1, // 0xD0-0xDF
        s2, s3, s3, s3, s3, s3, s3, s3, s3, s3, s3, s3, s3, s4, s3, s3, // 0xE0-0xEF
        s5, s6, s6, s6, s7, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, xx, // 0xF0-0xFF
    ]
    
    struct LH {
        var lo: UInt32
        var hi: UInt32
    }
    static let combining: [LH] = [
        LH (lo:0x0300, hi: 0x036F), LH (lo: 0x0483, hi: 0x0486), LH (lo: 0x0488, hi: 0x0489),
        LH (lo:0x0591, hi: 0x05BD), LH (lo: 0x05BF, hi: 0x05BF), LH (lo: 0x05C1, hi: 0x05C2),
        LH (lo:0x05C4, hi: 0x05C5), LH (lo: 0x05C7, hi: 0x05C7), LH (lo: 0x0600, hi: 0x0603),
        LH (lo:0x0610, hi: 0x0615), LH (lo: 0x064B, hi: 0x065E), LH (lo: 0x0670, hi: 0x0670),
        LH (lo:0x06D6, hi: 0x06E4), LH (lo: 0x06E7, hi: 0x06E8), LH (lo: 0x06EA, hi: 0x06ED),
        LH (lo:0x070F, hi: 0x070F), LH (lo: 0x0711, hi: 0x0711), LH (lo: 0x0730, hi: 0x074A),
        LH (lo:0x07A6, hi: 0x07B0), LH (lo: 0x07EB, hi: 0x07F3), LH (lo: 0x0901, hi: 0x0902),
        LH (lo:0x093C, hi: 0x093C), LH (lo: 0x0941, hi: 0x0948), LH (lo: 0x094D, hi: 0x094D),
        LH (lo:0x0951, hi: 0x0954), LH (lo: 0x0962, hi: 0x0963), LH (lo: 0x0981, hi: 0x0981),
        LH (lo:0x09BC, hi: 0x09BC), LH (lo: 0x09C1, hi: 0x09C4), LH (lo: 0x09CD, hi: 0x09CD),
        LH (lo:0x09E2, hi: 0x09E3), LH (lo: 0x0A01, hi: 0x0A02), LH (lo: 0x0A3C, hi: 0x0A3C),
        LH (lo:0x0A41, hi: 0x0A42), LH (lo: 0x0A47, hi: 0x0A48), LH (lo: 0x0A4B, hi: 0x0A4D),
        LH (lo:0x0A70, hi: 0x0A71), LH (lo: 0x0A81, hi: 0x0A82), LH (lo: 0x0ABC, hi: 0x0ABC),
        LH (lo:0x0AC1, hi: 0x0AC5), LH (lo: 0x0AC7, hi: 0x0AC8), LH (lo: 0x0ACD, hi: 0x0ACD),
        LH (lo:0x0AE2, hi: 0x0AE3), LH (lo: 0x0B01, hi: 0x0B01), LH (lo: 0x0B3C, hi: 0x0B3C),
        LH (lo:0x0B3F, hi: 0x0B3F), LH (lo: 0x0B41, hi: 0x0B43), LH (lo: 0x0B4D, hi: 0x0B4D),
        LH (lo:0x0B56, hi: 0x0B56), LH (lo: 0x0B82, hi: 0x0B82), LH (lo: 0x0BC0, hi: 0x0BC0),
        LH (lo:0x0BCD, hi: 0x0BCD), LH (lo: 0x0C3E, hi: 0x0C40), LH (lo: 0x0C46, hi: 0x0C48),
        LH (lo:0x0C4A, hi: 0x0C4D), LH (lo: 0x0C55, hi: 0x0C56), LH (lo: 0x0CBC, hi: 0x0CBC),
        LH (lo:0x0CBF, hi: 0x0CBF), LH (lo: 0x0CC6, hi: 0x0CC6), LH (lo: 0x0CCC, hi: 0x0CCD),
        LH (lo:0x0CE2, hi: 0x0CE3), LH (lo: 0x0D41, hi: 0x0D43), LH (lo: 0x0D4D, hi: 0x0D4D),
        LH (lo:0x0DCA, hi: 0x0DCA), LH (lo: 0x0DD2, hi: 0x0DD4), LH (lo: 0x0DD6, hi: 0x0DD6),
        LH (lo:0x0E31, hi: 0x0E31), LH (lo: 0x0E34, hi: 0x0E3A), LH (lo: 0x0E47, hi: 0x0E4E),
        LH (lo:0x0EB1, hi: 0x0EB1), LH (lo: 0x0EB4, hi: 0x0EB9), LH (lo: 0x0EBB, hi: 0x0EBC),
        LH (lo:0x0EC8, hi: 0x0ECD), LH (lo: 0x0F18, hi: 0x0F19), LH (lo: 0x0F35, hi: 0x0F35),
        LH (lo:0x0F37, hi: 0x0F37), LH (lo: 0x0F39, hi: 0x0F39), LH (lo: 0x0F71, hi: 0x0F7E),
        LH (lo:0x0F80, hi: 0x0F84), LH (lo: 0x0F86, hi: 0x0F87), LH (lo: 0x0F90, hi: 0x0F97),
        LH (lo:0x0F99, hi: 0x0FBC), LH (lo: 0x0FC6, hi: 0x0FC6), LH (lo: 0x102D, hi: 0x1030),
        LH (lo:0x1032, hi: 0x1032), LH (lo: 0x1036, hi: 0x1037), LH (lo: 0x1039, hi: 0x1039),
        LH (lo:0x1058, hi: 0x1059), LH (lo: 0x1160, hi: 0x11FF), LH (lo: 0x135F, hi: 0x135F),
        LH (lo:0x1712, hi: 0x1714), LH (lo: 0x1732, hi: 0x1734), LH (lo: 0x1752, hi: 0x1753),
        LH (lo:0x1772, hi: 0x1773), LH (lo: 0x17B4, hi: 0x17B5), LH (lo: 0x17B7, hi: 0x17BD),
        LH (lo:0x17C6, hi: 0x17C6), LH (lo: 0x17C9, hi: 0x17D3), LH (lo: 0x17DD, hi: 0x17DD),
        LH (lo:0x180B, hi: 0x180D), LH (lo: 0x18A9, hi: 0x18A9), LH (lo: 0x1920, hi: 0x1922),
        LH (lo:0x1927, hi: 0x1928), LH (lo: 0x1932, hi: 0x1932), LH (lo: 0x1939, hi: 0x193B),
        LH (lo:0x1A17, hi: 0x1A18), LH (lo: 0x1B00, hi: 0x1B03), LH (lo: 0x1B34, hi: 0x1B34),
        LH (lo:0x1B36, hi: 0x1B3A), LH (lo: 0x1B3C, hi: 0x1B3C), LH (lo: 0x1B42, hi: 0x1B42),
        LH (lo:0x1B6B, hi: 0x1B73), LH (lo: 0x1DC0, hi: 0x1DCA), LH (lo: 0x1DFE, hi: 0x1DFF),
        LH (lo:0x200B, hi: 0x200F), LH (lo: 0x202A, hi: 0x202E), LH (lo: 0x2060, hi: 0x2063),
        LH (lo:0x206A, hi: 0x206F), LH (lo: 0x20D0, hi: 0x20EF), LH (lo: 0x302A, hi: 0x302F),
        LH (lo:0x3099, hi: 0x309A), LH (lo: 0xA806, hi: 0xA806), LH (lo: 0xA80B, hi: 0xA80B),
        LH (lo:0xA825, hi: 0xA826), LH (lo: 0xFB1E, hi: 0xFB1E), LH (lo: 0xFE00, hi: 0xFE0F),
        LH (lo:0xFE20, hi: 0xFE23), LH (lo: 0xFEFF, hi: 0xFEFF), LH (lo: 0xFFF9, hi: 0xFFFB),
        LH (lo:0x10A01, hi: 0x10A03), LH (lo: 0x10A05, hi: 0x10A06), LH (lo: 0x10A0C, hi: 0x10A0F),
        LH (lo:0x10A38, hi: 0x10A3A), LH (lo: 0x10A3F, hi: 0x10A3F), LH (lo: 0x1D167, hi: 0x1D169),
        LH (lo:0x1D173, hi: 0x1D182), LH (lo: 0x1D185, hi: 0x1D18B), LH (lo: 0x1D1AA, hi: 0x1D1AD),
        LH (lo:0x1D242, hi: 0x1D244), LH (lo: 0xE0001, hi: 0xE0001), LH (lo: 0xE0020, hi: 0xE007F),
        LH (lo:0xE0100, hi: 0xE01EF)
    ]
    
    // This is the list of emoji that uses two columns - notice that this is not a
    // list of all emoji, it explicitly excludes those that fit in a single column.
    //
    // That said, this is probably the wrong approach, as it might be possible that
    // the various emoji could have different sizes depending on the font - so I
    // should probably compute whether the character overflows given the current font
    // this would adjust correctly over time and be more resilient.
    static let twoColumnEmoji: [LH] = [
        // ⌚, ⌛
        LH (lo: 0x231a, hi: 0x231b),
        // assorted playback
        LH (lo: 0x23e9, hi: 0x23f0),
        // ⏳
        LH (lo: 0x23f3, hi: 0x23f3),
        // Ⓜ
        LH (lo: 0x24c2, hi: 0x24c2),
        // ◽, ◾
        LH (lo: 0x25fd, hi: 0x25fe),
        // ☔, ☕
        LH (lo: 0x2614, hi: 0x2615),
        // zodiac signs
        LH (lo: 0x2648, hi: 0x2653),
        // ♿
        LH (lo: 0x267f, hi: 0x267f),
        // ⚓
        LH (lo: 0x2693, hi: 0x2693),
        // ⚡
        LH (lo: 0x26a1, hi: 0x26a1),
        // ⚧
        LH (lo: 0x26a7, hi: 0x26a7),
        // ⚪, ⚫
        LH (lo: 0x26aa, hi: 0x26ab),
        // balls
        LH (lo: 0x26bd, hi: 0x26be),
        // snowman, clouds
        LH (lo: 0x26c4, hi: 0x26c5),
        // another zodiac looking sign
        LH (lo: 0x26ce, hi: 0x26ce),
        // ⛔
        LH (lo: 0x26d4, hi: 0x26d4),
        // ⛪
        LH (lo: 0x26ea, hi: 0x26ea),
        //
        LH (lo: 0x26f2, hi: 0x26f5),
        // ⛺
        LH (lo: 0x26fa, hi: 0x26fa),
        // ⛽
        LH (lo: 0x26fd, hi: 0x26fd),
        // ✅
        LH (lo: 0x2705, hi: 0x2705),
        // ✊, ✋
        LH (lo: 0x270a, hi: 0x270b),
        // ✨
        LH (lo: 0x2728, hi: 0x2728),
        // ❌
        LH (lo: 0x274c, hi: 0x274c),
        // ❎
        LH (lo: 0x274e, hi: 0x274e),
        //
        LH (lo: 0x2753, hi: 0x2755),
        // 
        LH (lo: 0x2757, hi: 0x2757),
        LH (lo: 0x2795, hi: 0x2797),
        LH (lo: 0x27b0, hi: 0x27b0),
        LH (lo: 0x27bf, hi: 0x27bf),
        LH (lo: 0x2b05, hi: 0x2b07),
        LH (lo: 0x2b1b, hi: 0x2b1c),
        LH (lo: 0x2b50, hi: 0x2b50),
        LH (lo: 0x2b55, hi: 0x2b55),
        LH (lo: 0x3030, hi: 0x3030),
        LH (lo: 0x303d, hi: 0x303d),
        LH (lo: 0x3297, hi: 0x3297),
        LH (lo: 0x3299, hi: 0x3299),
        LH (lo: 0x1f004, hi: 0x1f004),
        LH (lo: 0x1f0cf, hi: 0x1f0cf),
        LH (lo: 0x1f170, hi: 0x1f189),
        
        LH (lo: 0x1f18e, hi: 0x1f19a),
        // boxed letters
        LH (lo: 0x1f1e6, hi: 0x1f1ff),
        
        LH (lo: 0x1f201, hi: 0x1f202),
        LH (lo: 0x1f21a, hi: 0x1f21a),
        LH (lo: 0x1f22f, hi: 0x1f22f),
        LH (lo: 0x1f232, hi: 0x1f23a),

        LH (lo: 0x1f250, hi: 0x1f251),

        LH (lo: 0x1f300, hi: 0x1f321),

        LH (lo: 0x1f324, hi: 0x1f393),
        LH (lo: 0x1f396, hi: 0x1f397),
        LH (lo: 0x1f399, hi: 0x1f39b),
        LH (lo: 0x1f39e, hi: 0x1f3f0),
        LH (lo: 0x1f3f3, hi: 0x1f3f5),
        LH (lo: 0x1f3f7, hi: 0x1f4fd),
        LH (lo: 0x1f4ff, hi: 0x1f53d),
        LH (lo: 0x1f549, hi: 0x1f54e),
        LH (lo: 0x1f550, hi: 0x1f567),
        LH (lo: 0x1f56f, hi: 0x1f570),
        LH (lo: 0x1f573, hi: 0x1f57a),
        LH (lo: 0x1f587, hi: 0x1f587),
        LH (lo: 0x1f58a, hi: 0x1f58d),
        LH (lo: 0x1f590, hi: 0x1f590),
        LH (lo: 0x1f595, hi: 0x1f596),
        LH (lo: 0x1f5a4, hi: 0x1f5a5),
        LH (lo: 0x1f5a8, hi: 0x1f5a8),
        LH (lo: 0x1f5b1, hi: 0x1f5b2),
        LH (lo: 0x1f5bc, hi: 0x1f5bc),
        LH (lo: 0x1f5c2, hi: 0x1f5c4),
        LH (lo: 0x1f5d1, hi: 0x1f5d3),
        LH (lo: 0x1f5dc, hi: 0x1f5de),
        LH (lo: 0x1f5e1, hi: 0x1f5e1),
        LH (lo: 0x1f5e3, hi: 0x1f5e3),
        LH (lo: 0x1f5e8, hi: 0x1f5e8),
        LH (lo: 0x1f5ef, hi: 0x1f5ef),
        LH (lo: 0x1f5f3, hi: 0x1f5f3),
        LH (lo: 0x1f5fa, hi: 0x1f64f),
        LH (lo: 0x1f680, hi: 0x1f6c5),
        LH (lo: 0x1f6cb, hi: 0x1f6d2),
        LH (lo: 0x1f6d5, hi: 0x1f6d7),
        LH (lo: 0x1f6dc, hi: 0x1f6e5),
        LH (lo: 0x1f6e9, hi: 0x1f6e9),
        LH (lo: 0x1f6eb, hi: 0x1f6ec),
        LH (lo: 0x1f6f0, hi: 0x1f6f0),
        LH (lo: 0x1f6f3, hi: 0x1f6fc),
        LH (lo: 0x1f7e0, hi: 0x1f7eb),
        LH (lo: 0x1f7f0, hi: 0x1f7f0),
        LH (lo: 0x1f90c, hi: 0x1f93a),
        LH (lo: 0x1f93c, hi: 0x1f945),
        LH (lo: 0x1f947, hi: 0x1f9ff),
        LH (lo: 0x1fa70, hi: 0x1fa7c),
        LH (lo: 0x1fa80, hi: 0x1fa88),
        LH (lo: 0x1fa90, hi: 0x1fabd),
        LH (lo: 0x1fabf, hi: 0x1fac5),
        LH (lo: 0x1face, hi: 0x1fadb),
        LH (lo: 0x1fae0, hi: 0x1fae8),
        LH (lo: 0x1fabf, hi: 0x1fac5),
        LH (lo: 0x1face, hi: 0x1fadb),
        LH (lo: 0x1fae0, hi: 0x1fae8),
        LH (lo: 0x1faf0, hi: 0x1faf8),


]
    
    static func bisearch (rune: UInt32, table: [LH], max _max: Int) -> Int
    {
        var min = 0
        var mid = 0
        var max = _max

        if rune < table [0].lo || rune > table [max].hi {
            return 0
        }
        while max >= min {
            mid = (min + max) / 2
            if (rune > table [mid].hi) {
                min = mid + 1
            } else if rune < table [mid].lo {
                max = mid - 1
            } else {
                return 1
            }
        }
        return 0
    }

    /**
     * Number of column positions of a wide-character code.   This is used to measure runes as displayed by text-based terminals.
     * - Returns: The width in columns, 0 if the argument is the null character, -1 if the value is not printable, otherwise the number of columsn that the rune occupies.
     * - Parameter rune: a UnicodeScalar
     */
    static func columnWidth (rune: UnicodeScalar) -> Int
    {
        let irune = rune.value

        if irune < 32 {
            return 0
        }
        if irune < 127 {
            return 1
        }
        if irune >= 0x7f && irune <= 0xa0 {
            return 0
        }
        /* binary search in table of non-spacing characters */
        if bisearch (rune: irune, table: combining, max: combining.count-1) != 0 {
            return 0
        }
        
        /* if we arrive here, ucs is not a combining or C0/C1 control character */
        return 1 +
            ((irune >= 0x1100 &&
             (irune <= 0x115f ||                    /* Hangul Jamo init. consonants */
            irune == 0x2329 || irune == 0x232a ||
            (irune >= 0x2e80 && irune <= 0xa4cf &&
            irune != 0x303f) ||                  /* CJK ... Yi */
            (irune >= 0xac00 && irune <= 0xd7a3) || /* Hangul Syllables */
            (irune >= 0xf900 && irune <= 0xfaff) || /* CJK Compatibility Ideographs */
            (irune >= 0xfe10 && irune <= 0xfe19) || /* Vertical forms */
            (irune >= 0xfe30 && irune <= 0xfe6f) || /* CJK Compatibility Forms */
            (irune >= 0xff00 && irune <= 0xff60) || /* Fullwidth Forms */
            (irune >= 0xffe0 && irune <= 0xffe6) ||
            (irune >= 0x20000 && irune <= 0x2fffd) ||
              (irune >= 0x30000 && irune <= 0x3fffd)) ||
              bisearch(rune: irune, table: twoColumnEmoji, max: twoColumnEmoji.count-1) != 0) ? 1 : 0)
    }
}
