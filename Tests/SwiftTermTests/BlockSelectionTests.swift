//
//  BlockSelectionTests.swift
//
//  A block selection, as an Option-drag makes: the columns between two
//  points, on every row between them.
//

import Foundation
import Testing

#if os(macOS)
import AppKit
#endif

@testable import SwiftTerm

final class BlockSelectionTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    private func makeTerminal(cols: Int = 12, rows: Int = 5, text: String) -> (Terminal, SelectionService) {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows))
        let selection = SelectionService(terminal: terminal)
        terminal.feed(text: text)
        return (terminal, selection)
    }

    @Test func blockCopiesTheSameColumnsFromEveryRow() {
        let (_, selection) = makeTerminal(text: "0123456789\r\nabcdefghij\r\nABCDEFGHIJ")

        selection.startBlockSelection(bufferPosition: Position(col: 2, row: 0))
        selection.dragExtend(bufferPosition: Position(col: 5, row: 2))

        #expect(selection.isBlock)
        #expect(selection.getSelectedText() == "234\ncde\nCDE")
        for row in 0...2 {
            #expect(selection.selectedColumnsRange(row: row, cols: 12) == 2..<5)
        }
        #expect(selection.selectedColumnsRange(row: 3, cols: 12) == nil)
    }

    @Test func blockDraggedUpAndLeftCoversTheSameColumns() {
        let (_, selection) = makeTerminal(text: "0123456789\r\nabcdefghij\r\nABCDEFGHIJ")

        selection.startBlockSelection(bufferPosition: Position(col: 5, row: 2))
        selection.dragExtend(bufferPosition: Position(col: 2, row: 0))

        #expect(selection.getSelectedText() == "234\ncde\nCDE")
        #expect(selection.selectedColumnsRange(row: 1, cols: 12) == 2..<5)
    }

    @Test func streamDragStillReadsInOrder() {
        let (_, selection) = makeTerminal(text: "0123456789\r\nabcdefghij\r\nABCDEFGHIJ")

        selection.setSoftStart(bufferPosition: Position(col: 2, row: 0))
        selection.startSelection()
        selection.dragExtend(bufferPosition: Position(col: 5, row: 2))

        #expect(!selection.isBlock)
        #expect(selection.getSelectedText() == "23456789\nabcdefghij\nABCDE")
        #expect(selection.selectedColumnsRange(row: 1, cols: 12) == 0..<12)
    }

    @Test func blockTrimsTrailingSpacesAndKeepsEmptyRows() {
        let (_, selection) = makeTerminal(text: "ab   cdefgh\r\nab\r\nxyz   w")

        selection.startBlockSelection(bufferPosition: Position(col: 0, row: 0))
        selection.dragExtend(bufferPosition: Position(col: 5, row: 2))
        #expect(selection.getSelectedText() == "ab\nab\nxyz")

        // Only trailing spaces go; a row with nothing in the block is empty.
        selection.startBlockSelection(bufferPosition: Position(col: 5, row: 0))
        selection.dragExtend(bufferPosition: Position(col: 7, row: 2))
        #expect(selection.getSelectedText() == "cd\n\n w")
    }

    @Test func blockCopiesWideCharactersCutByAnEdgeWhole() {
        // 中 fills columns 1 and 2.
        let (_, selection) = makeTerminal(text: "a中bc\r\nwxyz")

        // The left edge falls on its second half.
        selection.startBlockSelection(bufferPosition: Position(col: 2, row: 0))
        selection.dragExtend(bufferPosition: Position(col: 3, row: 1))
        #expect(selection.getSelectedText() == "中\ny")

        // The right edge falls between its halves.
        selection.startBlockSelection(bufferPosition: Position(col: 0, row: 0))
        selection.dragExtend(bufferPosition: Position(col: 2, row: 1))
        #expect(selection.getSelectedText() == "a中\nwx")

        // A block that starts on it takes it once.
        selection.startBlockSelection(bufferPosition: Position(col: 1, row: 0))
        selection.dragExtend(bufferPosition: Position(col: 4, row: 1))
        #expect(selection.getSelectedText() == "中b\nxyz")
    }

    @Test func blockReachingTheLastColumnIncludesIt() {
        let (_, selection) = makeTerminal(cols: 6, text: "abcdef\r\nghijkl")

        selection.startBlockSelection(bufferPosition: Position(col: 3, row: 0))
        selection.dragExtend(bufferPosition: Position(col: 5, row: 1))

        #expect(selection.selectedColumnsRange(row: 0, cols: 6) == 3..<6)
        #expect(selection.getSelectedText() == "def\njkl")
    }

    @Test func zeroWidthBlockSelectsNothing() {
        let (_, selection) = makeTerminal(text: "0123456789\r\nabcdefghij")

        selection.startBlockSelection(bufferPosition: Position(col: 4, row: 0))
        selection.dragExtend(bufferPosition: Position(col: 4, row: 1))

        #expect(selection.selectedColumnsRange(row: 0, cols: 12) == nil)
        #expect(selection.getSelectedText() == "")
    }

    @Test func shiftExtendMovesTheBlockEdgesNearestTheClick() {
        let (_, selection) = makeTerminal(text: "0123456789\r\nabcdefghij\r\nABCDEFGHIJ\r\nklmnopqrst")

        selection.startBlockSelection(bufferPosition: Position(col: 2, row: 0))
        selection.dragExtend(bufferPosition: Position(col: 5, row: 1))

        // Below and to the right: the top-left corner stays.
        selection.shiftExtend(bufferPosition: Position(col: 7, row: 3))
        #expect(selection.isBlock)
        #expect(selection.getSelectedText() == "23456\ncdefg\nCDEFG\nmnopq")

        // Inside, near the left edge: that edge moves in, the rest stays.
        selection.shiftExtend(bufferPosition: Position(col: 3, row: 3))
        #expect(selection.getSelectedText() == "3456\ndefg\nDEFG\nnopq")
    }

    @Test func otherSelectionsEndTheBlock() {
        let (_, selection) = makeTerminal(text: "hello world\r\nabcdefghij")

        selection.startBlockSelection(bufferPosition: Position(col: 0, row: 0))
        selection.dragExtend(bufferPosition: Position(col: 3, row: 1))
        selection.selectWordOrExpression(at: Position(col: 7, row: 0), in: selection.terminal.buffer)
        #expect(!selection.isBlock)
        #expect(selection.getSelectedText() == "world")

        selection.startBlockSelection(bufferPosition: Position(col: 0, row: 0))
        selection.select(row: 1)
        #expect(!selection.isBlock)

        selection.startBlockSelection(bufferPosition: Position(col: 0, row: 0))
        selection.startSelection(row: 0, col: 1)
        #expect(!selection.isBlock)

        selection.startBlockSelection(bufferPosition: Position(col: 0, row: 0))
        selection.selectNone()
        #expect(!selection.isBlock)
        #expect(!selection.active)
    }

    @Test func blockCapturedContentFollowsItsColumns() {
        let (terminal, selection) = makeTerminal(text: "0123456789\r\nabcdefghij")

        selection.startBlockSelection(bufferPosition: Position(col: 2, row: 0))
        selection.dragExtend(bufferPosition: Position(col: 4, row: 1))
        let snapshot = selection.captureSelectedContent()
        #expect(snapshot?.rows.map { $0.cells?.count ?? 0 } == [2, 2])

        // A change outside the block's columns keeps it.
        terminal.feed(text: "\u{1b}[1;9HZ")
        if let snapshot { selection.clearIfSelectedContentChanged(from: snapshot) }
        #expect(selection.active)

        // A change inside clears it.
        terminal.feed(text: "\u{1b}[2;4HZ")
        if let snapshot { selection.clearIfSelectedContentChanged(from: snapshot) }
        #expect(!selection.active)
    }

