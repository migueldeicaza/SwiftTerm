//
//  MirrorSnapshotTests.swift
//
//  Terminal.mirrorSnapshot: bytes that make another terminal of the same size
//  show what this one shows. Each test builds a source, feeds its snapshot to
//  a fresh receiver and to used ones, and compares every cell and every piece
//  of state the snapshot claims to restore. Most then feed both the same
//  further bytes and compare again, which checks the hidden state (saved
//  cursor, modes, character sets) by its effect.
//

import Foundation
import Testing
@testable import SwiftTerm

/// A terminal and the delegate it holds weakly.
final class MirrorTestTerminal {
    let delegate = TerminalTestDelegate()
    let terminal: Terminal

    init(cols: Int, rows: Int, scrollback: Int = 1000) {
        terminal = Terminal(delegate: delegate,
                            options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
    }

    func feed(_ text: String) {
        terminal.feed(text: text)
    }

    func feed(_ bytes: [UInt8]) {
        terminal.feed(byteArray: bytes)
    }
}

/// Compares two terminals on everything a mirror snapshot restores.
enum MirrorComparison {
    /// Each difference, described. Empty when they match.
    ///
    /// - Parameter history: how many scrollback lines above the screen to
    ///   compare, at most. Fewer when either terminal has fewer.
    static func differences(_ source: Terminal, _ receiver: Terminal, history: Int) -> [String] {
        var found: [String] = []
        func check<T: Equatable>(_ name: @autoclosure () -> String, _ a: T, _ b: T) {
            if a != b {
                found.append("\(name()): \(a) / \(b)")
            }
        }
        check("columns", source.cols, receiver.cols)
        check("rows", source.rows, receiver.rows)
        guard source.cols == receiver.cols, source.rows == receiver.rows else { return found }
        let cols = source.cols
        let rows = source.rows

        let alternate = source.isCurrentBufferAlternate
        check("alternate screen", alternate, receiver.isCurrentBufferAlternate)

        let normalHistory = min(history, source.normalBuffer.yBase, receiver.normalBuffer.yBase)
        compareLines(source.normalBuffer, receiver.normalBuffer, history: normalHistory,
                     label: "normal", cols: cols, rows: rows, into: &found)
        // An alternate screen with no rows shows as blank rows when a program
        // comes back to it.
        let sourceAlt = source.altBuffer.lines.count > 0
        let receiverAlt = receiver.altBuffer.lines.count > 0
        if sourceAlt && receiverAlt {
            compareLines(source.altBuffer, receiver.altBuffer, history: 0,
                         label: "alternate", cols: cols, rows: rows, into: &found)
        } else if sourceAlt != receiverAlt {
            let rowsHeld = sourceAlt ? source.altBuffer : receiver.altBuffer
            if !isBlank(rowsHeld, cols: cols) {
                found.append("alternate content: \(sourceAlt) / \(receiverAlt)")
            }
        }
        compareScreenState(source.normalBuffer, receiver.normalBuffer, label: "normal",
                           cols: cols, rows: rows, into: &found)
        compareScreenState(source.altBuffer, receiver.altBuffer, label: "alternate",
                           cols: cols, rows: rows, into: &found)

        check("cursor x", source.buffer.x, receiver.buffer.x)
        check("cursor y", source.buffer.y, receiver.buffer.y)

        check("cursor hidden", source.cursorHidden, receiver.cursorHidden)
        check("cursor style", source.options.cursorStyle, receiver.options.cursorStyle)
        check("cursor blink", source.cursorBlink, receiver.cursorBlink)
        check("origin mode", source.originMode, receiver.originMode)
        check("margin mode", source.marginMode, receiver.marginMode)
        check("insert mode", source.insertMode, receiver.insertMode)
        check("wraparound", source.wraparound, receiver.wraparound)
        check("reverse wraparound", source.reverseWraparound, receiver.reverseWraparound)
        check("application cursor", source.applicationCursor, receiver.applicationCursor)
        check("application keypad", source.applicationKeypad, receiver.applicationKeypad)
        check("reverse video", source.reverseColors, receiver.reverseColors)
        check("smooth scroll", source.smoothScroll, receiver.smoothScroll)
        check("80/132", source.allow80To132, receiver.allow80To132)
        check("line feed mode", source.lineFeedMode, receiver.lineFeedMode)
        check("bracketed paste", source.bracketedPasteMode, receiver.bracketedPasteMode)
        check("alternate scroll", source.alternateScrollMode, receiver.alternateScrollMode)
        check("colour scheme reports", source.colorSchemeUpdatesEnabled, receiver.colorSchemeUpdatesEnabled)
        check("visibility reports", source.visibilityReportsEnabled, receiver.visibilityReportsEnabled)
        check("size reports", source.inBandSizeReportsEnabled, receiver.inBandSizeReportsEnabled)
        check("focus reports", source.sendFocus, receiver.sendFocus)
        check("mouse mode", source.mouseMode, receiver.mouseMode)
        check("mouse encoding", "\(source.mirrorMouseProtocol)", "\(receiver.mirrorMouseProtocol)")
        check("shift capture", source.mouseShiftCapture, receiver.mouseShiftCapture)
        for alternate in [false, true] {
            let a = source.mirrorKeyboardMode(alternate: alternate)
            let b = receiver.mirrorKeyboardMode(alternate: alternate)
            check("keyboard flags (alternate \(alternate))", a.flags.rawValue, b.flags.rawValue)
            check("keyboard stack (alternate \(alternate))", a.stack.map(\.rawValue), b.stack.map(\.rawValue))
        }
        check("synchronized output", false, receiver.synchronizedOutputActive)
        check("attribute", source.currentAttribute, receiver.currentAttribute)
        check("link", source.mirrorActiveHyperlink, receiver.mirrorActiveHyperlink)
        check("title", source.terminalTitle, receiver.terminalTitle)
        check("icon title", source.iconTitle, receiver.iconTitle)
        check("palette", source.ansiColors, receiver.ansiColors)
        check("character sets", source.mirrorCharsets.designated, receiver.mirrorCharsets.designated)
        check("active character set", source.mirrorCharsets.active, receiver.mirrorCharsets.active)
        check("invoked set", source.gLevel, receiver.gLevel)
        check("bidi", source.currentBidiState, receiver.currentBidiState)
        check("bidi arrows", source.bidiArrowKeySwap, receiver.bidiArrowKeySwap)
        check("saved private modes", source.mirrorSavedPrivateModes, receiver.mirrorSavedPrivateModes)
        return found
    }

