import Testing
@testable import SwiftTerm

final class CarriageReturnTests {
    private let esc = "\u{1b}"
    
    @Test func testProgressBarOverwrite() {
        // Test the exact bug scenario: progress bar updates
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 30, rows: 5)
        
        // Simulate progress bar: write, \r, write again
        terminal.feed(text: "Progress 1/20 ####")
        terminal.feed(text: "\r")
        terminal.feed(text: "Progress 2/20 ########")
        
        // Should only show the latest progress
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "Progress 2/20 ########")
        
        // Cursor should be after the new text
        #expect(terminal.buffer.x == 22)
    }
    
    @Test func testMultipleCarriageReturns() {
        // Test multiple overwrites on same line
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 30, rows: 5)
        
        for i in 1...5 {
            terminal.feed(text: "\rIteration \(i)")
        }
        
        // Should only show the last iteration
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "Iteration 5")
    }
    
    @Test func testCarriageReturnWithLineFeed() {
        // Test that \r\n properly moves to next line
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 30, rows: 5)
        
        terminal.feed(text: "Line 1\r\nLine 2\r\nLine 3")
        
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "Line 1")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "Line 2")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "Line 3")
    }
    
    @Test func testCarriageReturnPartialOverwrite() {
        // Test overwriting with shorter text
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 30, rows: 5)
        
        terminal.feed(text: "Long text here")
        terminal.feed(text: "\r")
        terminal.feed(text: "Short")
        
        // Old content should be cleared
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "Short")
    }
    
    @Test func testCarriageReturnWithMarginMode() {
        // Test \r behavior with margin mode enabled
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 30, rows: 5)
        
        terminal.feed(text: "\(esc)[?69h")  // Enable margin mode
        terminal.feed(text: "\(esc)[5;25s")  // Set margins
        terminal.feed(text: "\(esc)[1;10H")  // Position cursor
        terminal.feed(text: "Test\r")
        
        // Cursor should go to margin left, not column 0
        #expect(terminal.buffer.x == 4)  // margin left is 4 (5-1 for 0-indexed)
    }
    
    @Test func testSpinnerAnimation() {
        // Test spinner characters: ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 30, rows: 5)
        let spinners = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        
        for spinner in spinners {
            terminal.feed(text: "\r\(spinner) Loading...")
        }
        
        // Should only show the last spinner
        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "⠏ Loading...")
    }
}
