//
//  SynchronizedUpdatesTests.swift
//  SwiftTermTests
//
//  Tests for synchronized updates functionality (DEC mode 2026)
//

import XCTest
@testable import SwiftTerm

// Mock delegate for testing
class MockTerminalDelegate: TerminalDelegate {
    func bell(source: Terminal) {}
    func bufferActivated(source: Terminal) {}
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
    func showCursor(source: Terminal) {}
    func hideCursor(source: Terminal) {}
    func setTerminalTitle(source: Terminal, title: String) {}
    func setTerminalIconTitle(source: Terminal, title: String) {}
    func sizeChanged(source: Terminal) {}
    func setTerminalForegroundColor(source: Terminal, color: Color) {}
    func setTerminalBackgroundColor(source: Terminal, color: Color) {}
    func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { return nil }
    func mouseModeChanged(source: Terminal) {}
    func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {}
}

final class SynchronizedUpdatesTests: XCTestCase {
    
    func testSynchronizedUpdatesMode() {
        let delegate = MockTerminalDelegate()
        let terminal = Terminal(delegate: delegate)
        
        // Initial state should have synchronized updates disabled
        XCTAssertFalse(terminal.synchronizedUpdates)
        
        // Enable synchronized updates mode
        terminal.feed(text: "\u{1b}[?2026h")
        XCTAssertTrue(terminal.synchronizedUpdates)
        
        // Disable synchronized updates mode
        terminal.feed(text: "\u{1b}[?2026l")
        XCTAssertFalse(terminal.synchronizedUpdates)
    }
    
    func testSynchronizedUpdatesUpdateDeferral() {
        let delegate = MockTerminalDelegate()
        let terminal = Terminal(delegate: delegate)
        
        // Initial setup - write some text and clear ranges
        terminal.feed(text: "Initial text\n")
        terminal.clearUpdateRange()
        
        // Enable synchronized updates
        terminal.feed(text: "\u{1b}[?2026h")
        XCTAssertTrue(terminal.synchronizedUpdates)
        
        // Write more text that should normally trigger updates
        terminal.feed(text: "Deferred text\n")
        
        // With synchronized updates enabled, getUpdateRange should return nil
        XCTAssertNil(terminal.getUpdateRange())
        XCTAssertNil(terminal.getScrollInvariantUpdateRange())
        
        // Disable synchronized updates - this should flush deferred updates
        terminal.feed(text: "\u{1b}[?2026l")
        XCTAssertFalse(terminal.synchronizedUpdates)
        
        // Now updates should be available
        let updateRange = terminal.getUpdateRange()
        XCTAssertNotNil(updateRange)
    }
    
    func testSynchronizedUpdatesUpdateFullScreen() {
        let delegate = MockTerminalDelegate()
        let terminal = Terminal(delegate: delegate)
        
        // Enable synchronized updates
        terminal.feed(text: "\u{1b}[?2026h")
        
        // Call updateFullScreen - this should defer updates
        terminal.updateFullScreen()
        
        // Should not return any updates while synchronized updates are enabled
        XCTAssertNil(terminal.getUpdateRange())
        
        // Disable synchronized updates
        terminal.feed(text: "\u{1b}[?2026l")
        
        // Now should have full screen update range
        let updateRange = terminal.getUpdateRange()
        XCTAssertNotNil(updateRange)
        if let range = updateRange {
            XCTAssertEqual(range.startY, 0)
            XCTAssertEqual(range.endY, terminal.rows)
        }
    }
    
    static var allTests = [
        ("testSynchronizedUpdatesMode", testSynchronizedUpdatesMode),
        ("testSynchronizedUpdatesUpdateDeferral", testSynchronizedUpdatesUpdateDeferral),
        ("testSynchronizedUpdatesUpdateFullScreen", testSynchronizedUpdatesUpdateFullScreen),
    ]
}