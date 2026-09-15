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
        var linesTopDelta: Int
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
        headless.terminal.onRowsShiftedInPlace = { [weak recorder] top, bottom, lines, linesTop, linesTopDelta in
            recorder?.shifts.append (Shift (top: top, bottom: bottom, lines: lines, linesTop: linesTop, linesTopDelta: linesTopDelta))
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
        XCTAssertEqual (recorder.shifts, [Shift (top: 0, bottom: 5, lines: 1, linesTop: 2, linesTopDelta: 1)])
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
        XCTAssertEqual (recorder.shifts, [Shift (top: 0, bottom: 7, lines: 1, linesTop: 2, linesTopDelta: 1)])
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
        XCTAssertEqual (recorder.shifts, [Shift (top: 7, bottom: 9, lines: -1, linesTop: 0, linesTopDelta: 0)])
    }

    /// A 3J scrollback clear resets the trim count: the shift carries the
    /// consumed base as a negative delta so hosts translate survivors onto
    /// their new anchors instead of double-counting or expiring them.
    func testScrollbackClearReportsFrameReset () {
        let recorder = Recorder ()
        let headless = makeTerminal (recorder: recorder)
        let terminal: Terminal = headless.terminal
        feedLines (terminal, count: 8)
        XCTAssertEqual (terminal.buffer.linesTop, 1)
        XCTAssertEqual (terminal.buffer.lines.count, 8)
        recorder.shifts.removeAll ()

        terminal.feed (text: "\u{1b}[3J")

        XCTAssertEqual (terminal.buffer.linesTop, 0)
        XCTAssertEqual (terminal.buffer.lines.count, 6)
        XCTAssertEqual (recorder.shifts, [Shift (top: 0, bottom: 7, lines: 2, linesTop: 0, linesTopDelta: -1)])
    }

    /// `clearScrollback` trims without touching the trim count, which used
    /// to leave host anchors aimed at the wrong rows with no notification
    /// at all. It now mirrors like any other trim.
    func testClearScrollbackReportsTrim () {
        let recorder = Recorder ()
        let headless = makeTerminal (recorder: recorder)
        let terminal: Terminal = headless.terminal
        feedLines (terminal, count: 8)
        let trimmedLineCount = terminal.buffer.yBase
        XCTAssertGreaterThan (trimmedLineCount, 0)
        let previousLineCount = terminal.buffer.lines.count
        let previousLinesTop = terminal.buffer.linesTop
        recorder.shifts.removeAll ()

        terminal.clearScrollback ()

        XCTAssertEqual (terminal.buffer.linesTop, previousLinesTop)
        XCTAssertEqual (recorder.shifts, [Shift (top: 0, bottom: previousLineCount - 1, lines: trimmedLineCount, linesTop: previousLinesTop, linesTopDelta: 0)])
    }

    /// The documented host translation law, applied to absolute anchors
    /// (-1 marks a dropped anchor and is preserved). Membership is tested
    /// in the pre-shift frame, the landing in the post-shift frame, motion
    /// is net of the per-shift trim consumption, and anchors outside the
    /// window absorb this shift's base share.
    private func applyHostLaw (_ anchors: [Int], shift: Shift) -> [Int] {
        let previousBase = shift.linesTop - shift.linesTopDelta
        let previousWindow = (shift.top + previousBase)...(shift.bottom + previousBase)
        let window = (shift.top + shift.linesTop)...(shift.bottom + shift.linesTop)
        let motion = shift.lines - shift.linesTopDelta
        return anchors.map { anchor in
            guard anchor >= 0, previousWindow.contains (anchor) else {
                return anchor >= 0 ? anchor + shift.linesTopDelta : anchor
            }
            let moved = anchor - motion
            return window.contains (moved) ? moved : -1
        }
    }

    /// The host's reconcile half: anchors above the surviving base are
    /// gone. The law never keeps one (the windows exclude them), but the
    /// eviction runs here too so the tests stay faithful when a shift's
    /// motion is zero.
    private func evictBelowBase (_ anchors: [Int], terminal: Terminal) -> [Int] {
        let base = terminal.buffer.linesTop
        return anchors.map { $0 >= 0 && $0 < base ? -1 : $0 }
    }

    private func textAtAbsoluteRow (_ absoluteRow: Int, terminal: Terminal) -> String? {
        let slot = absoluteRow - terminal.buffer.linesTop
        guard slot >= 0, slot < terminal.buffer.lines.count else {
            return nil
        }
        return terminal.buffer.lines [slot].translateToString (trimRight: true)
    }

    /// Independent second route: where the buffer actually holds the text.
    private func absoluteRowContaining (_ text: String, terminal: Terminal) -> Int? {
        for slot in 0..<terminal.buffer.lines.count {
            if terminal.buffer.lines [slot].translateToString (trimRight: true).hasPrefix (text) {
                return slot + terminal.buffer.linesTop
            }
        }
        return nil
    }

    /// Full recycles (whole and region-clamped) followed by a 3J: after
    /// every step the law-derived anchors must agree with a content search,
    /// so a per-shift consumer can never drift from a full re-sync. Plants
    /// go to slots 0...5 of the fresh buffer.
    func testTrimPathsInterleaveLawMatchesContent () {
        let recorder = Recorder ()
        var options = TerminalOptions.default
        options.cols = 40
        options.rows = 6
        options.scrollback = 8
        let headless = HeadlessTerminal (queue: nil, options: options) { _ in }
        headless.terminal.onRowsShiftedInPlace = { [weak recorder] top, bottom, lines, linesTop, linesTopDelta in
            recorder?.shifts.append (Shift (top: top, bottom: bottom, lines: lines, linesTop: linesTop, linesTopDelta: linesTopDelta))
        }
        let terminal: Terminal = headless.terminal
        let plants = ["A", "B", "C", "D", "E", "F", "H", "G"]
        for plant in plants.prefix (6) {
            terminal.feed (text: "\(plant)\r\n")
        }
        var anchors = [0, 1, 2, 3, 4, 5]
        func check (_ file: StaticString = #filePath, _ line: UInt = #line) {
            for (index, plant) in plants.enumerated () {
                guard index < anchors.count else {
                    continue
                }
                let anchor = anchors [index]
                if anchor < 0 {
                    XCTAssertNil (absoluteRowContaining (plant, terminal: terminal), "plant \(plant) should be gone", file: file, line: line)
                } else {
                    XCTAssertEqual (textAtAbsoluteRow (anchor, terminal: terminal), plant, "plant \(plant) at \(anchor)", file: file, line: line)
                    XCTAssertEqual (absoluteRowContaining (plant, terminal: terminal), anchor, "plant \(plant) content search", file: file, line: line)
                }
            }
        }
        func consume (_ expected: [Shift], _ file: StaticString = #filePath, _ line: UInt = #line) {
            XCTAssertEqual (recorder.shifts, expected, file: file, line: line)
            for shift in recorder.shifts {
                anchors = applyHostLaw (anchors, shift: shift)
            }
            anchors = evictBelowBase (anchors, terminal: terminal)
            recorder.shifts.removeAll ()
            check (file, line)
        }

        // Seven pushes fill the buffer, then five scrollback-consuming
        // recycles trim the oldest plants away.
        terminal.feed (text: "\u{1b}[6;1H\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n")
        XCTAssertEqual (terminal.buffer.linesTop, 5)
        XCTAssertEqual (terminal.buffer.lines.count, 14)
        consume ([
            Shift (top: 0, bottom: 13, lines: 1, linesTop: 1, linesTopDelta: 1),
            Shift (top: 0, bottom: 13, lines: 1, linesTop: 2, linesTopDelta: 1),
            Shift (top: 0, bottom: 13, lines: 1, linesTop: 3, linesTopDelta: 1),
            Shift (top: 0, bottom: 13, lines: 1, linesTop: 4, linesTopDelta: 1),
            Shift (top: 0, bottom: 13, lines: 1, linesTop: 5, linesTopDelta: 1),
        ])
        XCTAssertEqual (anchors, [-1, -1, -1, -1, -1, 5])

        // Plant H at the viewport bottom; the feed scrolls once more over
        // the whole buffer.
        terminal.feed (text: "\u{1b}[6;1HH\r\n")
        consume ([Shift (top: 0, bottom: 13, lines: 1, linesTop: 6, linesTopDelta: 1)])
        anchors.append (18)
        check ()

        // A top-anchored region recycle: partial window, same consumption.
        // F sits in the destroyed front slot and drops, while H below the
        // window absorbs the base advance (its slots do not move).
        terminal.feed (text: "\u{1b}[1;4r\u{1b}[4;1H\r\n")
        consume ([Shift (top: 0, bottom: 11, lines: 1, linesTop: 7, linesTopDelta: 1)])
        XCTAssertEqual (anchors, [-1, -1, -1, -1, -1, -1, 19])

        // Plant G at the viewport bottom (region reset first so the feed
        // scrolls); the feed scrolls once more.
        terminal.feed (text: "\u{1b}[r\u{1b}[6;1HG\r\n")
        consume ([Shift (top: 0, bottom: 13, lines: 1, linesTop: 8, linesTopDelta: 1)])
        anchors.append (20)
        check ()

        // 3J: the frame resets; H and G land exactly on their surviving
        // rows while the dropped plants stay dropped.
        terminal.feed (text: "\u{1b}[3J")
        consume ([Shift (top: 0, bottom: 13, lines: 8, linesTop: 0, linesTopDelta: -8)])
        XCTAssertEqual (anchors, [-1, -1, -1, -1, -1, -1, 3, 4])
    }

    /// A true margin scroll moves only the region, then IL moves rows down:
    /// anchors outside each window stay put while inside ones track content.
    func testMarginAndInsertPathsLawMatchesContent () {
        let recorder = Recorder ()
        var options = TerminalOptions.default
        options.cols = 40
        options.rows = 6
        options.scrollback = 8
        let headless = HeadlessTerminal (queue: nil, options: options) { _ in }
        headless.terminal.onRowsShiftedInPlace = { [weak recorder] top, bottom, lines, linesTop, linesTopDelta in
            recorder?.shifts.append (Shift (top: top, bottom: bottom, lines: lines, linesTop: linesTop, linesTopDelta: linesTopDelta))
        }
        let terminal: Terminal = headless.terminal
        for plant in ["A", "B", "C"] {
            terminal.feed (text: "\(plant)\r\n")
        }
        var anchors = [0, 1, 2]
        let plants = ["A", "B", "C"]
        func check (_ file: StaticString = #filePath, _ line: UInt = #line) {
            for (index, plant) in plants.enumerated () {
                let anchor = anchors [index]
                if anchor < 0 {
                    XCTAssertNil (absoluteRowContaining (plant, terminal: terminal), "plant \(plant) should be gone", file: file, line: line)
                } else {
                    XCTAssertEqual (textAtAbsoluteRow (anchor, terminal: terminal), plant, "plant \(plant) at \(anchor)", file: file, line: line)
                    XCTAssertEqual (absoluteRowContaining (plant, terminal: terminal), anchor, "plant \(plant) content search", file: file, line: line)
                }
            }
        }
        func consume (_ expected: [Shift], _ file: StaticString = #filePath, _ line: UInt = #line) {
            XCTAssertEqual (recorder.shifts, expected, file: file, line: line)
            for shift in recorder.shifts {
                anchors = applyHostLaw (anchors, shift: shift)
            }
            anchors = evictBelowBase (anchors, terminal: terminal)
            recorder.shifts.removeAll ()
            check (file, line)
        }

        // A true margin (not top-anchored): slots 1...4 shift up in place.
        // B sits on the destroyed top edge and drops; C follows its row up.
        terminal.feed (text: "\u{1b}[2;5r\u{1b}[5;1H\r\n")
        consume ([Shift (top: 1, bottom: 4, lines: 1, linesTop: 0, linesTopDelta: 0)])
        XCTAssertEqual (anchors, [0, -1, 1])

        // Insert two lines at row 2: rows move down, C rides along.
        terminal.feed (text: "\u{1b}[r\u{1b}[2;1H\u{1b}[2L")
        consume ([Shift (top: 1, bottom: 5, lines: -2, linesTop: 0, linesTopDelta: 0)])
        XCTAssertEqual (anchors, [0, -1, 3])
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
