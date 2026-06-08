//
//  TerminalFollowTailTests.swift
//  Regression for the long-standing macOS "terminal scrolls to the bottom while
//  I'm scrolled up reading" bug. Root cause: the macOS view never set
//  Terminal.userScrolling, the only flag the feed consults, so every feed forced
//  yDisp = yBase. Fix: scrollTo(row:) drives userScrolling from the scroll
//  position. Typing routes through ensureCaretIsVisible → scrollTo(yBase), which
//  clears it and resumes following.
//

import Foundation
import Testing

@testable import SwiftTerm

#if os(macOS)
@Suite struct TerminalFollowTailTests {

    @Test func scrolledUpHoldsPositionWhileOutputStreams() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 240, height: 120))
        let t = view.getTerminal()
        for i in 0..<200 { t.feed(text: "line\(i)\r\n") }
        let yBase0 = t.buffer.yBase
        #expect(yBase0 > 20)                       // real scrollback accumulated

        // User scrolls UP off the bottom.
        let parked = yBase0 - 8
        view.scrollTo(row: parked)
        #expect(t.buffer.yDisp == parked)
        #expect(t.userScrolling == true)           // pre-fix: false

        // Output streams in — the viewport must HOLD, not yank to the new bottom.
        for i in 200..<220 { t.feed(text: "line\(i)\r\n") }
        #expect(t.buffer.yDisp == parked)          // pre-fix: == new yBase (the bug)

        // Typing returns to the bottom and resumes following the tail.
        view.send(data: Array("x".utf8)[...])      // → ensureCaretIsVisible → scrollTo(yBase)
        #expect(t.userScrolling == false)
        let yBase1 = t.buffer.yBase
        t.feed(text: "tail\r\n")
        #expect(t.buffer.yDisp == t.buffer.yBase)  // followed the tail again
        #expect(t.buffer.yBase == yBase1 + 1)
    }

    @Test func atBottomFollowsTailNormally() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 240, height: 120))
        let t = view.getTerminal()
        for i in 0..<50 { t.feed(text: "row\(i)\r\n") }
        #expect(t.buffer.yDisp == t.buffer.yBase)  // at the bottom
        #expect(t.userScrolling == false)
        t.feed(text: "more\r\n")
        #expect(t.buffer.yDisp == t.buffer.yBase)  // still following
    }
}
#endif