    private static func compareLines(_ a: Buffer, _ b: Buffer, history: Int, label: String,
                                     cols: Int, rows: Int, into found: inout [String]) {
        let aStart = a.yBase - history
        let bStart = b.yBase - history
        for k in 0..<(history + rows) {
            let aIndex = aStart + k
            let bIndex = bStart + k
            guard aIndex >= 0, aIndex < a.lines.count, bIndex >= 0, bIndex < b.lines.count else {
                found.append("\(label) line \(k - history): missing")
                continue
            }
            let x = a.lines[aIndex]
            let y = b.lines[bIndex]
            let name = "\(label) line \(k - history)"
            // The oldest line a receiver holds has nothing above it to wrap from.
            if bIndex > 0 && x.isWrapped != y.isWrapped {
                found.append("\(name) wrapped: \(x.isWrapped) / \(y.isWrapped)")
            }
            if x.renderMode != y.renderMode {
                found.append("\(name) render mode: \(x.renderMode) / \(y.renderMode)")
            }
            if x.bidiState != y.bidiState {
                found.append("\(name) bidi: \(x.bidiState) / \(y.bidiState)")
            }
            var cellDifferences = 0
            for col in 0..<cols where cellDifferences < 3 {
                let p = x[col]
                let q = y[col]
                let pText = p.code == 0 ? "∅" : p.getText()
                let qText = q.code == 0 ? "∅" : q.getText()
                var what: [String] = []
                if pText != qText { what.append("text \(pText.debugDescription) / \(qText.debugDescription)") }
                if p.width != q.width { what.append("width \(p.width) / \(q.width)") }
                if p.attribute != q.attribute { what.append("attribute \(p.attribute) / \(q.attribute)") }
                // A blank cell's link doesn't come back.
                let pLink = p.getPayload() as? String
                let qLink = q.getPayload() as? String
                let bothBlank = p.code == 0 && q.code == 0 && p.width == 1 && q.width == 1
                if pLink != qLink && !bothBlank { what.append("link \(pLink ?? "-") / \(qLink ?? "-")") }
                if !what.isEmpty {
                    found.append("\(name) col \(col): " + what.joined(separator: ", "))
                    cellDifferences += 1
                }
            }
        }
    }

    private static func isBlank(_ buffer: Buffer, cols: Int) -> Bool {
        for index in 0..<buffer.lines.count {
            let line = buffer.lines[index]
            if line.isWrapped || line.renderMode != .single {
                return false
            }
            for col in 0..<min(cols, line.count) {
                let cell = line[col]
                if cell.code != 0 || cell.attribute != CharData.defaultAttr {
                    return false
                }
            }
        }
        return true
    }

    private static func compareScreenState(_ a: Buffer, _ b: Buffer, label: String,
                                           cols: Int, rows: Int, into found: inout [String]) {
        func check<T: Equatable>(_ name: String, _ x: T, _ y: T) {
            if x != y {
                found.append("\(label) \(name): \(x) / \(y)")
            }
        }
        check("scroll top", a.scrollTop, b.scrollTop)
        check("scroll bottom", a.scrollBottom, b.scrollBottom)
        check("left margin", a.marginLeft, b.marginLeft)
        check("right margin", a.marginRight, b.marginRight)
        check("tab stops", Array(a.tabStops.prefix(cols)), Array(b.tabStops.prefix(cols)))
        // DECRC clamps, so a saved column past the edge restores the same.
        check("saved x", min(max(a.savedX, 0), cols - 1), min(max(b.savedX, 0), cols - 1))
        check("saved y", min(max(a.savedY, 0), rows - 1), min(max(b.savedY, 0), rows - 1))
        check("saved attribute", a.savedAttr, b.savedAttr)
        check("saved character set", a.savedCharset, b.savedCharset)
        check("saved origin mode", a.savedOriginMode, b.savedOriginMode)
        check("saved margin mode", a.savedMarginMode, b.savedMarginMode)
        check("saved wraparound", a.savedWraparound, b.savedWraparound)
        check("saved reverse wraparound", a.savedReverseWraparound, b.savedReverseWraparound)
    }
}

/// Receivers in different prior states, each named.
enum MirrorReceivers {
    /// What a used terminal can be left holding: content on both screens,
    /// colours, modes, regions, titles, keyboard flags, and a sequence or a
    /// character cut off half way.
    static let dirtyStates: [(name: String, bytes: String)] = [
        ("fresh", ""),
        ("used", used),
        ("used, mid CSI", used + "\u{1b}[38;5;"),
        ("used, mid OSC", used + "\u{1b}]8;;http://example.com/cut"),
        ("used, mid UTF-8", used + "\u{e2}"),
        ("used, mid DCS", used + "\u{1b}P1$r"),
        ("used, on the alternate screen", used + "\u{1b}[?47h\u{1b}[44mALT\u{1b}[3;5r\u{1b}[>3u"),
    ]

