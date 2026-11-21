//
//  ReflowTests.swift
//  
//
//  Created by Miguel de Icaza on 4/17/20.
//
#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

final class ReflowTests {
    
    @Test func testDoesNotCrashWhenReflowingToTinyWidth() {
        let options = TerminalOptions(cols: 10, rows: 10, scrollback: 1)
        let h = HeadlessTerminal (queue: SwiftTermTests.queue, options: options) { exitCode in }
        
        let t = h.terminal!
        
        t.feed (text: "1234567890\r\n")
        t.feed (text: "ABCDEFGH\r\n")
        t.feed (text: "abcdefghijklmnopqrstxxx\r\n")
        t.feed (text: "\r\n")
        
        // if we resize to a small column width, content is pushed back up and out the top
        // of the buffer. Ensure that this does not crash
        t.resize(cols: 3, rows: 10)
        #expect(Bool(true))
    }

    /// The text of every row of the screen, joined, without blank cells.
    private func screenLetters (_ t: Terminal) -> String {
        let rows = (0..<t.rows).map { t.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
        return String (rows.joined ().filter (\.isLetter))
    }

    /// Widening reflows a logical line whose rows wrapped at an internal
    /// right margin. Each new row takes the rest of more than one old row,
    /// and the text keeps its order.
    @Test func testWideningALineThatWrappedAtAMarginKeepsItsText() {
        let options = TerminalOptions(cols: 20, rows: 24)
        let h = HeadlessTerminal (queue: SwiftTermTests.queue, options: options) { exitCode in }
        let t = h.terminal!
        let letters = "abcdefghij".map { String (repeating: $0, count: 10) }.joined ()
        // Margins at columns 1 to 10 of 20: ten rows of ten letters, each
        // a continuation that is not a full-width wrap.
        t.feed (text: "\u{1b}[?69h\u{1b}[1;10s" + letters + "\r\n")

        t.resize(cols: 30, rows: 24)

        #expect(screenLetters (t) == letters)
    }

    /// A shell's line editor erases to the end of a row (EL) as it redraws
    /// a long command line, which ends that row's full-width wrap. When a
    /// full-screen program exits after the screen widened, the normal
    /// screen reflows wider, and each new row takes the rest of more than
    /// one old row.
    @Test func testLeavingTheAlternateScreenWidensALineWithAnErasedRowEnd() {
        let options = TerminalOptions(cols: 20, rows: 24)
        let h = HeadlessTerminal (queue: SwiftTermTests.queue, options: options) { exitCode in }
        let t = h.terminal!
        let letters = "abcdefghijklmnopqrst".map { String (repeating: $0, count: 20) }.joined ()
        t.feed (text: letters + "\r\n")
        // Erase the end of the first row and write its letter again, then
        // leave the cursor below the line.
        t.feed (text: "\u{1b}[1;20H\u{1b}[Ka\u{1b}[22;1H")

        t.feed (text: "\u{1b}[?1049h")
        t.resize(cols: 60, rows: 24)
        t.feed (text: "\u{1b}[?1049l")

        #expect(screenLetters (t) == letters)
    }

    /// The wrap causes of the screen rows 1 to `count - 1`.
    private func wrapCauses (_ t: Terminal, count: Int) -> [BufferLine.WrapCause] {
        (1..<count).map { t.getLine(row: $0)?.wrapCause ?? .none }
    }

    /// Widening gives the soft wrap cause only to the new row that holds
    /// the cell after an old soft seam. The other new rows get the
    /// full-width wrap cause.
    @Test func testWideningPutsTheSoftSeamOnTheCorrectRow() {
        let options = TerminalOptions(cols: 20, rows: 24)
        let h = HeadlessTerminal (queue: SwiftTermTests.queue, options: options) { exitCode in }
        let t = h.terminal!
        let letters = "abcdefghijklmnopqrst".map { String (repeating: $0, count: 20) }.joined ()
        t.feed (text: letters + "\r\n")
        // Erase the end of row 10 and write its letter again. Row 11 then
        // continues row 10 with a soft wrap, at text offset 200.
        t.feed (text: "\u{1b}[10;20H\u{1b}[Kj\u{1b}[22;1H")
        #expect(t.getLine(row: 10)?.wrapCause == .soft)

        t.resize(cols: 60, rows: 24)

        #expect(screenLetters (t) == letters)
        // New rows: [0,60) [60,120) [120,180) [180,240) [240,300)
        // [300,360) [360,400). Only [180,240) holds offset 200.
        #expect(wrapCauses (t, count: 7) ==
                [.screenEdge, .screenEdge, .soft, .screenEdge, .screenEdge, .screenEdge])
        #expect(t.getLine(row: 7)?.isWrapped == false)
    }

