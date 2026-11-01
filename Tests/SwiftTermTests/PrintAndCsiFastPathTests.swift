import Testing

@testable import SwiftTerm

/// The parse loop takes a whole CSI sequence in ground state in one pass, and
/// a print run of one plain scalar goes straight into its cell. Fed a byte at
/// a time, neither shortcut applies: every CSI goes through the state table and
/// every scalar through the per-character print path. These tests feed the same
/// streams whole, a byte at a time and in random chunks, and expect the same
/// terminal.
@Suite("Print and CSI fast paths")
struct PrintAndCsiFastPathTests {
    private static let esc = "\u{1b}"

    /// Scalars that take the plain-scalar path and ones that must not: wide,
    /// combining, ZWJ, variation selectors, regional indicators, emoji
    /// modifiers, Prepend, Hangul jamo and Indic conjuncts.
    private static let scalars: [String] = [
        "é", "ÿ", "α", "а", "─", "│", "█", "▀", "▄", "░", "ж", "中", "あ", "가",
        "😀", "🧑", "🖐", "\u{1F3FE}", "\u{301}", "\u{308}", "\u{200D}", "\u{200C}",
        "\u{FE0F}", "\u{FE0E}", "🇦", "🇧", "\u{0600}", "ᄀ", "ᅡ", "ᆨ",
        "क", "\u{94D}", "ष", "\u{93F}", "❤", "\u{2028}", "\u{E0B0}", "\u{F8FF}",
    ]