#if os(macOS)
    /// Both renderers take a row's selected columns from this resolver.
    @Test @MainActor func renderersDrawTheBlockColumnsOnEachRow() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        view.feed(text: "0123456789\r\nabcdefghij\r\nABCDEFGHIJ")
        view.withTerminal { _ in
            view.selection.startBlockSelection(bufferPosition: Position(col: 2, row: 0))
            view.selection.dragExtend(bufferPosition: Position(col: 5, row: 2))
        }

        let state = view.withTerminal { _ in SnapshotSelectionState(selection: view.selection) }
        #expect(state.isBlock)
        let style = SnapshotStyle(selectionActive: state.active, selectionStart: state.start,
                                  selectionEnd: state.end, selectionIsBlock: state.isBlock,
                                  linkHighlightRange: nil, linkHighlightMode: .hover,
                                  commandActive: false, textBlinkVisible: true)
        let cols = view.withTerminal { $0.cols }
        let resolver = SnapshotSelectionResolver(style: style, cols: cols)
        for row in 0...2 {
            #expect(resolver.columns(forRow: row) == 2..<5)
        }
        #expect(resolver.columns(forRow: 3) == nil)

        // The attributes the Core Graphics and Metal renderers draw from.
        for row in 0...2 {
            let line = view.withTerminal { terminal in
                view.buildAttributedStringLocked(row: row, line: terminal.displayBuffer.lines[row],
                                                 cols: terminal.cols)
            }
            var selected: [Int] = []
            for segment in line.segments {
                let text = segment.attributedString
                for offset in 0..<text.length
                where text.attribute(.selectionBackgroundColor, at: offset, effectiveRange: nil) != nil {
                    selected.append(segment.column + offset)
                }
            }
            #expect(selected == [2, 3, 4], "row \(row)")
        }
    }

    @Test @MainActor func copyingABlockFromTheViewGivesItsRows() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        view.feed(text: "name   size\r\nalpha  12\r\nbeta   345")
        view.withTerminal { _ in
            view.selection.startBlockSelection(bufferPosition: Position(col: 7, row: 0))
            view.selection.dragExtend(bufferPosition: Position(col: 11, row: 2))
        }

        #expect(view.getSelection() == "size\n12\n345")
    }
#endif
}
