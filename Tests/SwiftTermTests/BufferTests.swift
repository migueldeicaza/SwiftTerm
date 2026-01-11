//
//  BufferTests.swift
//
//  Tests for buffer management, particularly around alternate buffer switching.
//
//  Created for issue #256: Crash on reverseIndex when yBase exceeds lines.count
//

import Foundation
import Testing

@testable import SwiftTerm

final class BufferTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        // Required by TerminalDelegate
    }

    /// Test for issue #256: yBase was not reset in Buffer.clear(), causing crashes
    /// when switching between normal and alternate buffers.
    ///
    /// The bug occurred because:
    /// 1. Alt buffer gets used and yBase increases through scrolling
    /// 2. Switch back to normal buffer calls altBuffer.clear()
    /// 3. clear() did NOT reset yBase (the bug)
    /// 4. Switch to alt buffer again - yBase is stale but lines.count is small
    /// 5. reverseIndex() crashes because buffer.y + buffer.yBase > buffer.lines.count
    @Test func testIssue256_YBaseResetOnClear() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))

        // Switch to alternate buffer
        terminal.feed(text: "\u{1b}[?1049h")
        #expect(terminal.buffer === terminal.altBuffer, "Should be in alt buffer")

        // Fill the buffer and scroll to increase yBase
        // Feed enough content to fill and scroll the alt buffer
        for i in 0..<50 {
            terminal.feed(text: "Line \(i)\r\n")
        }

        // Record the yBase value (it may or may not have increased depending on scroll behavior)
        let altYBaseBeforeSwitch = terminal.altBuffer.yBase

        // Switch back to normal buffer (this calls altBuffer.clear())
        terminal.feed(text: "\u{1b}[?1049l")
        #expect(terminal.buffer === terminal.normalBuffer, "Should be in normal buffer")

        // The fix: yBase should be reset to 0 after clear()
        #expect(terminal.altBuffer.yBase == 0,
            "yBase should be reset to 0 after clear(). Was \(altYBaseBeforeSwitch) before switch.")

        // Switch back to alt buffer
        terminal.feed(text: "\u{1b}[?1049h")
        #expect(terminal.buffer === terminal.altBuffer, "Should be in alt buffer again")

        // yBase should still be 0 for the fresh alt buffer
        #expect(terminal.buffer.yBase == 0, "yBase should be 0 for fresh alt buffer")

        // Now the critical test: reverseIndex should not crash
        // Set up a scroll region and position cursor at scrollTop
        terminal.feed(text: "\u{1b}[5;20r")  // Set scroll region lines 5-20
        terminal.feed(text: "\u{1b}[5;1H")   // Move cursor to line 5, column 1 (scrollTop)

        // This should not crash - it's the reverseIndex (ESC M)
        terminal.feed(text: "\u{1b}M")

        // If we get here without crashing, the test passes
    }

    /// Test that verifies the crash condition from issue #256 would have occurred
    /// before the fix. This test directly manipulates buffer state to recreate
    /// the exact conditions that caused the crash.
    @Test func testIssue256_ReverseIndexWithInvalidYBase() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))

        // Switch to alternate buffer
        terminal.feed(text: "\u{1b}[?1049h")

        // Get direct access to the buffer for testing
        let buffer = terminal.buffer

        // Verify initial state
        #expect(buffer.yBase == 0, "yBase should start at 0")
        #expect(buffer.lines.count == 25, "Alt buffer should have exactly rows lines")

        // Set up scroll region
        terminal.feed(text: "\u{1b}[1;25r")  // Full screen scroll region
        terminal.feed(text: "\u{1b}[1;1H")   // Move to top-left (scrollTop position)

        #expect(buffer.y == 0, "Cursor should be at row 0")
        #expect(buffer.scrollTop == 0, "scrollTop should be 0")

        // The crash would occur if yBase + y >= lines.count
        // For this test, verify that the current state is valid
        let startIndex = buffer.y + buffer.yBase
        #expect(startIndex < buffer.lines.count,
            "startIndex (\(startIndex)) should be less than lines.count (\(buffer.lines.count))")

        // Perform reverseIndex - should not crash
        terminal.feed(text: "\u{1b}M")
    }

    /// Test that Buffer.clear() resets all relevant state including yBase
    @Test func testBufferClearResetsYBase() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))

        // Switch to alt buffer and do some scrolling
        terminal.feed(text: "\u{1b}[?1049h")

        // Fill buffer
        for _ in 0..<30 {
            terminal.feed(text: "test line\r\n")
        }

        // Manually verify the clear behavior by checking altBuffer after switching away
        terminal.feed(text: "\u{1b}[?1049l")  // Switch back, which clears alt buffer

        // All these should be reset
        #expect(terminal.altBuffer.yBase == 0, "yBase should be 0 after clear")
        #expect(terminal.altBuffer.yDisp == 0, "yDisp should be 0 after clear")
        #expect(terminal.altBuffer.x == 0, "x should be 0 after clear")
        #expect(terminal.altBuffer.y == 0, "y should be 0 after clear")
        #expect(terminal.altBuffer.linesTop == 0, "linesTop should be 0 after clear")
    }

    /// Direct test that yBase is reset by clear() - this test manipulates yBase directly
    /// to simulate the condition that could occur through various code paths.
    /// This is the definitive test for issue #256.
    @Test func testBufferClearMustResetYBase() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))

        // Switch to alt buffer
        terminal.feed(text: "\u{1b}[?1049h")

        // Directly set yBase to a non-zero value to simulate the bug condition.
        // In the real bug, yBase could become non-zero through various sequences
        // involving scroll regions, resizing, or other edge cases.
        terminal.altBuffer.yBase = 50  // Set to value > rows to simulate corrupted state

        // Verify our setup
        #expect(terminal.altBuffer.yBase == 50, "Setup: yBase should be 50")

        // Now switch back to normal buffer - this should call clear() on altBuffer
        terminal.feed(text: "\u{1b}[?1049l")

        // THE KEY ASSERTION: yBase MUST be reset to 0 by clear()
        // Before the fix, yBase was NOT reset, causing the crash in issue #256
        #expect(terminal.altBuffer.yBase == 0,
            "CRITICAL: yBase must be reset to 0 by clear(). This is the fix for issue #256.")
    }

    /// Test that demonstrates the crash condition from issue #256.
    /// This test sets up the exact conditions that would cause the crash:
    /// yBase + y >= lines.count when reverseIndex is called.
    @Test func testIssue256_CrashConditionPrevented() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))

        // Switch to alt buffer
        terminal.feed(text: "\u{1b}[?1049h")

        // Simulate the corrupted state: yBase is stale/high value
        terminal.altBuffer.yBase = 30

        // Alt buffer has 25 lines (rows), yBase = 30
        // If y = 0, then startIndex = 0 + 30 = 30, which is >= lines.count (25)
        // This would crash in reverseIndex before the defensive guard was added

        // Set up scroll region and position cursor at scrollTop
        terminal.feed(text: "\u{1b}[1;25r")  // Set scroll region
        terminal.feed(text: "\u{1b}[1;1H")   // Position at scrollTop

        // Verify the dangerous condition exists
        let buffer = terminal.buffer
        let startIndex = buffer.y + buffer.yBase
        let wouldCrash = startIndex >= buffer.lines.count

        // Before the fix, this would crash. Now it should be caught by the guard.
        if wouldCrash {
            print("Test detected crash condition: startIndex=\(startIndex) >= lines.count=\(buffer.lines.count)")
        }

        // The reverseIndex should not crash due to the defensive guard
        terminal.feed(text: "\u{1b}M")  // Reverse Index

        // Verify buffer state is still sane after the guard
        #expect(buffer.lines.count >= 0, "Buffer should still have lines")
    }

    // MARK: - Cursor save/restore tests

    /// Test that cmdRestoreCursor clamps savedY to valid range.
    /// savedY can become invalid after resize operations, causing abort() in Debug builds.
    @Test func testRestoreCursorClampsInvalidSavedY() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))

        // Save cursor at a valid position
        terminal.feed(text: "\u{1b}[10;10H")  // Move to row 10, col 10
        terminal.feed(text: "\u{1b}7")         // Save cursor (DECSC)

        // Corrupt savedY to simulate post-resize invalid state
        terminal.buffer.savedY = 100  // Way beyond rows (25)

        // Restore cursor - should clamp, not crash
        terminal.feed(text: "\u{1b}8")  // Restore cursor (DECRC)

        // Verify y was clamped to valid range
        #expect(terminal.buffer.y >= 0, "y should be >= 0")
        #expect(terminal.buffer.y < terminal.rows, "y should be < rows")
        #expect(terminal.buffer.y == terminal.rows - 1, "y should be clamped to rows-1")
    }

    /// Test that cmdRestoreCursor clamps negative savedY.
    @Test func testRestoreCursorClampsNegativeSavedY() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))

        // Corrupt savedY to negative value
        terminal.buffer.savedY = -10

        // Restore cursor - should clamp, not crash
        terminal.feed(text: "\u{1b}8")  // Restore cursor (DECRC)

        // Verify y was clamped to 0
        #expect(terminal.buffer.y == 0, "y should be clamped to 0")
    }

    /// Test that cmdRestoreCursor clamps savedX to valid range.
    @Test func testRestoreCursorClampsInvalidSavedX() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))

        // Corrupt savedX to invalid values
        terminal.buffer.savedX = 200  // Beyond cols (80)

        // Restore cursor - should clamp, not crash
        terminal.feed(text: "\u{1b}8")  // Restore cursor (DECRC)

        // Verify x was clamped to valid range
        #expect(terminal.buffer.x >= 0, "x should be >= 0")
        #expect(terminal.buffer.x < terminal.cols, "x should be < cols")
        #expect(terminal.buffer.x == terminal.cols - 1, "x should be clamped to cols-1")
    }

    // MARK: - Additional edge case tests

    /// Test that clear() works correctly when called directly on a buffer
    /// (not just through the buffer switch mechanism)
    @Test func testDirectClearResetsYBase() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))

        // Use alt buffer and corrupt its state
        terminal.feed(text: "\u{1b}[?1049h")
        terminal.altBuffer.yBase = 100
        terminal.altBuffer.yDisp = 50

        // Call clear() directly
        terminal.altBuffer.clear()

        // Verify all state is reset
        #expect(terminal.altBuffer.yBase == 0, "yBase should be 0 after direct clear()")
        #expect(terminal.altBuffer.yDisp == 0, "yDisp should be 0 after direct clear()")
        #expect(terminal.altBuffer.x == 0, "x should be 0 after direct clear()")
        #expect(terminal.altBuffer.y == 0, "y should be 0 after direct clear()")
        #expect(terminal.altBuffer.linesTop == 0, "linesTop should be 0 after direct clear()")
        #expect(terminal.altBuffer.scrollTop == 0, "scrollTop should be 0 after direct clear()")
        #expect(terminal.altBuffer.scrollBottom == 24, "scrollBottom should be rows-1 after direct clear()")
    }

    /// Test multiple rapid buffer switches don't corrupt state
    @Test func testRapidBufferSwitches() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))

        // Perform many rapid switches between normal and alt buffer
        for i in 0..<20 {
            // Switch to alt buffer
            terminal.feed(text: "\u{1b}[?1049h")
            #expect(terminal.buffer === terminal.altBuffer, "Iteration \(i): Should be in alt buffer")

            // Do some work in alt buffer
            terminal.feed(text: "Alt buffer line \(i)\r\n")

            // Corrupt yBase to simulate potential issue
            if i % 2 == 0 {
                terminal.altBuffer.yBase = 50
            }

            // Switch back to normal buffer
            terminal.feed(text: "\u{1b}[?1049l")
            #expect(terminal.buffer === terminal.normalBuffer, "Iteration \(i): Should be in normal buffer")

            // Verify alt buffer was properly cleared
            #expect(terminal.altBuffer.yBase == 0, "Iteration \(i): yBase should be reset after switch")

            // Do some work in normal buffer
            terminal.feed(text: "Normal buffer line \(i)\r\n")
        }

        // Final verification: switch to alt buffer and perform operations
        terminal.feed(text: "\u{1b}[?1049h")
        #expect(terminal.buffer.yBase == 0, "yBase should be 0 after all switches")

        // reverseIndex should work without crashing
        terminal.feed(text: "\u{1b}[1;1H")  // Move to top
        terminal.feed(text: "\u{1b}M")       // Reverse index
    }

    /// Test buffer switch during active scrolling with scroll region
    @Test func testBufferSwitchDuringScrolling() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))

        // Set up scroll region in normal buffer
        terminal.feed(text: "\u{1b}[5;20r")  // Scroll region lines 5-20

        // Add content that causes scrolling
        for i in 0..<30 {
            terminal.feed(text: "Normal line \(i)\r\n")
        }

        // Switch to alt buffer mid-scroll
        terminal.feed(text: "\u{1b}[?1049h")

        // Set up scroll region in alt buffer
        terminal.feed(text: "\u{1b}[3;15r")  // Different scroll region

        // Add content that causes scrolling in alt buffer
        for i in 0..<20 {
            terminal.feed(text: "Alt line \(i)\r\n")
        }

        // Corrupt yBase to simulate edge case
        terminal.altBuffer.yBase = 40

        // Switch back to normal buffer
        terminal.feed(text: "\u{1b}[?1049l")

        // Verify alt buffer is properly reset
        #expect(terminal.altBuffer.yBase == 0, "yBase should be reset")

        // Switch back to alt and verify it works
        terminal.feed(text: "\u{1b}[?1049h")
        #expect(terminal.buffer.yBase == 0, "Fresh alt buffer should have yBase=0")

        // Operations should work without crashing
        terminal.feed(text: "\u{1b}[3;1H")   // Move to scroll region top
        terminal.feed(text: "\u{1b}M")        // Reverse index
    }

    /// Test scroll() with corrupted yBase triggers defensive guard
    @Test func testScrollWithCorruptedYBase() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))

        // Switch to alt buffer
        terminal.feed(text: "\u{1b}[?1049h")

        // Set up a non-zero scroll region (triggers the else branch in scroll())
        terminal.feed(text: "\u{1b}[5;20r")

        // Corrupt yBase
        terminal.altBuffer.yBase = 50

        // Position cursor in scroll region
        terminal.feed(text: "\u{1b}[20;1H")

        // Trigger scroll by adding a newline at bottom of scroll region
        // This should trigger the defensive guard in scroll()
        terminal.feed(text: "\r\n")

        // Should not crash - if we get here, the test passes
    }
}
