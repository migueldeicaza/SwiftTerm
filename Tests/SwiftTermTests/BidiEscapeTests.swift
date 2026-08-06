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

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        sent.append(contentsOf: data)
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
        #expect(!terminal.bidiArrowKeySwap, "arrow swapping requires opt-in")
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
        #expect(!terminal.bidiArrowKeySwap)

        terminal.bidiArrowKeySwap = true
        #expect(terminal.bidiArrowKeySwap)

        terminal.bidiArrowKeySwap = false
        #expect(!terminal.bidiArrowKeySwap)
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
        #expect(!terminal.bidiArrowKeySwap)
    }
}
