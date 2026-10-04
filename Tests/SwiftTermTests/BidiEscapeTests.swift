//
//  BidiEscapeTests.swift
//
//  Terminal-wg BiDi escape sequences: BDSM, SCP, and DEC private modes.
//  https://terminal-wg.pages.freedesktop.org/bidi/
//
import Foundation
import Testing

@testable import SwiftTerm

final class BidiEscapeTests: TerminalDelegate {
    var sent: [UInt8] = []
    var hostSwapsArrowKeys = true

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        sent.append(contentsOf: data)
    }

    func supportsBidiArrowKeySwap(source: Terminal) -> Bool {
        hostSwapsArrowKeys
    }

    var sentString: String {
        String(decoding: sent, as: UTF8.self)
    }

    func makeTerminal() -> Terminal {
        Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))
    }

    @Test func defaultsMatchTheAppBehavior() {
        let terminal = makeTerminal()
        #expect(terminal.bidiSupportEnabled, "implicit BDSM by default")
        #expect(terminal.bidiAutodetectDirection, "autodetect on by default (RTL-first app policy)")
        #expect(!terminal.bidiRTLPreference, "SPD default direction is LTR")
        #expect(!terminal.bidiBoxMirroring, "box mirroring off by default")
        #expect(terminal.bidiArrowKeySwap, "arrow swapping is on by default")
        #expect(terminal.currentBidiState.presentationMode == .implicitAutoLeftToRight)
    }

    @Test func presentationStateRepresentsAllSixModes() {
        var state = BidiPresentationState()
        #expect(state.presentationMode == .implicitAutoLeftToRight)
        state.fallbackDirection = .rightToLeft
        #expect(state.presentationMode == .implicitAutoRightToLeft)
        state.autodetectDirection = false
        #expect(state.presentationMode == .implicitRightToLeft)
        state.fallbackDirection = .leftToRight
        #expect(state.presentationMode == .implicitLeftToRight)
        state.supportMode = .explicit
        #expect(state.presentationMode == .explicitLeftToRight)
        state.fallbackDirection = .rightToLeft
        #expect(state.presentationMode == .explicitRightToLeft)
    }

    @Test func bdsmTogglesImplicitBidi() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[8l")
        #expect(!terminal.bidiSupportEnabled, "RM 8 selects explicit mode (app-side BiDi)")
        terminal.feed(text: "\u{1b}[8h")
        #expect(terminal.bidiSupportEnabled, "SM 8 selects implicit mode")
    }

    @Test func spdSelectsPresentationDirection() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[3 S")
        #expect(terminal.bidiRTLPreference, "SPD 3 selects RTL")
        terminal.feed(text: "\u{1b}[0 S")
        #expect(!terminal.bidiRTLPreference, "SPD 0 selects LTR")
        terminal.feed(text: "\u{1b}[3 S")
        terminal.feed(text: "\u{1b}[ S")
        #expect(!terminal.bidiRTLPreference, "SPD with no parameter defaults to 0 (LTR)")
    }

    @Test func scpSelectsTheSpecifiedCharacterPath() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[2 k")
        #expect(terminal.currentBidiState.fallbackDirection == .rightToLeft)
        terminal.feed(text: "\u{1b}[1 k")
        #expect(terminal.currentBidiState.fallbackDirection == .leftToRight)
        terminal.feed(text: "\u{1b}[2 k\u{1b}[0 k")
        #expect(terminal.currentBidiState.fallbackDirection == .leftToRight)
    }

    @Test func spdIgnoresUnsupportedDirections() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[3 S")
        terminal.feed(text: "\u{1b}[1 S")
        #expect(terminal.bidiRTLPreference, "vertical directions (1, 2) are ignored")
        terminal.feed(text: "\u{1b}[7 S")
        #expect(terminal.bidiRTLPreference)
    }

    @Test func spdDoesNotSwallowScrollUp() {
        let terminal = makeTerminal()
        terminal.feed(text: "hello\r\nworld")
        // Plain CSI 2 S (no space intermediate) must still scroll, not hit SPD.
        terminal.feed(text: "\u{1b}[2S")
        #expect(!terminal.bidiRTLPreference)
        let firstRow = terminal.getLine(row: 0)?.translateToString(trimRight: true)
        #expect(firstRow == "", "content scrolled away by CSI 2 S")
    }

    @Test func decModesToggleAutodetectAndBoxMirroring() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[?2501l")
        #expect(!terminal.bidiAutodetectDirection)
        terminal.feed(text: "\u{1b}[?2501h")
        #expect(terminal.bidiAutodetectDirection)
        terminal.feed(text: "\u{1b}[?2500h")
        #expect(terminal.bidiBoxMirroring)
        terminal.feed(text: "\u{1b}[?2500l")
        #expect(!terminal.bidiBoxMirroring)
    }

    @Test func paragraphKeepsTheStateFromItsFirstOutput() throws {
        let terminal = makeTerminal()
        terminal.feed(text: "old")
        let first = try #require(terminal.getLine(row: 0))
        #expect(first.bidiState.presentationMode == .implicitAutoLeftToRight)

        terminal.feed(text: "\u{1b}[8l")
        #expect(first.bidiState.presentationMode == .implicitAutoLeftToRight)
        terminal.feed(text: "\r\nnew")
        let second = try #require(terminal.getLine(row: 1))
        #expect(second.bidiState.presentationMode == .explicitLeftToRight)

        terminal.feed(text: "\u{1b}[8h")
        #expect(second.bidiState.presentationMode == .explicitLeftToRight)
        terminal.feed(text: "\r\nnext")
        let third = try #require(terminal.getLine(row: 2))
        #expect(third.bidiState.presentationMode == .implicitAutoLeftToRight)
    }

    @Test func lineFeedSetsTheStateOfTheCompleteDestinationParagraph() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 4, rows: 6))
        terminal.feed(text: "x\r\nאבגדאב\r\nz")
        let contents = (0..<4).map { terminal.buffer.lines[$0].translateToString() }
        terminal.feed(text: "\u{1b}[1;2H\u{1b}[8l\n")

        #expect(terminal.buffer.lines[0].bidiState == .default)
        for row in 1...2 {
            #expect(terminal.buffer.lines[row].bidiState == terminal.currentBidiState)
        }
        #expect(terminal.buffer.lines[2].isWrapped)
        #expect(terminal.buffer.lines[3].bidiState == .default)
        #expect((0..<4).map { terminal.buffer.lines[$0].translateToString() } == contents)
    }

    @Test func lineFeedWithinAParagraphPreservesItsState() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 4, rows: 6))
        terminal.feed(text: "אבגדאבגדאב")
        terminal.feed(text: "\u{1b}[1;2H\u{1b}[8l\n")

        #expect(terminal.currentBidiState.supportMode == .explicit)
        for row in 0...2 {
            #expect(terminal.buffer.lines[row].bidiState == .default)
        }
    }

    @Test(arguments: ["asciiSlice", "asciiSpan", "scalarRun", "singleCell", "insertMode"])
    func wrapSetsTheStateOfTheCompleteJoinedParagraph(path: String) {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 4, rows: 6))
        terminal.feed(text: "x\r\nאבגדאב\r\nz")
        terminal.feed(text: "\u{1b}[1;1H\u{1b}[8l")
        let continuation = terminal.buffer.lines[2].translateToString()
        let unrelated = terminal.buffer.lines[3].translateToString()
        let bytes = Array("abcde".utf8)
        switch path {
        case "asciiSlice":
            #expect(terminal.buffer.insertAsciiRun(bytes[...], styleID: 0, payloadCode: 0) == 5)
        case "asciiSpan":
            let slice = bytes[...]
            let inserted = terminal.buffer.insertAsciiRun(slice.span, styleID: 0, payloadCode: 0)
            #expect(inserted == 5)
        case "scalarRun":
            let scalars = bytes.map(UInt32.init)
            scalars.withUnsafeBufferPointer {
                #expect(terminal.buffer.insertScalarRun($0, width: 1, styleID: 0, payloadCode: 0) == 5)
            }
        case "singleCell":
            for byte in bytes {
                let cell = terminal.buffer.cellArena.pack(styleID: 0, scalar: UInt32(byte),
                                                          widthState: .narrow)!
                terminal.buffer.insertCharacter(cell)
            }
        default:
            terminal.feed(text: "\u{1b}[4habcde")
        }

        for row in 0...2 {
            #expect(terminal.buffer.lines[row].bidiState == terminal.currentBidiState)
        }
        #expect(terminal.buffer.lines[1].isWrapped)
        #expect(terminal.buffer.lines[2].isWrapped)
        #expect(terminal.buffer.lines[2].translateToString() == continuation)
        #expect(terminal.buffer.lines[3].translateToString() == unrelated)
        #expect(terminal.buffer.lines[3].bidiState == .default)
    }

    @Test(arguments: [false, true])
    func lineFeedScrollSeparatesContinuationRowsBelowTheRegion(generalPath: Bool) {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 4, rows: 6))
        terminal.feed(text: "x\r\nאבגדאבגדאב\r\nz")
        let continuation = (2...3).map { terminal.buffer.lines[$0].translateToString() }
        // A region at row zero uses the scrollback insertion path. A region
        // at row one uses the in-place scroll path.
        terminal.buffer.scrollTop = generalPath ? 0 : 1
        terminal.buffer.scrollBottom = 1
        terminal.feed(text: "\u{1b}[2;2H\u{1b}[8l\n")

        let base = terminal.buffer.yBase
        #expect(terminal.buffer.lines[base + 1].bidiState == terminal.currentBidiState)
        // The rows below the region keep their state and start a new paragraph,
        // as they do after RI, SU and SD.
        #expect(!terminal.buffer.lines[base + 2].isWrapped)
        #expect(terminal.buffer.lines[base + 3].isWrapped)
        for row in 2...3 {
            #expect(terminal.buffer.lines[base + row].bidiState == .default)
        }
        #expect((2...3).map { terminal.buffer.lines[base + $0].translateToString() } == continuation)
        #expect(terminal.buffer.lines[base + 4].bidiState == .default)
        #expect(terminal.buffer.lines[base + 4].translateToString(trimRight: true) == "z")
    }

    @Test(arguments: [false, true])
    func wrapScrollKeepsTheSourceParagraphState(generalPath: Bool) {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 4, rows: 6))
        terminal.feed(text: "אבגדאבגדאבגדאב\r\nz")
        let continuation = (2...3).map { terminal.buffer.lines[$0].translateToString() }
        terminal.buffer.scrollTop = generalPath ? 0 : 1
        terminal.buffer.scrollBottom = 1
        terminal.feed(text: "\u{1b}[2;4H\u{1b}[8lxy")

        let base = terminal.buffer.yBase
        #expect(terminal.currentBidiState.supportMode == .explicit)
        for row in 0...3 {
            #expect(terminal.buffer.lines[base + row].bidiState == .default)
        }
        #expect(terminal.buffer.lines[base + 1].isWrapped)
        #expect((2...3).map { terminal.buffer.lines[base + $0].translateToString() } == continuation)
        #expect(terminal.buffer.lines[base + 4].translateToString(trimRight: true) == "z")
    }

    @Test(arguments: [false, true])
    func regionLineFeedDoesNotJoinTheFirstMovedRowToAnEarlierParagraph(generalPath: Bool) {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 4, rows: 8))
        terminal.feed(text: "p\r\nq\r\nאבגדאבגדאב")
        terminal.feed(text: "\u{1b}[2;1H\u{1b}[8l")
        let earlierState = terminal.buffer.lines[1].bidiState
        let earlierContent = terminal.buffer.lines[1].translateToString()
        let movedContent = (3...4).map { terminal.buffer.lines[$0].translateToString() }
        terminal.buffer.scrollTop = 2
        terminal.buffer.scrollBottom = 4
        if generalPath {
            // Full-width horizontal margins select the general scroll worker.
            terminal.feed(text: "\u{1b}[?69h")
        }
        terminal.feed(text: "\u{1b}[5;2H\n")

        #expect(terminal.buffer.lines[1].bidiState == earlierState)
        #expect(terminal.buffer.lines[1].translateToString() == earlierContent)
        #expect(!terminal.buffer.lines[2].isWrapped)
        #expect(terminal.buffer.lines[3].isWrapped)
        #expect((2...3).map { terminal.buffer.lines[$0].translateToString() } == movedContent)
        #expect(terminal.buffer.lines[2].bidiState == .default)
        #expect(terminal.buffer.lines[3].bidiState == .default)

        // The destination already has the current state. Its unchanged-state
        // fast path must leave the separate moved paragraph unchanged.
        terminal.feed(text: "\u{1b}[1;2H\n")
        #expect(terminal.buffer.lines[1].bidiState == earlierState)
        #expect(terminal.buffer.lines[2].bidiState == .default)
        #expect(terminal.buffer.lines[3].bidiState == .default)
    }

    @Test func reverseIndexSeparatesTheInsertedRowFromMovedContinuations() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 4, rows: 8))
        terminal.feed(text: "p\r\nאבגדאבגדאבגדאבגדאב")
        let movedContent = terminal.buffer.lines[2].translateToString()
        let outsideContent = terminal.buffer.lines[4].translateToString()
        terminal.buffer.scrollTop = 2
        terminal.buffer.scrollBottom = 3
        terminal.feed(text: "\u{1b}[3;2H\u{1b}[8l\u{1b}M")

        #expect(terminal.buffer.lines[2].bidiState == terminal.currentBidiState)
        #expect(!terminal.buffer.lines[2].isWrapped)
        #expect(terminal.buffer.lines[3].bidiState == .default)
        #expect(!terminal.buffer.lines[3].isWrapped)
        #expect(terminal.buffer.lines[3].translateToString() == movedContent)
        #expect(!terminal.buffer.lines[4].isWrapped)
        #expect(terminal.buffer.lines[4].translateToString() == outsideContent)

        terminal.feed(text: "\u{1b}[2;2H\n")
        #expect(terminal.buffer.lines[2].bidiState == terminal.currentBidiState)
        #expect(terminal.buffer.lines[3].bidiState == .default)
    }

    @Test func reverseIndexInOneRowRegionPreservesTheOutsideRows() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 4, rows: 6))
        terminal.feed(text: "p\r\nאבגדאבגדאב")
        let above = terminal.buffer.lines[1].translateToString()
        let below = terminal.buffer.lines[3].translateToString()
        terminal.buffer.scrollTop = 2
        terminal.buffer.scrollBottom = 2
        terminal.feed(text: "\u{1b}[3;2H\u{1b}[8l\u{1b}M")

        #expect(terminal.buffer.lines[1].translateToString() == above)
        #expect(terminal.buffer.lines[1].bidiState == .default)
        #expect(terminal.buffer.lines[2].translateToString(trimRight: true) == "")
        #expect(terminal.buffer.lines[2].bidiState == terminal.currentBidiState)
        #expect(!terminal.buffer.lines[2].isWrapped)
        #expect(terminal.buffer.lines[3].translateToString() == below)
        #expect(terminal.buffer.lines[3].bidiState == .default)
        #expect(!terminal.buffer.lines[3].isWrapped)
    }

    @Test func reinforcedModeAppliesOnlyItsPropertyAtParagraphStart() throws {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[?2500hx")
        let line = try #require(terminal.getLine(row: 0))
        #expect(line.bidiState.boxMirroring)
        #expect(line.bidiState.autodetectDirection)

        terminal.feed(text: "\u{1b}[?2500l\u{1b}[?2501l")
        #expect(line.bidiState.boxMirroring)
        #expect(line.bidiState.autodetectDirection)

        terminal.feed(text: "\r\u{1b}[?2500l")
        #expect(!line.bidiState.boxMirroring)
        #expect(line.bidiState.autodetectDirection)
    }

    @Test func eraseDisplayGivesClearedRowsTheCurrentState() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[2 k")
        terminal.buffer.y = 1
        terminal.buffer.x = 1
        for row in 0..<terminal.rows {
            terminal.buffer.lines[row].bidiState = .default
            terminal.buffer.lines[row].isWrapped = true
        }

        terminal.feed(text: "\u{1b}[0J")
        #expect(terminal.buffer.lines[1].bidiState == .default)
        for row in 2..<terminal.rows {
            #expect(terminal.buffer.lines[row].bidiState.fallbackDirection == .rightToLeft)
            #expect(!terminal.buffer.lines[row].isWrapped)
        }
    }

    @Test func eraseDisplayUsesTheViewportOffsetForTheNextRow() {
        let options = TerminalOptions(cols: 5, rows: 3, scrollback: 20)
        let terminal = Terminal(delegate: self, options: options)
        terminal.feed(text: "0\n1\n2\n3\n4")
        #expect(terminal.buffer.yBase > 0)

        terminal.buffer.y = 1
        terminal.buffer.x = terminal.cols - 1
        let nextAbsoluteRow = terminal.buffer.yBase + terminal.buffer.y + 1
        terminal.buffer.lines[nextAbsoluteRow].isWrapped = true

        terminal.feed(text: "\u{1b}[1J")
        #expect(!terminal.buffer.lines[nextAbsoluteRow].isWrapped)
    }

    @Test func deleteCharactersPreservesWrappedParagraphAndState() {
        let terminal = makeTerminal()
        let oldState = BidiPresentationState(supportMode: .explicit,
                                             autodetectDirection: false,
                                             fallbackDirection: .rightToLeft,
                                             boxMirroring: true)
        terminal.buffer.lines[0].bidiState = oldState
        terminal.buffer.lines[1].bidiState = oldState
        terminal.buffer.lines[1].isWrapped = true
        terminal.buffer.y = 0
        terminal.buffer.x = 1
        terminal.feed(text: "\u{1b}[P")
        #expect(terminal.buffer.lines[1].isWrapped)
        #expect(terminal.buffer.lines[0].bidiState == oldState)
        #expect(terminal.buffer.lines[1].bidiState == oldState)
    }

    @Test func eraseInLinePreservesWrappedParagraphBoundaries() {
        let eraseRight = Terminal(delegate: self, options: TerminalOptions(cols: 5, rows: 3))
        eraseRight.feed(text: "abcdef")
        eraseRight.feed(text: "\u{1b}[1;3H\u{1b}[K")
        #expect(eraseRight.buffer.lines[1].isWrapped)

        let eraseLeft = Terminal(delegate: self, options: TerminalOptions(cols: 5, rows: 3))
        eraseLeft.feed(text: "abcdef")
        eraseLeft.feed(text: "\u{1b}[2;1H\u{1b}[1K")
        #expect(eraseLeft.buffer.lines[1].isWrapped)

        let eraseAll = Terminal(delegate: self, options: TerminalOptions(cols: 5, rows: 3))
        eraseAll.feed(text: "abcdefghijk")
        eraseAll.feed(text: "\u{1b}[2;1H\u{1b}[2K")
        #expect(eraseAll.buffer.lines[1].isWrapped)
        #expect(eraseAll.buffer.lines[2].isWrapped)
    }

    @Test func scrollUpMovesStateAndUsesCurrentStateForNewRows() {
        let terminal = makeTerminal()
        let movedState = BidiPresentationState(supportMode: .explicit,
                                               autodetectDirection: false,
                                               fallbackDirection: .rightToLeft)
        terminal.buffer.lines[1].bidiState = movedState
        terminal.feed(text: "\u{1b}[2 k")
        terminal.buffer.x = 1
        terminal.feed(text: "\u{1b}[S")
        #expect(terminal.buffer.lines[0].bidiState == movedState)
        #expect(terminal.buffer.lines[terminal.rows - 1].bidiState.fallbackDirection == .rightToLeft)
        #expect(!terminal.buffer.lines[0].isWrapped)
        #expect(!terminal.buffer.lines[terminal.rows - 1].isWrapped)
    }

    @Test func scrollDownMultipleLinesBreaksTheMovedParagraphBoundary() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 5, rows: 5))
        let oldState = BidiPresentationState(supportMode: .explicit,
                                             autodetectDirection: false,
                                             fallbackDirection: .rightToLeft)
        terminal.buffer.lines[0].bidiState = oldState
        terminal.buffer.lines[0].isWrapped = true

        terminal.feed(text: "\u{1b}[2T")

        #expect(!terminal.buffer.lines[2].isWrapped)
        #expect(terminal.buffer.lines[2].bidiState == oldState)
    }

    @Test func insertLinesBreaksTheFirstShiftedParagraphBoundary() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 5, rows: 5))
        let oldState = BidiPresentationState(supportMode: .explicit,
                                             autodetectDirection: false,
                                             fallbackDirection: .rightToLeft)
        terminal.buffer.lines[1].bidiState = oldState
        terminal.buffer.lines[1].isWrapped = true
        terminal.buffer.y = 1

        terminal.feed(text: "\u{1b}[2L")

        #expect(!terminal.buffer.lines[3].isWrapped)
        #expect(terminal.buffer.lines[3].bidiState == oldState)
    }

    @Test func deleteLinesBreaksTheFirstShiftedParagraphBoundary() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 5, rows: 5))
        let oldState = BidiPresentationState(supportMode: .explicit,
                                             autodetectDirection: false,
                                             fallbackDirection: .rightToLeft)
        terminal.buffer.lines[3].bidiState = oldState
        terminal.buffer.lines[3].isWrapped = true
        terminal.buffer.y = 1

        terminal.feed(text: "\u{1b}[2M")

        #expect(!terminal.buffer.lines[1].isWrapped)
        #expect(terminal.buffer.lines[1].bidiState == oldState)
    }

    @Test func privateModesSaveRestoreAndReportArrowSwapping() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[?2500h\u{1b}[?2501l\u{1b}[?1243l")
        terminal.feed(text: "\u{1b}[?2500;2501;1243s")
        terminal.feed(text: "\u{1b}[?2500l\u{1b}[?2501h\u{1b}[?1243h")
        terminal.feed(text: "\u{1b}[?2500;2501;1243r")
        #expect(terminal.bidiBoxMirroring)
        #expect(!terminal.bidiAutodetectDirection)
        #expect(!terminal.bidiArrowKeySwap)

        sent.removeAll()
        terminal.feed(text: "\u{1b}[?1243$p")
        #expect(sentString == "\u{1b}[?1243;2$y")
    }

    @Test func hostCanChangeArrowSwappingAtRuntime() {
        let terminal = makeTerminal()
        #expect(terminal.bidiArrowKeySwap)

        terminal.bidiArrowKeySwap = false
        #expect(!terminal.bidiArrowKeySwap)

        terminal.bidiArrowKeySwap = true
        #expect(terminal.bidiArrowKeySwap)
    }

    @Test func softResetRestoresConfiguredBidiDefaults() {
        let initial = BidiPresentationState(supportMode: .explicit,
                                            autodetectDirection: false,
                                            fallbackDirection: .rightToLeft,
                                            boxMirroring: true)
        let options = TerminalOptions(cols: 80, rows: 25, initialBidiState: initial,
                                      initialBidiArrowKeySwap: true)
        let terminal = Terminal(delegate: self, options: options)
        terminal.feed(text: "\u{1b}[8h\u{1b}[?2501h\u{1b}[1 k\u{1b}[?2500l\u{1b}[?1243l")
        #expect(!terminal.bidiArrowKeySwap)
        terminal.softReset()
        #expect(terminal.currentBidiState == initial)
        #expect(terminal.bidiArrowKeySwap)
    }

    @Test func resetRestoresConfiguredArrowSwappingDisabled() {
        let terminal = Terminal(delegate: self,
                                options: TerminalOptions(initialBidiArrowKeySwap: false))
        #expect(!terminal.bidiArrowKeySwap)
        terminal.feed(text: "\u{1b}[?1243h")
        terminal.softReset()
        #expect(!terminal.bidiArrowKeySwap)
        terminal.feed(text: "\u{1b}[?1243h")
        terminal.resetToInitialState()
        #expect(!terminal.bidiArrowKeySwap)
    }

    @Test func decrqmReportsBidiModes() {
        let terminal = makeTerminal()

        sent.removeAll()
        terminal.feed(text: "\u{1b}[8$p")
        #expect(sentString == "\u{1b}[8;1$y", "BDSM set by default")

        sent.removeAll()
        terminal.feed(text: "\u{1b}[8l\u{1b}[8$p")
        #expect(sentString == "\u{1b}[8;2$y", "BDSM reports reset after RM 8")

        sent.removeAll()
        terminal.feed(text: "\u{1b}[?2501$p")
        #expect(sentString == "\u{1b}[?2501;1$y", "autodetect set by default")

        sent.removeAll()
        terminal.feed(text: "\u{1b}[?2500$p")
        #expect(sentString == "\u{1b}[?2500;2$y", "box mirroring reset by default")

        sent.removeAll()
        terminal.feed(text: "\u{1b}[?2500h\u{1b}[?2500$p")
        #expect(sentString == "\u{1b}[?2500;1$y")

        sent.removeAll()
        terminal.feed(text: "\u{1b}[?1243$p")
        #expect(sentString == "\u{1b}[?1243;1$y", "arrow swapping set by default")
    }

    @Test func decrqmReportsArrowSwappingPermanentlyResetWhenTheHostDoesNotSwap() {
        hostSwapsArrowKeys = false
        let terminal = makeTerminal()
        #expect(terminal.bidiArrowKeySwap)
        for sequence in ["", "\u{1b}[?1243h", "\u{1b}[?1243l"] {
            sent.removeAll()
            terminal.feed(text: sequence + "\u{1b}[?1243$p")
            #expect(sentString == "\u{1b}[?1243;4$y")
        }
    }

    @Test func fullResetRestoresBidiDefaults() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[8l\u{1b}[?2501l\u{1b}[3 S\u{1b}[?2500h")
        #expect(!terminal.bidiSupportEnabled)
        #expect(!terminal.bidiAutodetectDirection)
        #expect(terminal.bidiRTLPreference)
        #expect(terminal.bidiBoxMirroring)

        terminal.resetToInitialState()
        #expect(terminal.bidiSupportEnabled)
        #expect(terminal.bidiAutodetectDirection)
        #expect(!terminal.bidiRTLPreference)
        #expect(terminal.bidiBoxMirroring == false)
        #expect(terminal.bidiArrowKeySwap)
    }
}
