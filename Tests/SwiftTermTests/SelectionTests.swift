//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 4/29/20.
//

import Foundation
import XCTest

@testable import SwiftTerm

final class SelectionTests: XCTestCase, TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        print ("here")
    }
    
    func testDoesNotCrashWhenSelectingWordOrExpressionOutsideColumnRange ()
    {
        let terminal = Terminal(delegate: self, options: TerminalOptions (cols: 10, rows: 10))
        let selection = SelectionService(terminal: terminal)
        terminal.feed (text: "1234567890")
        
        // depending on the size of terminal view, there might be a space near the margin where the user
        // clicks which might result in a col or row outside the bounds of terminal,
        selection.selectWordOrExpression(at: Position(col: -1, row: 0), in: terminal.buffer)
        selection.selectWordOrExpression(at: Position(col: 11, row: 0), in: terminal.buffer)
    }
    
    func testDoesNotCrashWhenSelectingWordOrExpressionOutsideRowRange ()
    {
        let terminal = Terminal(delegate: self, options: TerminalOptions (cols: 10, rows: 10))
        let selection = SelectionService(terminal: terminal)
        terminal.feed (text: "1234567890")

        // depending on the size of terminal view, there might be a space near the margin where the user
        // clicks which might result in a col or row outside the bounds of terminal,
        selection.selectWordOrExpression(at: Position (col: 0, row: -1), in: terminal.buffer)

    }

#if os(macOS)
    // Test only on macOS due to differences in how frames are handled on mac and iOS
    func testMouseHitCorrectWhenScrolled()
    {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 10, height: 10)))

        for _ in 0..<100 {
            view.terminal.feed (text: "12345")
        }

        // Scroll all the way down, check the bottom-left corner
        view.scrollTo(row: 100)
        XCTAssertEqual(view.calculateMouseHit(at: CGPoint(x: 0, y: 0)).grid.row, 100)

        // Scroll all the way back up, check the top-left corner
        view.scrollTo(row: 1)
        XCTAssertEqual(view.calculateMouseHit(at: CGPoint(x: 0, y: 10)).grid.row, 1)
    }
#endif
}