    private static let used =
        "\u{1b}[?1049h\u{1b}[41mDIRTY ALT\u{1b}[5;10r\u{1b}[?69h\u{1b}[3;9s\u{1b}[?69l\u{1b}[3g\u{1b}H"
        + "\u{1b}[2;3H\u{1b}7\u{1b}[>1u\u{1b}[?1049l"
        + "\u{1b}[42mdirty normal\r\n" + String(repeating: "x", count: 50) + "\r\n"
        + "\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?2004h\u{1b}[?25l\u{1b}[?1h\u{1b}=\u{1b}[>5u"
        + "\u{1b}]0;dirty\u{07}\u{1b}]1;dirty icon\u{07}\u{1b}]4;1;rgb:ff/00/00\u{07}\u{1b}(0\u{1b})0\u{0e}"
        + "\u{1b}[4h\u{1b}[?6h\u{1b}[?7l\u{1b}[3 q\u{1b}[?1004h\u{1b}[?45h\u{1b}[?4h\u{1b}[20h"
        + "\u{1b}[?12h\u{1b}[?5h\u{1b}[?40h\u{1b}[>1s\u{1b}[?2031h\u{1b}[?1007l\u{1b}[8l\u{1b}[?2501l"
        + "\u{1b}[?2004s\u{1b}]8;;http://dirty\u{1b}\\"
}

/// Builds a source from `setup`, feeds its snapshot to receivers in every
/// state in ``MirrorReceivers/dirtyStates``, and checks each matches; then
/// feeds source and receivers each of `then` and checks again.
func expectMirrors(_ setup: String, cols: Int = 20, rows: Int = 6, scrollback: Int = 100,
                   then more: [String] = [], sourceLocation: SourceLocation = #_sourceLocation) {
    let source = MirrorTestTerminal(cols: cols, rows: rows)
    source.feed(setup)
    expectMirrors(source, scrollback: scrollback, then: more, sourceLocation: sourceLocation)
}

func expectMirrors(_ source: MirrorTestTerminal, scrollback: Int = 100, then more: [String] = [],
                   sourceLocation: SourceLocation = #_sourceLocation) {
    let terminal = source.terminal
    #expect(terminal.mirrorParserIsGround, "the setup ends mid-sequence", sourceLocation: sourceLocation)
    let snapshot = terminal.mirrorSnapshot(scrollback: scrollback)
    var later: [MirrorTestTerminal] = []
    for (name, bytes) in MirrorReceivers.dirtyStates {
        let receiver = MirrorTestTerminal(cols: terminal.cols, rows: terminal.rows)
        receiver.feed(bytes)
        receiver.feed(snapshot)
        let history = min(scrollback, terminal.normalBuffer.yBase)
        let differences = MirrorComparison.differences(terminal, receiver.terminal, history: history)
        #expect(differences.isEmpty, "receiver \(name): \(differences.prefix(8))", sourceLocation: sourceLocation)
        #expect(receiver.terminal.normalBuffer.yBase == history,
                "receiver \(name) holds \(receiver.terminal.normalBuffer.yBase) lines of history, not \(history)",
                sourceLocation: sourceLocation)
        later.append(receiver)
    }
    // A second snapshot of an unchanged source is the same bytes.
    #expect(terminal.mirrorSnapshot(scrollback: scrollback) == snapshot, sourceLocation: sourceLocation)
    for (step, bytes) in more.enumerated() {
        source.feed(bytes)
        for (index, receiver) in later.enumerated() {
            receiver.feed(bytes)
            let history = min(scrollback, terminal.normalBuffer.yBase)
            let differences = MirrorComparison.differences(terminal, receiver.terminal, history: history)
            #expect(differences.isEmpty,
                    "after step \(step), receiver \(MirrorReceivers.dirtyStates[index].name): \(differences.prefix(8))",
                    sourceLocation: sourceLocation)
        }
    }
}

@Suite struct MirrorSnapshotTests {
    // MARK: Text and attributes

    @Test func plainText() {
        expectMirrors("hello\r\nworld", then: ["!\r\nmore"])
    }

    @Test func emptyTerminal() {
        expectMirrors("", then: ["first"])
    }

    @Test func coloursOfEveryKind() {
        var setup = ""
        for code in 0..<8 {
            setup += "\u{1b}[\(30 + code);\(47 - code)mF\u{1b}[\(90 + code);\(107 - code)mB"
        }
        setup += "\r\n\u{1b}[38;5;17;48;5;230m256\u{1b}[38;5;9;48;5;0mlow"
        setup += "\u{1b}[38;2;1;2;3;48;2;250;128;0mRGB\u{1b}[39mdefault-fg\u{1b}[49mdefault-bg"
        setup += "\r\n\u{1b}[38:2::10:20:30mcolon\u{1b}[0m plain"
        expectMirrors(setup, cols: 40, then: ["after", "\u{1b}[mreset"])
    }

    @Test func stylesAndUnderlines() {
        var setup = "\u{1b}[1mB\u{1b}[2mD\u{1b}[22;3mI\u{1b}[5mK\u{1b}[7mR\u{1b}[8mH\u{1b}[9mX\u{1b}[0m"
        setup += "\u{1b}[1;2mBD\u{1b}[22mn\u{1b}[1;3;7;9mmix\u{1b}[23;27;29mbold\u{1b}[m\r\n"
        for style in 1...5 {
            setup += "\u{1b}[4:\(style)mU\(style)\u{1b}[58;5;\(style + 1)mc\u{1b}[58;2;9;8;7mt\u{1b}[59mn"
        }
        setup += "\u{1b}[21mdouble\u{1b}[24mnone\u{1b}[4mone\u{1b}[m"
        expectMirrors(setup, cols: 50, then: ["\u{1b}[1mtail", "plain"])
    }

    @Test func widthsEmojiAndCombiningMarks() {
        let setup = "漢字かな\r\n🇺🇸🇬🇧 👩‍👩‍👦‍👦 🖐🏾 ❤️ ☺︎\r\ne\u{301}a\u{308}\u{323} 한국어 \u{1100}\u{1161}\u{11A8}\r\n"
            + "\u{915}\u{94d}\u{937} का Z\u{30A}\u{1b}[31m漢\u{1b}[m字"
        expectMirrors(setup, cols: 24, then: ["\u{301}", "👍🏽字", "\r\nend"])
    }

    @Test func hyperlinks() {
        let setup = "\u{1b}]8;;http://a.example\u{1b}\\link\u{1b}]8;;\u{1b}\\ plain "
            + "\u{1b}]8;id=7;http://b.example/x?y=1\u{1b}\\\u{1b}[1mbold link\u{1b}[m\u{1b}]8;;\u{1b}\\"
            + "\r\n\u{1b}]8;;http://c.example\u{1b}\\漢字 still open"
        expectMirrors(setup, cols: 30, then: [" more", "\u{1b}]8;;\u{1b}\\ closed"])
    }