    /// Sequences that the one-pass CSI path takes, and ones it must leave to
    /// the table: a prefix after parameters, a leading colon, C0 controls,
    /// DEL, too many parameters, an interrupted sequence.
    private static func sequence(_ generator: inout SplitMix) -> String {
        let esc = Self.esc
        switch generator.next() % 34 {
        case 0: return "\(esc)[m"
        case 1: return "\(esc)[\(generator.next() % 108)m"
        case 2: return "\(esc)[38;5;\(generator.next() % 256)m"
        case 3: return "\(esc)[48;2;\(generator.next() % 256);\(generator.next() % 256);\(generator.next() % 256)m"
        case 4: return "\(esc)[38:2::\(generator.next() % 256):\(generator.next() % 256):\(generator.next() % 256)m"
        case 5: return "\(esc)[4:\(generator.next() % 6)m"
        case 6: return "\(esc)[\(1 + generator.next() % 30);\(1 + generator.next() % 90)H"
        case 7: return "\(esc)[\(generator.next() % 4)\(["A", "B", "C", "D", "E", "F", "G", "d", "`"][Int(generator.next() % 9)])"
        case 8: return "\(esc)[\(generator.next() % 3)\(["J", "K"][Int(generator.next() % 2)])"
        case 9: return "\(esc)[?\(generator.next() % 3)\(["J", "K"][Int(generator.next() % 2)])"
        case 10: return "\(esc)[\(generator.next() % 4)\(["@", "P", "X", "L", "M", "S", "T", "b"][Int(generator.next() % 8)])"
        case 11: return "\(esc)[4\(generator.next() & 1 == 0 ? "h" : "l")"
        case 12: return "\(esc)[?7\(generator.next() & 1 == 0 ? "h" : "l")"
        case 13: return "\(esc)[?6\(generator.next() & 1 == 0 ? "h" : "l")"
        case 14: return "\(esc)[?69\(generator.next() & 1 == 0 ? "h" : "l")"
        case 15: return "\(esc)[\(1 + generator.next() % 5);\(5 + generator.next() % 20)s"
        case 16: return "\(esc)[\(1 + generator.next() % 4);\(4 + generator.next() % 10)r"
        case 17: return "\(esc)[\(generator.next() % 3)\"q"
        case 18: return "\(esc)[\(generator.next() % 7) q"
        case 19: return "\(esc)[6n"
        case 20: return "\(esc)[?6n"
        case 21: return "\(esc)[>c"
        case 22: return "\(esc)P$qm\(esc)\\"
        case 23: return "\(esc)P$q\"q\(esc)\\"
        // The table's business from here on.
        case 24: return generator.next() & 1 == 0 ? "\(esc)[1?m" : "\(esc)[6?h"
        case 25: return "\(esc)[:1m"
        case 26: return "\(esc)[?:1m"
        case 27: return "\(esc)[1\n2m"
        case 28: return "\(esc)[3\u{7f}1m"
        case 29: return "\(esc)[" + Array(repeating: "1", count: 20 + Int(generator.next() % 10)).joined(separator: ";") + "m"
        case 30: return "\(esc)[1;2\(esc)[3m"
        case 31: return "\(esc)[1 2m"
        case 32: return "\(esc)[\(Array(repeating: "9", count: 1 + Int(generator.next() % 14)).joined())C"
        default: return "\(esc)[?1049\(generator.next() & 1 == 0 ? "h" : "l")"
        }
    }

    private static func token(_ generator: inout SplitMix) -> [UInt8] {
        let esc = Self.esc
        switch generator.next() % 20 {
        case 0...5:
            return Array(Self.scalars[Int(generator.next() % UInt64(Self.scalars.count))].utf8)
        case 6...10:
            return Array(Self.sequence(&generator).utf8)
        case 11:
            return Array(String(repeating: "x", count: 1 + Int(generator.next() % 12)).utf8)
        case 12:
            return [[0x0d, 0x0a], [0x08], [0x09], [0x0a], [0x0d]][Int(generator.next() % 5)]
        case 13:
            // Malformed UTF-8: lone lead bytes, a truncated sequence, an
            // overlong encoding, a surrogate and bytes that never start one.
            return [[0xc3], [0xe2, 0x82], [0xc0, 0xaf], [0xed, 0xa0, 0x80], [0xff], [0x80], [0xf4, 0x90, 0x80, 0x80]][Int(generator.next() % 7)]
        case 14:
            return Array(["\(esc)7", "\(esc)8", "\(esc)V", "\(esc)W", "\(esc)(0", "\(esc)(B"][Int(generator.next() % 6)].utf8)
        case 15:
            return Array((generator.next() & 1 == 0 ? "\(esc)]8;;https://example.com\u{7}" : "\(esc)]8;;\u{7}").utf8)
        default:
            // A scalar between color changes, as block-element images send.
            let scalar = Self.scalars[Int(generator.next() % 12)]
            return Array("\(esc)[38;5;\(generator.next() % 256)m\(scalar)".utf8)
        }
    }

    @Test(arguments: [(80, 24, 0), (10, 4, 0), (12, 5, 20), (3, 2, 0)])
    func wholeByteAtATimeAndChunkedFeedsAgree(cols: Int, rows: Int, scrollback: Int) {
        var generator = SplitMix(state: UInt64(cols * 1000 + rows * 10 + scrollback))
        let (whole, wholeDelegate) = TerminalTestHarness.makeTerminal(cols: cols, rows: rows, scrollback: scrollback)
        let (single, singleDelegate) = TerminalTestHarness.makeTerminal(cols: cols, rows: rows, scrollback: scrollback)
        let (chunked, chunkedDelegate) = TerminalTestHarness.makeTerminal(cols: cols, rows: rows, scrollback: scrollback)
        for terminal in [whole, single, chunked] {
            terminal.silentLog = true
        }

        for _ in 0..<300 {
            var stream: [UInt8] = []
            for _ in 0..<(1 + Int(generator.next() % 40)) {
                stream += Self.token(&generator)
            }
            whole.feed(byteArray: stream)
            for byte in stream {
                single.feed(byteArray: [byte])
            }
            var offset = 0
            while offset < stream.count {
                let size = 1 + Int(generator.next() % UInt64(stream.count - offset))
                chunked.feed(byteArray: Array(stream[offset..<(offset + size)]))
                offset += size
            }
            // Ask each for its cursor, attributes and protection, so state
            // that has no cell yet is compared too.
            let probe = Array("\(Self.esc)[6n\(Self.esc)P$qm\(Self.esc)\\\(Self.esc)P$q\"q\(Self.esc)\\".utf8)
            for terminal in [whole, single, chunked] {
                terminal.feed(byteArray: probe)
            }

            expectSameState(whole, single, "byte at a time")
            expectSameState(whole, chunked, "random chunks")
            #expect(wholeDelegate.sentData == singleDelegate.sentData)
            #expect(wholeDelegate.sentData == chunkedDelegate.sentData)
        }
    }

    @Test func aPlainScalarAfterAPrependOrJoinerJoinsAsItDoesByteByByte() {
        // Each scalar arrives in a print run of its own, as it does between
        // color changes, so the one after the Prepend or the joiner is a
        // plain-scalar run whose cell is decided by the one before it.
        let text = Array("\u{0600}\(Self.esc)[31mé\(Self.esc)[m😀\(Self.esc)[32m\u{200D}\(Self.esc)[33m🧑".utf8)
        let (whole, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 2)
        let (single, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 2)
        whole.feed(byteArray: text)
        for byte in text {
            single.feed(byteArray: [byte])
        }
        #expect(whole.buffer.lines[0].packedView(at: 0).getScalarValues() == [0x0600, 0xE9])
        expectSameState(whole, single, "byte at a time")
    }

    private func expectSameState(_ lhs: Terminal, _ rhs: Terminal, _ label: Comment) {
        #expect(lhs.buffer.x == rhs.buffer.x, label)
        #expect(lhs.buffer.y == rhs.buffer.y, label)
        #expect(lhs.buffer.yBase == rhs.buffer.yBase, label)
        #expect(lhs.isDisplayBufferAlternate == rhs.isDisplayBufferAlternate, label)
        #expect(lhs.insertMode == rhs.insertMode, label)
        #expect(lhs.wraparound == rhs.wraparound, label)
        #expect(lhs.originMode == rhs.originMode, label)
        #expect(lhs.marginMode == rhs.marginMode, label)
        #expect(lhs.characterProtection == rhs.characterProtection, label)
        #expect(lhs.buffer.lines.count == rhs.buffer.lines.count, label)
        guard lhs.buffer.lines.count == rhs.buffer.lines.count else { return }
        // Payload codes are process-wide identities; compare payload values.
        let valueMask = ~PackedCell.payloadMask
        for row in 0..<lhs.buffer.lines.count {
            let left = lhs.buffer.lines[row]
            let right = rhs.buffer.lines[row]
            #expect(left.isWrapped == right.isWrapped, label)
            for column in 0..<lhs.cols {
                let l = left.packedView(at: column)
                let r = right.packedView(at: column)
                // A cluster's content is its slot in the terminal's own cell
                // arena, which depends on what was stored before; its scalars
                // are compared below.
                let mask = l.packed.contentTag == .grapheme ? valueMask & ~PackedCell.contentMask : valueMask
                guard l.packed.rawValue & mask == r.packed.rawValue & mask,
                      l.getScalarValues() == r.getScalarValues(),
                      String(describing: l.getPayload()) == String(describing: r.getPayload()) else {
                    Issue.record("\(label): cells differ at row \(row), column \(column): \(l.getScalarValues()) vs \(r.getScalarValues())")
                    return
                }
            }
        }
    }
}

private struct SplitMix {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
