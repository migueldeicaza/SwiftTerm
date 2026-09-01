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
    private struct TestImage: TerminalImage {
        var pixelWidth = 1
        var pixelHeight = 1
        var col = 0
    }

    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    private func makeTerminal(cols: Int = 40, rows: Int = 4, scrollback: Int = 2) -> Terminal {
        Terminal(delegate: self,
                 options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
    }

    private func row(_ terminal: Terminal, _ index: Int) -> String {
        terminal.buffer.translateBufferLineToString(lineIndex: index, trimRight: false)
    }

    private func makeFullBuffer() -> (buffer: Buffer, clearCell: PackedCell) {
        let buffer = Buffer(cols: 8, rows: 4, tabStopWidth: 8, scrollback: 2)
        buffer.fillViewportRows()
        let clearCell = buffer.getPackedBlankCell(attribute: CharData.defaultAttr)
        while !buffer.lines.isFull {
            buffer.lines.push(buffer.getBlankLine(packedBlank: clearCell))
        }
        return (buffer, clearCell)
    }

    private func rotateStartIndexToLastSlot(_ buffer: Buffer, clearCell: PackedCell) {
        for _ in 0..<(buffer.lines.maxLength - 1) {
            buffer.lines.recycle(clearCell: clearCell, isWrapped: false,
                                 bidiState: .default)
        }
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

    @Test func partialRotationReusesTopLineAndResetsItsState() {
        let buffer = Buffer(cols: 8, rows: 4, tabStopWidth: 8, scrollback: 2)
        buffer.fillViewportRows()
        let clearCell = buffer.getPackedBlankCell(attribute: CharData.defaultAttr)
        buffer.lines.push(buffer.getBlankLine(packedBlank: clearCell))
        buffer.lines.push(buffer.getBlankLine(packedBlank: clearCell))
        buffer.lines.recycle(clearCell: clearCell, isWrapped: false,
                             bidiState: .default)

        let lines = buffer.lines
        for index in 0..<lines.count {
            lines[index][0] = CharData(attribute: CharData.defaultAttr,
                                       code: Int32(65 + index))
        }
        let originalLines = (0..<lines.count).map { lines[$0] }
        let originalGenerations = originalLines.map(\.generation)
        let originalStartIndex = lines.getStartIndex()
        let recycledLine = originalLines[1]
        recycledLine[1] = CharData(attribute: CharData.defaultAttr, code: 90)
        recycledLine.setSemanticMark(kind: .initial, column: 1, group: 17)
        recycledLine.semanticHardContinuationGroup = 17
        recycledLine.renderMode = .doubleWidth
        buffer.attachImage(TestImage(), toLineAt: 1)
        let generation = recycledLine.generation
        let recycleGeneration = recycledLine.recycleGeneration
        let newBidiState = BidiPresentationState(
            supportMode: .explicit,
            autodetectDirection: false,
            fallbackDirection: .rightToLeft,
            boxMirroring: true)

        let result = lines.shiftUpAndRecycle(top: 1, bottom: 4,
                                             clearCell: clearCell,
                                             isWrapped: true,
                                             bidiState: newBidiState)

        #expect(result)
        #expect(lines.getStartIndex() == originalStartIndex)
        #expect(lines.count == originalLines.count)
        #expect(lines[0] === originalLines[0])
        #expect(lines[1] === originalLines[2])
        #expect(lines[2] === originalLines[3])
        #expect(lines[3] === originalLines[4])
        #expect(lines[4] === recycledLine)
        #expect(lines[5] === originalLines[5])
        for column in 0..<recycledLine.count {
            #expect(recycledLine.packedCell(at: column) == clearCell)
        }
        #expect(recycledLine.images == nil)
        #expect(recycledLine.semanticMarks.isEmpty)
        #expect(recycledLine.semanticHardContinuationGroup == nil)
        #expect(recycledLine.isWrapped)
        #expect(recycledLine.bidiState == newBidiState)
        #expect(recycledLine.renderMode == .single)
        #expect(recycledLine.owningBuffer === buffer)
        #expect(buffer.hasAnyImages == false)
        #expect(recycledLine.generation == generation + 1)
        #expect(recycledLine.recycleGeneration == recycleGeneration + 1)
        for index in 0..<originalLines.count where index != 1 {
            #expect(originalLines[index].generation == originalGenerations[index])
            #expect(originalLines[index].owningBuffer === buffer)
        }
    }

    @Test func fullRingRecycleAtZeroRotatesIdentityAndResetsState() {
        let (buffer, clearCell) = makeFullBuffer()
        let lines = buffer.lines
        let originalLines = (0..<lines.count).map { lines[$0] }
        let recycledLine = originalLines[0]
        recycledLine[0] = CharData(attribute: CharData.defaultAttr, code: 65)
        recycledLine[1] = CharData(attribute: CharData.defaultAttr, code: 90)
        recycledLine.setSemanticMark(kind: .initial, column: 1, group: 17)
        recycledLine.semanticHardContinuationGroup = 17
        recycledLine.renderMode = .doubleWidth
        buffer.attachImage(TestImage(), toLineAt: 0)
        let generation = recycledLine.generation
        let recycleGeneration = recycledLine.recycleGeneration
        let newBidiState = BidiPresentationState(
            supportMode: .explicit,
            autodetectDirection: false,
            fallbackDirection: .rightToLeft,
            boxMirroring: true)

        lines.recycle(clearCell: clearCell, isWrapped: true,
                      bidiState: newBidiState)

        #expect(lines.getStartIndex() == 1)
        for index in 0..<(lines.count - 1) {
            #expect(lines[index] === originalLines[index + 1])
        }
        #expect(lines[lines.count - 1] === recycledLine)
        for column in 0..<recycledLine.count {
            #expect(recycledLine.packedCell(at: column) == clearCell)
        }
        #expect(recycledLine.images == nil)
        #expect(recycledLine.semanticMarks.isEmpty)
        #expect(recycledLine.semanticHardContinuationGroup == nil)
        #expect(recycledLine.isWrapped)
        #expect(recycledLine.bidiState == newBidiState)
        #expect(recycledLine.renderMode == .single)
        #expect(recycledLine.generation == generation + 1)
        #expect(recycledLine.recycleGeneration == recycleGeneration + 1)
        #expect(recycledLine.owningBuffer === buffer)
        #expect(buffer.hasAnyImages == false)
    }

    @Test func fullRingRecycleWrapsStartIndexAtCapacity() {
        let (buffer, clearCell) = makeFullBuffer()
        let lines = buffer.lines
        rotateStartIndexToLastSlot(buffer, clearCell: clearCell)
        #expect(lines.getStartIndex() == lines.maxLength - 1)
        let originalLines = (0..<lines.count).map { lines[$0] }

        lines.recycle(clearCell: clearCell, isWrapped: false,
                      bidiState: .default)

        #expect(lines.getStartIndex() == 0)
        for index in 0..<(lines.count - 1) {
            #expect(lines[index] === originalLines[index + 1])
        }
        #expect(lines[lines.count - 1] === originalLines[0])
    }

    @Test func repeatedFullRingRecyclePreservesLogicalOrderAcrossWraps() {
        let (buffer, clearCell) = makeFullBuffer()
        let lines = buffer.lines
        var expectedCodes = (0..<lines.count).map { Int32(65 + $0) }
        for index in 0..<lines.count {
            lines[index][0] = CharData(attribute: CharData.defaultAttr,
                                       code: expectedCodes[index])
        }

        for rotation in 0..<(2 * lines.maxLength + 1) {
            lines.recycle(clearCell: clearCell, isWrapped: false,
                          bidiState: .default)
            let newCode = Int32(71 + rotation)
            lines[lines.count - 1][0] = CharData(attribute: CharData.defaultAttr,
                                                 code: newCode)
            expectedCodes.removeFirst()
            expectedCodes.append(newCode)

            #expect((0..<lines.count).map { lines[$0][0].code } == expectedCodes)
            #expect(lines.getStartIndex() < lines.maxLength)
        }
    }

    @Test func spliceNormalizesStartIndexBeforeSubsequentRecycle() {
        let (buffer, clearCell) = makeFullBuffer()
        let lines = buffer.lines
        rotateStartIndexToLastSlot(buffer, clearCell: clearCell)
        let inserted = buffer.getBlankLine(packedBlank: clearCell)

        lines.splice(start: lines.count, deleteCount: 0, items: [inserted],
                     change: { _ in })

        #expect(lines.getStartIndex() < lines.maxLength)
        #expect(lines.isFull)
        let oldest = lines[0]
        lines.recycle(clearCell: clearCell, isWrapped: false,
                      bidiState: .default)
        #expect(lines[lines.count - 1] === oldest)
    }

    @Test func trimStartNormalizesStartIndexBeforeSubsequentRecycle() {
        let (buffer, clearCell) = makeFullBuffer()
        let lines = buffer.lines
        rotateStartIndexToLastSlot(buffer, clearCell: clearCell)

        lines.trimStart(count: 2)

        #expect(lines.getStartIndex() < lines.maxLength)
        while !lines.isFull {
            lines.push(buffer.getBlankLine(packedBlank: clearCell))
        }
        let oldest = lines[0]
        lines.recycle(clearCell: clearCell, isWrapped: false,
                      bidiState: .default)
        #expect(lines[lines.count - 1] === oldest)
    }

    @Test func shiftElementsNormalizesStartIndexBeforeSubsequentRecycle() {
        let (buffer, clearCell) = makeFullBuffer()
        let lines = buffer.lines
        rotateStartIndexToLastSlot(buffer, clearCell: clearCell)

        let shifted = lines.shiftElements(start: 1, count: lines.count - 1,
                                          offset: 1)

        #expect(shifted)
        #expect(lines.getStartIndex() < lines.maxLength)
        #expect(lines.isFull)
        let oldest = lines[0]
        lines.recycle(clearCell: clearCell, isWrapped: false,
                      bidiState: .default)
        #expect(lines[lines.count - 1] === oldest)
    }

    @Test func terminalFullScreenScrollingKeepsTheNewestRingContents() {
        let terminal = makeTerminal(cols: 40, rows: 4, scrollback: 2)
        let lineCount = 20
        for index in 0..<lineCount {
            terminal.feed(text: "line-\(index)\r\n")
        }

        let lines = terminal.buffer.lines
        let firstExpectedLine = lineCount - lines.maxLength + 1
        let expected = (firstExpectedLine..<lineCount).map { "line-\($0)" } + [""]
        let actual = (0..<lines.count).map {
            terminal.buffer.translateBufferLineToString(lineIndex: $0, trimRight: true)
        }

        #expect(actual == expected)
    }

    @Test func terminalPartialScrollRotatesLineIdentity() {
        let terminal = makeTerminal(cols: 8, rows: 5, scrollback: 2)
        terminal.feed(text: "\u{1b}[2;4r")
        let lines = terminal.buffer.lines
        let originalLines = (0..<lines.count).map { lines[$0] }
        let recycledLine = originalLines[1]
        let generation = recycledLine.generation
        let recycleGeneration = recycledLine.recycleGeneration
        let bidiState = BidiPresentationState(supportMode: .explicit,
                                               autodetectDirection: false,
                                               fallbackDirection: .rightToLeft)
        originalLines[3].bidiState = bidiState

        terminal.scroll(isWrapped: true)

        #expect(lines[0] === originalLines[0])
        #expect(lines[1] === originalLines[2])
        #expect(lines[2] === originalLines[3])
        #expect(lines[3] === recycledLine)
        #expect(lines[4] === originalLines[4])
        #expect(recycledLine.isWrapped)
        #expect(recycledLine.bidiState == bidiState)
        #expect(recycledLine.generation == generation + 1)
        #expect(recycledLine.recycleGeneration == recycleGeneration + 1)
    }

    @Test func topAnchoredPartialScrollWithoutHistoryRotatesLineIdentity() {
        let terminal = makeTerminal(cols: 8, rows: 5, scrollback: 2)
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[1;4r")
        let buffer = terminal.buffer
        let lines = buffer.lines
        let originalLines = (0..<lines.count).map { lines[$0] }
        let recycledLine = originalLines[0]
        let originalGeneration = recycledLine.generation
        let originalRecycleGeneration = recycledLine.recycleGeneration
        let originalCount = lines.count
        let originalYBase = buffer.yBase
        let originalYDisp = buffer.yDisp
        let originalLinesTop = buffer.linesTop

        terminal.clearUpdateRange()
        terminal.scroll(isWrapped: true)

        #expect(lines.count == originalCount)
        #expect(buffer.yBase == originalYBase)
        #expect(buffer.yDisp == originalYDisp)
        #expect(buffer.linesTop == originalLinesTop)
        #expect(lines[0] === originalLines[1])
        #expect(lines[1] === originalLines[2])
        #expect(lines[2] === originalLines[3])
        #expect(lines[3] === recycledLine)
        #expect(lines[4] === originalLines[4])
        #expect(recycledLine.isWrapped)
        #expect(recycledLine.generation == originalGeneration + 1)
        #expect(recycledLine.recycleGeneration == originalRecycleGeneration + 1)
        #expect(terminal.getUpdateRange()?.startY == 0)
        #expect(terminal.getUpdateRange()?.endY == 3)
    }

    @Test func topAnchoredPartialScrollPreservesNormalBufferHistory() {
        let terminal = makeTerminal(cols: 8, rows: 5, scrollback: 2)
        let buffer = terminal.buffer
        for row in 0..<buffer.lines.count {
            buffer.lines[row][0] = CharData(attribute: CharData.defaultAttr,
                                             code: Int32(65 + row))
        }
        let firstLine = buffer.lines[0]
        terminal.feed(text: "\u{1b}[1;4r")

        terminal.scroll()

        #expect(buffer.lines.count == 6)
        #expect(buffer.yBase == 1)
        #expect(buffer.yDisp == 1)
        #expect(buffer.linesTop == 0)
        #expect(buffer.lines[0] === firstLine)
        #expect(row(terminal, 0).first == "A")

        terminal.scroll()
        terminal.scroll()

        #expect(buffer.lines.count == 7)
        #expect(buffer.yBase == 2)
        #expect(buffer.yDisp == 2)
        #expect(buffer.linesTop == 1)
        #expect(row(terminal, 0).first == "B")
        #expect(row(terminal, 1).first == "C")
    }

    @Test func fullScreenScrollbackStillAppendsALine() {
        let terminal = makeTerminal(cols: 8, rows: 3, scrollback: 2)
        let lines = terminal.buffer.lines
        let originalLines = (0..<lines.count).map { lines[$0] }
        let topGeneration = originalLines[0].generation

        terminal.scroll()

        #expect(lines.count == 4)
        #expect(terminal.buffer.yBase == 1)
        #expect(lines[0] === originalLines[0])
        #expect(lines[1] === originalLines[1])
        #expect(lines[2] === originalLines[2])
        #expect(lines[3] !== originalLines[0])
        #expect(originalLines[0].generation == topGeneration)
    }

    @Test func narrowMarginScrollKeepsLineIdentity() {
        let terminal = makeTerminal(cols: 6, rows: 4, scrollback: 0)
        terminal.feed(text: "\u{1b}[?69h\u{1b}[2;5s")
        let lines = terminal.buffer.lines
        let originalLines = (0..<lines.count).map { lines[$0] }
        for row in 0..<lines.count {
            for column in 0..<lines[row].count {
                lines[row][column] = CharData(attribute: CharData.defaultAttr,
                                              code: Int32(65 + row))
            }
        }

        terminal.scroll()

        for row in 0..<lines.count {
            #expect(lines[row] === originalLines[row])
        }
        #expect(row(terminal, 0) == "ABBBBA")
        #expect(row(terminal, 1) == "BCCCCB")
        #expect(row(terminal, 2) == "CDDDDC")
        #expect(lines[3][0].code == 68)
        #expect(lines[3][5].code == 68)
        for column in 1...4 {
            #expect(lines[3][column].code == 0)
        }
    }
}