    @Test func erasedCellsKeepTheirBackground() {
        let setup = "\u{1b}[44m\u{1b}[2J\u{1b}[H\u{1b}[mtext\u{1b}[41m\u{1b}[K\r\n\u{1b}[42m  \u{1b}[5X"
            + "\u{1b}[m\r\nabc\u{1b}[48;5;200m\u{1b}[3X\u{1b}[10Gxyz\u{1b}[48;2;1;2;3m\u{1b}[K\u{1b}[m"
            + "\u{1b}[5;1H\u{1b}[45m\u{1b}[J\u{1b}[m"
        expectMirrors(setup, then: ["\u{1b}[6;1Hfill", "\r\n\r\nscrolled"])
    }

    @Test func nullCellsStayNull() {
        // Cursor moves leave cells nobody wrote between the ones written.
        let setup = "a\u{1b}[5Gb\u{1b}[2;10Hc\u{1b}[3;20Hd\u{1b}[4;3H\u{1b}[1me\u{1b}[m"
        expectMirrors(setup, then: ["\u{1b}[1;3Hz"])
    }

    @Test func doubleWidthLines() {
        let setup = "\u{1b}#6wide\r\n\u{1b}#3top\r\n\u{1b}#4bottom\r\nnormal"
        expectMirrors(setup, then: ["\u{1b}#5"])
    }

    // MARK: Wrapping

    @Test func textExactlyToTheLastColumn() {
        // The cursor ends past the last column: the next character wraps.
        expectMirrors("12345678901234567890", then: ["x", "y"])
        expectMirrors("first\r\n" + String(repeating: "\u{1b}[44m=", count: 20), then: ["\u{1b}[mwrap"])
        expectMirrors("漢字漢字漢字漢字漢字", then: ["字"])
        expectMirrors("1234567890123456789漢", then: ["!"])
    }

    @Test func longWrappedLines() {
        let long = (0..<70).map { String(UnicodeScalar(UInt8(65 + $0 % 26))) }.joined()
        expectMirrors(long + "\r\nshort\r\n" + long + long, then: ["\r\n" + long])
    }

    @Test func wideCharacterThatWrapsEarly() {
        // A wide character that doesn't fit leaves the last column empty and
        // wraps; the row after is a continuation.
        expectMirrors("1234567890123456789字after", then: ["more"])
    }

    @Test func wrappedLineWhoseStartWasErased() {
        let long = String(repeating: "w", count: 30)
        expectMirrors(long + "\u{1b}[1G\u{1b}[44m\u{1b}[3X\u{1b}[m\r\n" + long + "\u{1b}[2;1H\u{1b}[1K",
                      then: ["\u{1b}[1;20H\u{1b}[K"])
    }

    @Test func wrappedLineWhoseEndWasErased() {
        let long = String(repeating: "e", count: 30)
        expectMirrors(long + "\u{1b}[1;18H\u{1b}[K" + "\r\n\r\n" + long + "\u{1b}[3;20H\u{1b}[45m\u{1b}[X\u{1b}[m",
                      then: ["\u{1b}[5;1Hnext"])
    }

    @Test func wrappedLinesScrollingIntoHistory() {
        var setup = ""
        for line in 0..<30 {
            setup += String(repeating: String(line % 10), count: line % 3 == 0 ? 45 : 7) + "\r\n"
        }
        expectMirrors(setup, then: [String(repeating: "z", count: 25)])
    }

    // MARK: Graphemes held apart

    @Test func cellsThatWouldJoinIfPrintedInOrder() {
        // Each pair is written right to left, so the source holds the two
        // halves apart. Printed left to right they would join.
        let setup = "\u{1b}[1;3H🇸\u{1b}[1;1H🇺"              // two regional indicators, not a flag
            + "\u{1b}[2;2H\u{93e}\u{1b}[2;1H\u{915}"           // a spacing mark after a consonant
            + "\u{1b}[3;3H🏾\u{1b}[3;1H🖐"                      // a skin tone after a hand
            + "\u{1b}[4;2H\u{1161}\u{1b}[4;1H\u{1100}"          // Hangul jamo
            + "\u{1b}[5;5H🇸\u{1b}[5;3H🇺\u{1b}[5;1H🇬"          // three in a chain
        expectMirrors(setup, then: ["\u{1b}[6;1Hend"])
    }

    @Test func cellsThatWouldJoinAcrossAWrap() {
        // A regional indicator ends a wrapped line and another starts the next.
        let setup = String(repeating: "a", count: 18) + "🇺" + "🇸" + "\u{1b}[1;19H🇺"
        let source = MirrorTestTerminal(cols: 20, rows: 6)
        source.feed(String(repeating: "a", count: 18) + "  🇸")
        source.feed("\u{1b}[1;19H🇺")
        expectMirrors(source, then: ["x"])
        expectMirrors(setup, then: ["y"])
    }

    @Test func narrowClustersThatPrintingWouldWiden() {
        // A skin tone widens the hand it joins, unless the hand sits at the
        // right margin with autowrap off.
        expectMirrors("\u{1b}[?7l" + String(repeating: "x", count: 19) + "🖐🏾\u{1b}[?7h", then: ["!"])
        expectMirrors("\u{1b}[?69h\u{1b}[1;5s\u{1b}[?7l\u{1b}[1;5H🖐🏾\u{1b}[?7h\u{1b}[?69lafter", then: ["!"])
        expectMirrors(String(repeating: "w", count: 20) + "🖐\u{1b}[?69h\u{1b}[1;1s\u{1b}[?7l\u{1b}[2;2H🏾"
                      + "\u{1b}[?7h\u{1b}[?69l\u{1b}[2;3Hrest", then: ["!"])
    }

    @Test func controlsAndZeroWidthCellsPlacedByFill() {
        // DECFRA can place a control character or a lone combining mark in a
        // cell, which printing can't.
        let setup = "ab\u{1b}[1;1;1;1;1$x\u{1b}[768;2;2;2;3$x\u{1b}[127;3;1;3;1$x\u{1b}[8205;4;19;4;20$x"
        expectMirrors(setup, then: ["\u{1b}[5;1Hz"])
        // Marks printed onto a lone mark that DECFRA placed join it.
        expectMirrors("\u{1b}[768;1;1;1;20$x\u{1b}[1;2H\u{301}\u{1b}[1;20H\u{93e}", then: ["\u{1b}[2;1Hz"])
    }

