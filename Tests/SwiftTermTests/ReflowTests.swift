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
}
#endif
