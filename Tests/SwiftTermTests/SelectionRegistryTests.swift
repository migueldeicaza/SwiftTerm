//
//  SelectionRegistryTests.swift
//
//  Covers `Terminal`'s selection registry after it stopped holding its entries
//  weakly (Docs/io-cpu-profile.md §8).
//
//  Two things need pinning. The registry's slots are `unowned(unsafe)` and rely
//  on `SelectionService.deinit` removing them, so a stale slot would be a
//  use-after-free rather than a nil read. And the scroll path now consults an
//  active-selection count before walking the registry at all, so if that count
//  ever drifts, selections silently stop tracking in-place scrolls — a failure
//  that is invisible until a user selects text in a TUI.
//
//  `adjustForInPlaceScroll` had no test coverage at all before this file.
//

import Foundation
import Testing

@testable import SwiftTerm

@Suite final class SelectionRegistryTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    /// Builds a terminal with a DECSTBM region that does not start at row 0, so
    /// `Terminal.scroll` takes the in-place branch (no scrollback push) and
    /// notifies selections.
    private func makeTerminal(rows: Int = 10) -> Terminal {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: rows))
        // DECSTBM 3;8 -> absolute rows 2...7
        terminal.feed(text: "\u{1b}[3;8r")
        return terminal
    }

    // MARK: - the count that gates the hot path

    @Test func activeCountTracksSelectionState() {
        let terminal = makeTerminal()
        let selection = SelectionService(terminal: terminal)

        #expect(terminal.testingActiveSelectionCount == 0)

        selection.setSelection(start: Position(col: 0, row: 3), end: Position(col: 5, row: 3))
        #expect(selection.active)
        #expect(terminal.testingActiveSelectionCount == 1)

        selection.selectNone()
        #expect(terminal.testingActiveSelectionCount == 0)

        // Re-activating must not double count.
        selection.setSelection(start: Position(col: 0, row: 3), end: Position(col: 5, row: 3))
        selection.setSelection(start: Position(col: 1, row: 3), end: Position(col: 6, row: 3))
        #expect(terminal.testingActiveSelectionCount == 1)
    }

    @Test func deallocatingAnActiveSelectionRestoresTheCount() {
        let terminal = makeTerminal()
        do {
            let selection = SelectionService(terminal: terminal)
            selection.setSelection(start: Position(col: 0, row: 3), end: Position(col: 5, row: 3))
            #expect(terminal.testingActiveSelectionCount == 1)
            #expect(terminal.testingSelectionCount == 1)
        }
        // deinit must have unregistered and decremented, or the next scroll
        // would walk a dangling slot.
        #expect(terminal.testingSelectionCount == 0)
        #expect(terminal.testingActiveSelectionCount == 0)
    }

    @Test func registryDropsServicesAsTheyDie() {
        let terminal = makeTerminal()
        do {
            let a = SelectionService(terminal: terminal)
            let b = SelectionService(terminal: terminal)
            #expect(terminal.testingSelectionCount == 2)
            _ = a; _ = b
        }
        #expect(terminal.testingSelectionCount == 0)

        // A scroll after every service died must not touch freed memory.
        terminal.feed(text: "\u{1b}[8;1Hx\n")
        #expect(terminal.testingSelectionCount == 0)
    }

    // MARK: - the behaviour the count gates

    /// The whole point of the registry: an in-place scroll moves the rows under
    /// an active selection, so its anchors must follow.
    @Test func activeSelectionFollowsAnInPlaceScroll() {
        let terminal = makeTerminal()
        let selection = SelectionService(terminal: terminal)
        selection.setSelection(start: Position(col: 0, row: 4), end: Position(col: 5, row: 4))
        #expect(selection.active)

        // Park the cursor on the last row of the region and line feed, which
        // scrolls rows 2...7 up by one in place.
        terminal.feed(text: "\u{1b}[8;1H\n")

        #expect(selection.active)
        #expect(selection.start.row == 3)
        #expect(selection.end.row == 3)
    }

    /// A selection scrolled out of the region is dropped rather than left
    /// pointing at text that is gone.
    @Test func selectionScrolledOutOfTheRegionIsCleared() {
        let terminal = makeTerminal()
        let selection = SelectionService(terminal: terminal)
        // Top row of the region: one scroll pushes it out.
        selection.setSelection(start: Position(col: 0, row: 2), end: Position(col: 5, row: 2))
        #expect(selection.active)

        terminal.feed(text: "\u{1b}[8;1H\n")

        #expect(selection.active == false)
        #expect(terminal.testingActiveSelectionCount == 0)
    }

    /// An inactive selection is what the fast path skips; make sure a scroll
    /// with nothing selected leaves it alone and keeps the count at zero.
    @Test func inactiveSelectionIsUndisturbedByScrolling() {
        let terminal = makeTerminal()
        let selection = SelectionService(terminal: terminal)
        #expect(terminal.testingActiveSelectionCount == 0)

        for _ in 0..<50 {
            terminal.feed(text: "\u{1b}[8;1Hline\n")
        }

        #expect(selection.active == false)
        #expect(terminal.testingActiveSelectionCount == 0)
    }

    /// Registration runs inside `terminalLock.withLock` in the real view, and
    /// that same assignment releases the previous service — so construction and
    /// destruction both have to work with the lock already held. This is the
    /// shape that would deadlock if `deinit` took the lock unconditionally.
    @Test func replacingASelectionWhileHoldingTheLockDoesNotDeadlock() {
        let terminal = makeTerminal()
        var selection: SelectionService? = terminal.terminalLock.withLock {
            SelectionService(terminal: terminal)
        }
        #expect(terminal.testingSelectionCount == 1)

        terminal.terminalLock.withLock {
            // Releases the old service (running its deinit) and registers a new
            // one, all while the lock is held.
            selection = SelectionService(terminal: terminal)
        }
        #expect(terminal.testingSelectionCount == 1)
        #expect(selection != nil)

        selection = nil
        #expect(terminal.testingSelectionCount == 0)
    }
}