    @Test func halvesOfWideCharactersOnTheirOwn() {
        // REP copies the cell before the cursor as it is: after a wide
        // character that is its second half.
        expectMirrors("x\u{1b}[1;9H🇺🇸\u{1b}[3b", cols: 13, then: ["\u{1b}[2;1Hy"])
        expectMirrors("字\u{1b}[5b tail", then: ["!"])
        expectMirrors("\u{1b}[1;15H字\u{1b}[4b", then: ["!"])
        // DECFRA writes cells without mending a wide character it cuts.
        expectMirrors("漢字漢字\u{1b}[1;2;1;2;1$x\u{1b}[88;1;5;1;5$x", then: ["\u{1b}[2;1Hz"])
        expectMirrors("ab漢\u{1b}[44m\u{1b}[0;1;4;1;4$x\u{1b}[m", then: ["!"])
    }

    @Test func pendingWrapOnABlankOrFramedLastCell() {
        // Erasing the whole line leaves the cursor past the last column.
        let full = String(repeating: "q", count: 20)
        expectMirrors(full + "\u{1b}[2K", then: ["!"])
        expectMirrors(full + "\u{1b}[44m\u{1b}[2K\u{1b}[m", then: ["!"])
        expectMirrors(full + "\u{1b}[1;1;20;1;20$x", then: ["!"])
        expectMirrors("\r\n" + full + "\u{1b}[2;1H\u{1b}[K\u{1b}[2;20H\u{1b}[1Kab\u{1b}[2;19H字", then: ["!"])
    }

    // MARK: Screens and regions

    @Test func scrollRegions() {
        var setup = "top\r\n\u{1b}[2;5r\u{1b}[5;1H"
        for line in 0..<8 {
            setup += "\u{1b}[3\(line % 8)mregion \(line)\r\n"
        }
        expectMirrors(setup, then: ["\u{1b}[5;1Hlast\r\n\r\nscroll", "\u{1b}[r\u{1b}[6;1H\r\nall"])
    }

    @Test func originModeAndMargins() {
        let setup = "\u{1b}[2;5r\u{1b}[?6h\u{1b}[2;3Hin\u{1b}[?69h\u{1b}[3;12s\u{1b}[1;1Hmargins"
        expectMirrors(setup, then: ["\u{1b}[1;1Hhome", "longer text that wraps in the margins", "\u{1b}[?6l\u{1b}[?69l"])
    }

    @Test func alternateScreenActive() {
        var setup = "shell prompt $ vim\r\n"
        for line in 0..<10 {
            setup += "history \(line)\r\n"
        }
        setup += "\u{1b}[1;1H\u{1b}[44m\u{1b}[?1049h\u{1b}[m\u{1b}[H\u{1b}[2J"
        setup += "\u{1b}[1;1H\u{1b}[7m file.txt \u{1b}[m\u{1b}[2;1H~\u{1b}[3;1H~\u{1b}[34m~\u{1b}[m"
        setup += "\u{1b}[6;1H\u{1b}[1m-- INSERT --\u{1b}[m\u{1b}[2;5r\u{1b}[?1h\u{1b}=\u{1b}[>1u\u{1b}[2;4H"
        expectMirrors(setup, then: ["typed", "\u{1b}[r\u{1b}[?1049l", "back at the shell\r\n"])
    }

    @Test func alternateScreenLeft() {
        let setup = "before\r\n\u{1b}[?1049h\u{1b}[2Jfull screen\u{1b}[?1049lafter"
        expectMirrors(setup, then: ["\u{1b}[?1049hagain", "\u{1b}[?1049l"])
    }

    @Test func alternateScreenLeftWith47KeepsItsContent() {
        let setup = "normal\u{1b}[?47h\u{1b}[2Jkept\u{1b}[?47l"
        expectMirrors(setup, then: ["\u{1b}[?47h", "!"])
    }

    @Test func alternateScreenAfterResize() {
        // The normal screen keeps its old size while the alternate one shows.
        let source = MirrorTestTerminal(cols: 20, rows: 6)
        source.feed("one\r\n" + String(repeating: "long ", count: 9) + "\r\nthree\u{1b}[?1049hvim")
        source.terminal.resize(cols: 14, rows: 5)
        source.feed("\u{1b}[Hresized")
        expectMirrors(source, then: ["\u{1b}[?1049l", "\r\nshell"])
    }

    @Test func savedCursorOnEachScreen() {
        let setup = "\u{1b}[3;7H\u{1b}[1;31m\u{1b}(0\u{1b}[?7l\u{1b}7\u{1b}(B\u{1b}[?7h\u{1b}[m\u{1b}[H"
            + "\u{1b}[?1049h\u{1b}[4;2H\u{1b}[42m\u{1b}7\u{1b}[m\u{1b}[H"
        expectMirrors(setup, then: ["\u{1b}8saved", "\u{1b}[?1049l\u{1b}8normal qqq"])
    }

    @Test func tabStops() {
        let setup = "\u{1b}[3g\u{1b}[4G\u{1b}H\u{1b}[11G\u{1b}H\u{1b}[1G\ta\tb\tc"
        expectMirrors(setup, then: ["\r\n\tx\ty", "\u{1b}[?1049h\tz"])
    }

    @Test func scrollbackLimitedToN() {
        let source = MirrorTestTerminal(cols: 20, rows: 6)
        for line in 0..<60 {
            source.feed("line \(line)\r\n")
        }
        expectMirrors(source, scrollback: 10, then: ["more\r\n"])
        expectMirrors(source, scrollback: 0, then: ["more\r\n"])
    }

    // MARK: Modes

    @Test func cursorHidden() {
        expectMirrors("\u{1b}[?25lhidden", then: ["\u{1b}[?25h"])
    }

