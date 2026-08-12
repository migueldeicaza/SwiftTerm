//
//  BufferOwnerRefTests.swift
//
//  Guards the invariant that lets `BufferLine` reach its `Buffer` without a
//  `weak` reference. See Docs/io-cpu-profile.md §3.1: a single weak reference to
//  a Buffer or a Terminal moves it onto the runtime's side-table refcount path
//  for life, which costs about 9x on every retain and release, and the parse
//  loop pays that constantly. The back-references therefore go through
//  `BufferRef` (cleared in `Buffer.deinit`) and `unowned(unsafe)` back-pointers
//  whose lifetimes are strictly nested.
//
//  These tests exist because that safety is now an invariant of the code rather
//  than something the compiler enforces.
//

import Foundation
import Testing

@testable import SwiftTerm

/// Reads bit 63 of the object header's refcount word (`InlineRefCountBits`'s
/// `UseSlowRC`): set means the object was moved to a side table.
private func isSideTabled(_ object: AnyObject) -> Bool {
    let word = unsafeBitCast(object, to: UnsafeRawPointer.self)
        .load(fromByteOffset: 8, as: UInt64.self)
    return (word >> 63) & 1 == 1
}

@Suite struct BufferOwnerRefTests {

    final class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    /// The whole point of the exercise: neither hot object may carry a side
    /// table. If someone reintroduces a `weak var terminal` or `[weak self]`
    /// anywhere that can reach these, this fails.
    @Test func terminalAndBufferStayOnTheInlineRefcountPath() {
        let terminal = Terminal(delegate: Delegate())
        terminal.feed(text: "some output\r\nand a second line\r\n")

        #expect(isSideTabled(terminal) == false)
        #expect(isSideTabled(terminal.buffer) == false)
        #expect(isSideTabled(terminal.normalBuffer) == false)
        #expect(isSideTabled(terminal.altBuffer) == false)
    }

    /// A line attached to a buffer can name its owner.
    @Test func attachedLineReportsItsOwningBuffer() {
        let terminal = Terminal(delegate: Delegate())
        terminal.feed(text: "hello\r\n")

        let line = terminal.buffer.lines[0]
        #expect(line.owningBuffer === terminal.buffer)
    }

    /// The invariant that replaces `weak`: a line that outlives its buffer reads
    /// nil, not a dangling pointer. `Buffer.deinit` clears the shared box.
    @Test func lineOutlivingItsBufferSeesNilOwner() {
        var buffer: Buffer? = Buffer(cols: 10, rows: 4, tabStopWidth: 8, scrollback: nil)
        buffer!.fillViewportRows()

        // Keep a line alive past its buffer.
        let line = buffer!.lines[0]
        #expect(line.owningBuffer === buffer)

        buffer = nil
        #expect(line.owningBuffer == nil)
    }

    /// Reflow stages lines through scratch lists. Those borrow the owner so an
    /// empty slot can still be filled, but must not re-stamp ownership or move
    /// the image counter — the regression that `isLive` exists to prevent.
    @Test func reflowDoesNotDisturbTheImageCounter() {
        let terminal = Terminal(delegate: Delegate())
        terminal.feed(text: "line one\r\nline two\r\nline three\r\n")
        #expect(terminal.buffer.hasAnyImages == false)

        terminal.resize(cols: 40, rows: 10)
        terminal.resize(cols: 100, rows: 24)
        terminal.resize(cols: 60, rows: 12)

        // A buffer that never carried an image must still report none: a
        // double-counted push would make this true and leak image bookkeeping.
        #expect(terminal.buffer.hasAnyImages == false)
    }

    /// Buffer teardown and reconstruction must not leave lines pointing at a
    /// dead buffer, on either the reset or the clear path.
    @Test func resetPathsRestampLineOwnership() {
        let terminal = Terminal(delegate: Delegate())
        terminal.feed(text: "before reset\r\n")

        terminal.resetToInitialState()
        terminal.feed(text: "after reset\r\n")

        let line = terminal.buffer.lines[0]
        #expect(line.owningBuffer === terminal.buffer)
        #expect(isSideTabled(terminal.buffer) == false)
    }
}