    /// Each row wrapped at an internal right margin is a soft seam, so
    /// after widening each new row that holds one of those seams keeps the
    /// soft wrap cause.
    @Test func testWideningAMarginWrappedLineKeepsSoftCauses() {
        let options = TerminalOptions(cols: 20, rows: 24)
        let h = HeadlessTerminal (queue: SwiftTermTests.queue, options: options) { exitCode in }
        let t = h.terminal!
        let letters = "abcdefghij".map { String (repeating: $0, count: 10) }.joined ()
        t.feed (text: "\u{1b}[?69h\u{1b}[1;10s" + letters + "\r\n")

        t.resize(cols: 30, rows: 24)

        // Old lengths: nine rows of 20 cells and one of 10 (190 cells),
        // with seams at 20, 40, ..., 180. Every new row of 30 cells after
        // the first holds a seam.
        #expect(screenLetters (t) == letters)
        #expect(wrapCauses (t, count: 7) == [BufferLine.WrapCause] (repeating: .soft, count: 6))
        #expect(t.getLine(row: 7)?.isWrapped == false)
    }

    /// Widening a line of wide characters with a soft seam: each new row
    /// takes the rest of more than one old row, and ends on the first half
    /// of a wide character, which moves to the next row.
    @Test func testWideningWideCharactersAcrossManyOldRows() {
        let options = TerminalOptions(cols: 12, rows: 24)
        let h = HeadlessTerminal (queue: SwiftTermTests.queue, options: options) { exitCode in }
        let t = h.terminal!
        // 60 different wide characters: ten rows of six.
        let chars = (0..<60).map { Character (Unicode.Scalar (0x4E00 + $0)!) }
        let text = String (chars)
        t.feed (text: text + "\r\n")
        // Erase the last character of row 2 (columns 11 and 12) and write it
        // again. Row 3 then continues row 2 with a soft wrap, at offset 24.
        t.feed (text: "\u{1b}[2;11H\u{1b}[K" + String (chars [11]) + "\u{1b}[20;1H")
        #expect(t.getLine(row: 2)?.wrapCause == .soft)

        t.resize(cols: 25, rows: 24)

        #expect(screenLetters (t) == text)
        // A new row of 25 cells would end on the first half of a wide
        // character, so each row holds 24 cells: twelve characters.
        for row in 0..<5 {
            let rowText = t.getLine(row: row)?.translateToString(trimRight: true) ?? ""
            #expect(rowText.filter (\.isLetter).count == 12, "row \(row)")
        }
        #expect(t.getLine(row: 5)?.isWrapped == false)
        // New rows: [0,24) [24,48) [48,72) [72,96) [96,120). Only [24,48)
        // holds offset 24. Rows of 25 cells would put it on row 0 instead.
        #expect(wrapCauses (t, count: 5) == [.soft, .screenEdge, .screenEdge, .screenEdge])
    }

    /// The same line of wide characters, widened by the normal screen when
    /// a full-screen program exits, as in the crash report.
    @Test func testLeavingTheAlternateScreenWidensWideCharacters() {
        let options = TerminalOptions(cols: 12, rows: 24)
        let h = HeadlessTerminal (queue: SwiftTermTests.queue, options: options) { exitCode in }
        let t = h.terminal!
        let chars = (0..<60).map { Character (Unicode.Scalar (0x4E00 + $0)!) }
        let text = String (chars)
        t.feed (text: text + "\r\n")
        t.feed (text: "\u{1b}[2;11H\u{1b}[K" + String (chars [11]) + "\u{1b}[20;1H")

        t.feed (text: "\u{1b}[?1049h")
        t.resize(cols: 37, rows: 24)
        t.feed (text: "\u{1b}[?1049l")

        #expect(screenLetters (t) == text)
    }
}
#endif