    @Test func cursorStyleAndBlink() {
        expectMirrors("\u{1b}[5 q\u{1b}[?12h")
    }

    @Test func applicationCursorAndKeypad() {
        expectMirrors("\u{1b}[?1h\u{1b}=")
    }

    @Test func bracketedPaste() {
        expectMirrors("\u{1b}[?2004h")
    }

    @Test func kittyKeyboardFlags() {
        expectMirrors("\u{1b}[>1u\u{1b}[>5u\u{1b}[=9;2u\u{1b}[?1049h\u{1b}[>3u\u{1b}[>8u",
                      then: ["\u{1b}[<u", "\u{1b}[?1049l\u{1b}[<u"])
        expectMirrors("\u{1b}[?1049h\u{1b}[>4u\u{1b}[?1049l\u{1b}[=2;1u")
    }

    @Test func mouseModes() {
        expectMirrors("\u{1b}[?1002h\u{1b}[?1006h")
        expectMirrors("\u{1b}[?1003h\u{1b}[?1015h\u{1b}[>1s")
        expectMirrors("\u{1b}[?9h\u{1b}[?1005h")
        expectMirrors("\u{1b}[?1000h\u{1b}[?1016h")
    }

    @Test func otherModes() {
        expectMirrors("\u{1b}[4h\u{1b}[?45h\u{1b}[?7l\u{1b}[?5h\u{1b}[?4h\u{1b}[?40h\u{1b}[20h\u{1b}[?1004h"
                      + "\u{1b}[?1007l\u{1b}[?2031h\u{1b}[?2033h\u{1b}[?2048h",
                      then: ["insert", "\u{1b}[4l\u{1b}[?7h"])
    }

    @Test func savedPrivateModes() {
        expectMirrors("\u{1b}[?2004h\u{1b}[?2026h\u{1b}[?2004;2026s\u{1b}[?2004l\u{1b}[?2026l",
                      then: ["\u{1b}[?2004r"])
    }

    @Test func synchronizedOutputEndsOff() {
        let source = MirrorTestTerminal(cols: 20, rows: 6)
        source.feed("\u{1b}[?2026hframe")
        let receiver = MirrorTestTerminal(cols: 20, rows: 6)
        receiver.feed(source.terminal.mirrorSnapshot(scrollback: 10))
        #expect(!receiver.terminal.synchronizedOutputActive)
        #expect(MirrorComparison.differences(source.terminal, receiver.terminal, history: 10).isEmpty)
    }

    @Test func bidiState() {
        expectMirrors("ltr\r\n\u{1b}[8lexplicit\r\n\u{1b}[?2501l\u{1b}[3 Sno auto\r\n\u{1b}[?2500h\u{1b}[8hback\u{1b}[?1243h",
                      then: ["\r\nnext", "\u{1b}[8l\r\nlater"])
    }

    @Test func titlesPaletteAndCharacterSets() {
        let setup = "\u{1b}]2;window title ✓\u{07}\u{1b}]1;icon\u{1b}\\\u{1b}]4;3;rgb:12/34/56;200;#abcdef\u{07}"
            + "\u{1b})0\u{1b}*A\u{0e}lqk"
        expectMirrors(setup, then: ["qqq", "\u{0f}qqq"])
    }

    @Test func currentAttributeAndLinkCarryOn() {
        expectMirrors("\u{1b}[1;4:3;38;5;100;58;2;1;2;3m\u{1b}]8;;http://x\u{1b}\\open",
                      then: ["still styled", "\u{1b}[m\u{1b}]8;;\u{1b}\\"])
    }

    // MARK: Odd sizes

    @Test func oneRowAndTwoColumns() {
        expectMirrors("one row that wraps a lot", cols: 20, rows: 1, then: ["!"])
        expectMirrors("字字字a字", cols: 2, rows: 3, then: ["b"])
    }

    // MARK: Speed

    @Test func twoThousandLinesOfTwoHundredColumns() {
        let source = MirrorTestTerminal(cols: 200, rows: 50, scrollback: 2000)
        var line = ""
        for col in 0..<199 {
            line += col % 7 == 0 ? "\u{1b}[3\(col % 8);4\((col / 8) % 8)m" : ""
            line += String(UnicodeScalar(UInt8(33 + col % 90)))
        }
        line += "\u{1b}[m\r\n"
        for _ in 0..<2050 {
            source.feed(line)
        }
        let clock = ContinuousClock()
        var snapshot: [UInt8] = []
        let elapsed = clock.measure {
            snapshot = source.terminal.mirrorSnapshot(scrollback: 2000)
        }
        let receiver = MirrorTestTerminal(cols: 200, rows: 50, scrollback: 2000)
        receiver.feed(snapshot)
        #expect(MirrorComparison.differences(source.terminal, receiver.terminal, history: 2000).isEmpty)
        print("mirror snapshot of 2,050 lines × 200 columns: \(elapsed), \(snapshot.count) bytes")
#if !DEBUG
        #expect(elapsed < .milliseconds(50))
#endif
    }
}

