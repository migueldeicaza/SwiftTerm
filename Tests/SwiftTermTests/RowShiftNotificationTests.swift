//
//  RowShiftNotificationTests.swift
//
//  The `onRowsShiftedInPlace` hook mirrors the structural notifications
//  attached selections already get, so hosts tracking their own absolute
//  row anchors can apply the same translation. These tests pin the reported
//  region, direction, and trim count for each scroll shape, and pin the
//  buffer reset epoch that tells a hard reset apart from a trim.
//

import Foundation
import XCTest

@testable import SwiftTerm

final class RowShiftNotificationTests: XCTestCase {

    private struct Shift: Equatable {
        var top: Int
        var bottom: Int
        var lines: Int
        var linesTop: Int
    }

    private final class Recorder {
        var shifts: [Shift] = []
    }

    private func makeTerminal (rows: Int = 6, cols: Int = 40, scrollback: Int = 2, recorder: Recorder = Recorder ()) -> HeadlessTerminal {
        var options = TerminalOptions.default
        options.cols = cols
        options.rows = rows
        options.scrollback = scrollback
        let headless = HeadlessTerminal (queue: nil, options: options) { _ in }
        headless.terminal.onRowsShiftedInPlace = { [weak recorder] top, bottom, lines, linesTop in
            recorder?.shifts.append (Shift (top: top, bottom: bottom, lines: lines, linesTop: linesTop))
        }
        return headless
    }

    private func feedLines (_ terminal: Terminal, count: Int) {
        for _ in 1...count {
            terminal.feed (text: "\r\n")
        }
    }

    /// A top-anchored margin that does not reach the buffer end trims the
    /// front row while rows below the margin stay: the hook names exactly
    /// the scrolled region and the new trim count.
    func testPartialMarginTrimReportsRegionAndTrim () {
        let recorder = Recorder ()
        let headless = makeTerminal (recorder: recorder)
        let terminal: Terminal = headless.terminal
        feedLines (terminal, count: 8)
        XCTAssertEqual (terminal.buffer.linesTop, 1)
        recorder.shifts.removeAll ()

        // Margin rows 1...4 with two scrollback rows above: the scrolled
        // region is buffer rows 0...5.
        terminal.feed (text: "\u{1b}[1;4r\u{1b}[4;1H\r\n")

        XCTAssertEqual (terminal.buffer.linesTop, 2)
        XCTAssertEqual (recorder.shifts, [Shift (top: 0, bottom: 5, lines: 1, linesTop: 2)])
    }

    /// A full-width scroll with a full buffer recycles the front row: the
    /// hook names the whole buffer.
    func testFullWidthScrollReportsWholeBuffer () {
        let recorder = Recorder ()
        let headless = makeTerminal (recorder: recorder)
        let terminal: Terminal = headless.terminal
        feedLines (terminal, count: 8)
        XCTAssertEqual (terminal.buffer.linesTop, 1)
        recorder.shifts.removeAll ()

        terminal.feed (text: "\u{1b}[6;1H\r\n")

        XCTAssertEqual (terminal.buffer.linesTop, 2)
        XCTAssertEqual (recorder.shifts, [Shift (top: 0, bottom: 7, lines: 1, linesTop: 2)])
    }

    /// A top-anchored margin scrolled before scrollback fills splices below
    /// the region instead of trimming: rows below move down, the trim count
    /// stays zero, and the direction is negative.
    func testPartialMarginSpliceReportsDownwardShift () {
        let recorder = Recorder ()
        let headless = makeTerminal (scrollback: 10, recorder: recorder)
        let terminal: Terminal = headless.terminal
        feedLines (terminal, count: 8)
        XCTAssertEqual (terminal.buffer.linesTop, 0)
        recorder.shifts.removeAll ()

        terminal.feed (text: "\u{1b}[1;4r\u{1b}[4;1H\r\n")

        XCTAssertEqual (terminal.buffer.linesTop, 0)
        XCTAssertEqual (recorder.shifts, [Shift (top: 7, bottom: 9, lines: -1, linesTop: 0)])
    }

    /// A hard reset on an untrimmed buffer changes no counter a fingerprint
    /// can see, so the buffer carries its own epoch: fresh buffers start at
    /// zero, a reset advances it, and trims leave it alone.
    func testResetEpochAdvancesOnHardResetOnly () {
        let headless = makeTerminal ()
        let terminal: Terminal = headless.terminal
        XCTAssertEqual (terminal.buffer.resetEpoch, 0)

        feedLines (terminal, count: 8)
        XCTAssertEqual (terminal.buffer.resetEpoch, 0)

        terminal.feed (text: "\u{1b}c")
        XCTAssertEqual (terminal.buffer.resetEpoch, 1)
        XCTAssertEqual (terminal.buffer.linesTop, 0)

        terminal.feed (text: "\u{1b}c")
        XCTAssertEqual (terminal.buffer.resetEpoch, 2)
    }
}
