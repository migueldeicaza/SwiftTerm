//
//  LineRecycleTests.swift
//
//  Covers BufferLine's `usedLength` optimisation (Docs/io-cpu-profile.md §10):
//  clearing a recycled row wipes only the cells that were actually written,
//  instead of storing blanks over the whole row.
//
//  The failure mode is stale text surviving on a recycled row, which is silent
//  in production and surfaces much later as corruption in a full-screen app.
//  BufferLine also carries a DEBUG-only assertion checking the invariant against
//  the real cells on every clear, so the whole suite audits it; these tests
//  cover the behaviour itself, since that assertion is compiled out of release.
//

import Foundation
import Testing

@testable import SwiftTerm

@Suite final class LineRecycleTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    private func makeTerminal(cols: Int = 40, rows: Int = 4, scrollback: Int = 2) -> Terminal {
        Terminal(delegate: self,
                 options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
    }

    private func row(_ terminal: Terminal, _ index: Int) -> String {
        terminal.buffer.translateBufferLineToString(lineIndex: index, trimRight: false)
    }

    /// The core hazard: a long line scrolls off, its row object is recycled for a
    /// short line, and the tail of the long line must not survive.
    @Test func recycledRowKeepsNoStaleTextFromALongerLine() {
        let terminal = makeTerminal(cols: 40, rows: 4, scrollback: 2)

        // Fill the scrollback so further output recycles rows rather than pushing.
        for _ in 0..<12 {
            terminal.feed(text: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\r\n")
        }
        // Now write short lines into those recycled rows.
        for _ in 0..<12 {
            terminal.feed(text: "bb\r\n")
        }

        let lines = terminal.buffer.lines
        for i in 0..<lines.count {
            let text = row(terminal, i)
            #expect(text.contains("A") == false,
                    "row \(i) kept stale text from a recycled longer line: \(text.debugDescription)")
        }
    }

    /// Same hazard, but the stale cells sit past the end of the new content,
    /// which is exactly the region a partial clear would skip.
    @Test func trailingCellsAreBlankAfterRecycling() {
        let terminal = makeTerminal(cols: 40, rows: 4, scrollback: 2)
        for _ in 0..<12 { terminal.feed(text: String(repeating: "X", count: 40) + "\r\n") }
        for _ in 0..<12 { terminal.feed(text: "hi\r\n") }

        for i in 0..<terminal.buffer.lines.count {
            let line = terminal.buffer.lines[i]
            for col in 2..<line.count {
                let c = line[col]
                #expect(c.code == 0 || c.code == 32,
                        "row \(i) col \(col) is not blank after recycle (code \(c.code))")
            }
        }
    }

    /// A partial clear is only valid while the blanks past the written region
    /// carry the same attribute being erased to. Changing the background colour
    /// between recycles must repaint the whole row, tail included.
    @Test func changingEraseAttributeRepaintsTheWholeRow() {
        let terminal = makeTerminal(cols: 40, rows: 4, scrollback: 2)
        for _ in 0..<12 { terminal.feed(text: "short\r\n") }

        // Switch the background, so eraseAttr() changes, then recycle more rows.
        terminal.feed(text: "\u{1b}[44m")
        for _ in 0..<12 { terminal.feed(text: "x\r\n") }

        let expected = terminal.eraseAttr()
        for i in 0..<terminal.buffer.lines.count {
            let line = terminal.buffer.lines[i]
            // Past the written text the cells must carry the *new* erase
            // attribute, not the one the row was previously cleared with.
            for col in 8..<line.count {
                #expect(line[col].attribute == expected,
                        "row \(i) col \(col) kept a stale erase attribute")
            }
        }
    }

    /// Erasing to end-of-line, then recycling, then writing a shorter line: the
    /// EL path goes through replaceCells rather than the subscript setter.
    @Test func eraseInLineThenRecycleLeavesNoResidue() {
        let terminal = makeTerminal(cols: 40, rows: 4, scrollback: 2)
        for _ in 0..<10 {
            terminal.feed(text: String(repeating: "Z", count: 30))
            terminal.feed(text: "\r\u{1b}[K")     // CR + erase to end of line
            terminal.feed(text: "keep\r\n")
        }
        for _ in 0..<10 { terminal.feed(text: "q\r\n") }

        for i in 0..<terminal.buffer.lines.count {
            let text = row(terminal, i)
            #expect(text.contains("Z") == false, "row \(i) kept erased text: \(text.debugDescription)")
        }
    }

    /// Reflow reallocates and shuffles cells; the used-length bookkeeping must
    /// not let a resize strand content that a later recycle then skips.
    @Test func resizeThenRecycleLeavesNoResidue() {
        let terminal = makeTerminal(cols: 40, rows: 6, scrollback: 4)
        for _ in 0..<20 { terminal.feed(text: String(repeating: "W", count: 38) + "\r\n") }

        terminal.resize(cols: 20, rows: 6)
        terminal.resize(cols: 60, rows: 6)

        for _ in 0..<20 { terminal.feed(text: "n\r\n") }

        for i in 0..<terminal.buffer.lines.count {
            let text = row(terminal, i)
            #expect(text.contains("W") == false,
                    "row \(i) kept text across resize + recycle: \(text.debugDescription)")
        }
    }

    @Test func emptySemanticCleanupDoesNotMutateTheLine() {
        let line = BufferLine(cols: 8)
        let generation = line.generation

        line.destroySemanticState()

        #expect(line.generation == generation)
        #expect(line.semanticMarks.isEmpty)
        #expect(line.semanticHardContinuationGroup == nil)
    }

    @Test func unchangedMetadataDoesNotMutateTheLine() {
        let line = BufferLine(cols: 8)
        let generation = line.generation

        line.isWrapped = false
        line.bidiState = .default
        line.renderMode = .single
        line.images = nil
        line.semanticHardContinuationGroup = nil

        #expect(line.generation == generation)
    }

    @Test func recycleResetsAllRowStateWithOneGenerationChange() {
        let line = BufferLine(cols: 8)
        let newBidiState = BidiPresentationState(
            supportMode: .explicit,
            autodetectDirection: false,
            fallbackDirection: .rightToLeft,
            boxMirroring: true)
        line[0] = CharData(attribute: CharData.defaultAttr, code: 65)
        line.setSemanticMark(kind: .initial, column: 0, group: 17)
        line.semanticHardContinuationGroup = 17
        line.renderMode = .doubleWidth
        let generation = line.generation
        let recycleGeneration = line.recycleGeneration

        line.recycle(with: line.pack(CharData.Null), isWrapped: true,
                     bidiState: newBidiState)

        #expect(line.generation == generation + 1)
        #expect(line.recycleGeneration == recycleGeneration + 1)
        #expect(line[0].code == 0)
        #expect(line.semanticMarks.isEmpty)
        #expect(line.semanticHardContinuationGroup == nil)
        #expect(line.isWrapped)
        #expect(line.bidiState == newBidiState)
        #expect(line.renderMode == .single)
    }
}