/// A terminal session of the kind a pty produces: a shell with colours and
/// links, wrapped and wide text, then a full-screen program on the alternate
/// screen with a scroll region and modes, and back.
enum MirrorRecording {
    static let session: [UInt8] = {
        var text = "\u{1b}]0;~/code\u{07}\u{1b}[1;32muser@mac\u{1b}[m:\u{1b}[34m~/code\u{1b}[m$ ls --color\r\n"
        text += "\u{1b}[0m\u{1b}[01;34mSources\u{1b}[0m  \u{1b}[01;32mrun.sh\u{1b}[0m  README.md  漢字.txt  🎉.png\r\n"
        text += "\u{1b}]8;;file:///Users/me/README.md\u{1b}\\README.md\u{1b}]8;;\u{1b}\\ "
        text += "\u{1b}]8;id=x;https://example.com/a?b=c\u{1b}\\\u{1b}[4:3;58;5;196mcurly link\u{1b}[m\u{1b}]8;;\u{1b}\\\r\n"
        text += "$ echo 'a long line that wraps across the edge of the terminal more than once, and on'\r\n"
        text += "a long line that wraps across the edge of the terminal more than once, and on\r\n"
        text += "e\u{301}t\u{e9} na\u{ef}ve \u{1100}\u{1161}\u{11a8} 👩‍👩‍👧 🇫🇷🇩🇪 🖐🏽 ❤️ \u{915}\u{94d}\u{937}\r\n"
        text += "\u{1b}[48;2;30;30;60m\u{1b}[K bar \u{1b}[38;5;214m\u{1b}[1m!\u{1b}[22m\u{1b}[39;49m\r\n"
        text += "\u{1b}(0lqqqqk\u{1b}(B\r\n\u{1b}(0x\u{1b}(B ok \u{1b}(0x\u{1b}(B\r\n\u{1b}(0mqqqqj\u{1b}(B\r\n"
        text += "col1\tcol2\tcol3\r\n\u{1b}[7mreverse\u{1b}[27m \u{1b}[9mstruck\u{1b}[29m \u{1b}[2mdim\u{1b}[22m\r\n"
        text += "\u{1b}[?2004h$ vim notes.txt\r\n\u{1b}[?2004l"
        // The full-screen program.
        text += "\u{1b}[?1049h\u{1b}[22;0;0t\u{1b}[?1h\u{1b}=\u{1b}[H\u{1b}[2J\u{1b}[?25l\u{1b}[>1u\u{1b}[?1000h\u{1b}[?1006h"
        text += "\u{1b}[1;1H\u{1b}[44;97m notes.txt \u{1b}[K\u{1b}[m"
        for row in 2...7 {
            text += "\u{1b}[\(row);1H\u{1b}[94m~\u{1b}[m"
        }
        text += "\u{1b}[2;7r\u{1b}[2;1Hfirst line of the file\u{1b}[3;1Hsecond, with 漢字\u{1b}[7;1H"
        text += "\n\n\u{1b}[7;1Hscrolled in at the bottom\u{1b}[r\u{1b}[8;1H\u{1b}[1m-- INSERT --\u{1b}[m"
        text += "\u{1b}[3;9H\u{1b}[?25h\u{1b}[4hins\u{1b}[4l\u{1b}7\u{1b}[8;20H\u{1b}[31mE37\u{1b}[m\u{1b}8"
        text += "\u{1b}[?2026h\u{1b}[5;3H\u{1b}[42m  \u{1b}[3X\u{1b}[m\u{1b}[?2026l"
        text += "\u{1b}[?1000l\u{1b}[?1006l\u{1b}[<u\u{1b}[?1l\u{1b}>\u{1b}[?1049l\u{1b}[23;0;0t"
        // Back at the shell.
        text += "$ printf '%s' \"$(seq 1 30)\" | tr '\\n' ' '\r\n"
        for number in 1...30 {
            text += "\(number) "
        }
        text += "\r\n\u{1b}[?25l\u{1b}[s\u{1b}[1;1H\u{1b}[46m clock 12:00 \u{1b}[m\u{1b}[u\u{1b}[?25h"
        text += "\u{1b}]2;done ✓\u{1b}\\\u{1b}[38;2;255;100;0m$ \u{1b}[m"
        return Array(text.utf8)
    }()
}

/// Mirrors a terminal the way the view's tap does, from any point in a
/// stream: the snapshot waits for the end of the first batch that leaves the
/// parser with nothing partial, and the receiver gets every batch after it.
enum MirrorStream {
    struct Outcome {
        var differences: [String]
        var started: Bool
    }

    static func run(_ bytes: [UInt8], split: Int, chunks: [Int], cols: Int = 30, rows: Int = 8,
                    scrollback: Int = 40) -> Outcome {
        let source = MirrorTestTerminal(cols: cols, rows: rows, scrollback: 400)
        let receiver = MirrorTestTerminal(cols: cols, rows: rows, scrollback: 400)
        source.feed(Array(bytes[0..<split]))
        var started = false
        func startIfGround() {
            if source.terminal.mirrorParserIsGround {
                receiver.feed(source.terminal.mirrorSnapshot(scrollback: scrollback))
                started = true
            }
        }
        startIfGround()
        var index = split
        var chunk = 0
        while index < bytes.count {
            let end = min(bytes.count, index + chunks[chunk % chunks.count])
            chunk += 1
            let batch = Array(bytes[index..<end])
            source.feed(batch)
            if started {
                receiver.feed(batch)
            } else {
                startIfGround()
            }
            index = end
        }
        let history = min(scrollback, source.terminal.normalBuffer.yBase)
        return Outcome(differences: MirrorComparison.differences(source.terminal, receiver.terminal,
                                                                 history: history),
                       started: started)
    }
}

@Suite struct MirrorSnapshotStreamTests {
    /// Every byte offset of the session, inside escape sequences and UTF-8
    /// characters included, in eight interleaved groups that run in parallel.
    @Test(arguments: 0..<8)
    func mirrorStartedAtEveryOffset(group: Int) {
        let bytes = MirrorRecording.session
        var failures: [String] = []
        for split in stride(from: group, through: bytes.count, by: 8) {
            let chunks = [1 + split % 5, 7, 2, 31, 1, 64]
            let outcome = MirrorStream.run(bytes, split: split, chunks: chunks)
            if !outcome.started {
                failures.append("split \(split): never reached a point to start")
            } else if !outcome.differences.isEmpty {
                failures.append("split \(split): \(outcome.differences.prefix(4))")
            }
            if failures.count >= 5 { break }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    /// The whole session, mirrored after each step in turn, at widths that
    /// make different lines wrap.
    @Test(arguments: [(20, 6), (41, 10), (80, 24)])
    func sessionAtOtherSizes(size: (cols: Int, rows: Int)) {
        let bytes = MirrorRecording.session
        var failures: [String] = []
        for split in stride(from: 0, through: bytes.count, by: 97) {
            let outcome = MirrorStream.run(bytes, split: split, chunks: [53, 5, 200],
                                           cols: size.cols, rows: size.rows)
            if !outcome.started || !outcome.differences.isEmpty {
                failures.append("split \(split): \(outcome.differences.prefix(4))")
            }
            if failures.count >= 5 { break }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func snapshotOfTheWholeSessionMatches() {
        let source = MirrorTestTerminal(cols: 30, rows: 8)
        source.feed(MirrorRecording.session)
        expectMirrors(source, scrollback: 400, then: ["$ exit\r\n"])
    }
}

/// Random terminal output from a seed: text of every kind with cursor
/// motion, erases, inserts and deletes, regions, both screens, links and
/// modes, the way full-screen programs and shells mix them.
struct MirrorRandomOutput {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    private mutating func pick(_ choices: [String]) -> String {
        choices[below(choices.count)]
    }

    mutating func make(pieces: Int, cols: Int, rows: Int) -> [UInt8] {
        let texts = ["hello", "x", "the quick brown fox", "漢字", "字", "かな", "👍", "🖐🏾", "🇺🇸", "🇬",
                     "e\u{301}", "\u{301}", "a\u{308}\u{323}", "\u{915}", "\u{93e}", "\u{915}\u{94d}\u{937}",
                     "\u{1100}", "\u{1161}", "\u{11a8}", "👩‍👩‍👦", "\u{200d}", "❤️", "☺︎", "🏽", "\t", " ",
                     String(repeating: "=", count: cols - 1), String(repeating: "#", count: cols + 3)]
        var out = ""
        for _ in 0..<pieces {
            switch below(24) {
            case 0...7:
                out += pick(texts)
            case 8:
                out += pick(["\r\n", "\n", "\r", "\u{1b}D", "\u{1b}M", "\u{1b}E", "\u{08}"])
            case 9:
                out += "\u{1b}[\(1 + below(rows));\(1 + below(cols))H"
            case 10:
                out += "\u{1b}[\(below(4))\(pick(["A", "B", "C", "D", "G", "d", "E", "F"]))"
            case 11:
                out += "\u{1b}[\(pick(["", "0", "1", "2"]))\(pick(["K", "J"]))"
            case 12:
                out += "\u{1b}[\(1 + below(5))\(pick(["X", "@", "P", "L", "M", "S", "T"]))"
            case 13:
                let codes = ["0", "1", "2", "3", "4", "4:3", "5", "7", "9", "22", "24", "27", "31", "42",
                             "38;5;\(below(256))", "48;2;\(below(256));\(below(256));\(below(256))",
                             "58;5;\(below(256))", "39", "49", "94", "105"]
                out += "\u{1b}[\(pick(codes))m"
            case 14:
                let top = 1 + below(rows)
                out += below(3) == 0 ? "\u{1b}[r" : "\u{1b}[\(top);\(min(rows, top + 1 + below(rows)))r"
            case 15:
                out += pick(["\u{1b}7", "\u{1b}8", "\u{1b}[s", "\u{1b}[u"])
            case 16:
                out += pick(["\u{1b}[?1049h", "\u{1b}[?1049l", "\u{1b}[?47h", "\u{1b}[?47l", "\u{1b}[?1047h",
                             "\u{1b}[?1047l", "\u{1b}[?1048h", "\u{1b}[?1048l"])
            case 17:
                out += pick(["\u{1b}]8;;http://a.example\u{1b}\\", "\u{1b}]8;id=2;http://b\u{07}",
                             "\u{1b}]8;;\u{1b}\\"])
            case 18:
                out += pick(["\u{1b}[4h", "\u{1b}[4l", "\u{1b}[?7l", "\u{1b}[?7h", "\u{1b}[?6h", "\u{1b}[?6l",
                             "\u{1b}[?25l", "\u{1b}[?25h", "\u{1b}[?1h", "\u{1b}[?2004h", "\u{1b}[?1002h",
                             "\u{1b}[?1006h", "\u{1b}[>1u", "\u{1b}[<u", "\u{1b}[3 q"])
            case 19:
                // Character sets come and go together with what selects them:
                // DECRC can leave a set in use that no designation names,
                // which the snapshot can't restore.
                out += pick(["\u{1b}(0lqk\u{1b}(B", "\u{1b})0\u{0e}x\u{0f}"])
            case 20:
                // DECFRA, only where it can't cut a wide character in two:
                // across whole rows it may. MirrorSnapshotTests covers the
                // cells it leaves.
                out += "\u{1b}[\(pick(["0", "1", "768", "32", "88", "8205"]));\(1 + below(rows));1;"
                    + "\(1 + below(rows));\(cols)$x"
            case 21:
                out += pick(["\u{1b}[3g", "\u{1b}H", "\u{1b}[g", "\u{1b}#6", "\u{1b}#5"])
            case 22:
                // REP after a character of one byte, as ncurses sends it.
                out += pick(["\u{1b}[?69h\u{1b}[2;\(cols - 3)s", "\u{1b}[?69l", "-\u{1b}[\(1 + below(3))b"])
            default:
                out += "\u{1b}]2;title \(below(100))\u{07}"
            }
        }
        return Array(out.utf8)
    }
}

extension MirrorSnapshotStreamTests {
    /// Random output from many seeds, mirrored from random points.
    @Test(arguments: 0..<16)
    func randomOutputMirrorsFromAnyPoint(seed: Int) {
        var random = MirrorRandomOutput(seed: UInt64(seed))
        let sizes = [(20, 6), (13, 4), (37, 9)]
        var failures: [String] = []
        for round in 0..<6 {
            let (cols, rows) = sizes[(seed + round) % sizes.count]
            let bytes = random.make(pieces: 260, cols: cols, rows: rows)
            for split in stride(from: (seed * 7 + round * 13) % 41, to: bytes.count, by: 41) {
                let outcome = MirrorStream.run(bytes, split: split, chunks: [1 + split % 9, 17, 3, 80],
                                               cols: cols, rows: rows)
                if !outcome.started || !outcome.differences.isEmpty {
                    failures.append("seed \(seed) round \(round) split \(split) (\(cols)×\(rows)): "
                                    + "\(outcome.differences.prefix(3))")
                    break
                }
            }
            if failures.count >= 3 { break }
        }
        #expect(failures.isEmpty, "\(failures)")
    }
}
