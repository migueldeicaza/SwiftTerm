//
//  BidiCacheTests.swift
//
//  Guards for the BiDi paragraph layout caches: a cached layout must always be
//  indistinguishable from a freshly computed one. Every test compares a
//  possibly-cache-served layout against a fresh computation after clearing the
//  caches — any stale or wrongly-shared entry fails that comparison.
//
#if os(macOS)
import Foundation
import AppKit
import Testing

@testable import SwiftTerm

@Suite(.serialized)
final class BidiCacheTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    func makeTerminal(cols: Int = 20, rows: Int = 4, scrollback: Int = 100,
                      state: BidiPresentationState = .default,
                      feed text: String) -> Terminal {
        let options = TerminalOptions(cols: cols, rows: rows, scrollback: scrollback,
                                      initialBidiState: state)
        let terminal = Terminal(delegate: self, options: options)
        terminal.feed(text: text)
        return terminal
    }

    func layout(_ terminal: Terminal, row: Int = 0, cols: Int = 20) -> BidiRowLayout? {
        return TerminalBidi.layout(row: row, buffer: terminal.buffer, cols: cols,
                                   terminal: terminal, font: font,
                                   hostPolicy: .respectTerminal)
    }

    /// Layout equality as the renderer sees it: everything except
    /// paragraphRevision, which is a change stamp rather than layout content.
    func equalLayouts(_ a: BidiRowLayout?, _ b: BidiRowLayout?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case let (a?, b?):
            guard a.baseDirection == b.baseDirection,
                  a.logicalToVisualCol == b.logicalToVisualCol,
                  a.visualToLogicalCol == b.visualToLogicalCol,
                  a.visualCells.count == b.visualCells.count else {
                return false
            }
            for (ca, cb) in zip(a.visualCells, b.visualCells) {
                if ca.logicalCol != cb.logicalCol || ca.width != cb.width
                    || ca.display != cb.display {
                    return false
                }
            }
            return true
        default:
            return false
        }
    }

    /// A layout served from the content cache must be identical to one
    /// computed from scratch for the same content.
    @Test func contentCacheHitMatchesFreshComputation() {
        let text = "مرحبا بالعالم"
        let first = makeTerminal(feed: text)
        let firstLayout = layout(first)
        #expect(firstLayout != nil)

        let hitsBefore = TerminalBidi._contentCacheHits
        let second = makeTerminal(feed: text)
        let servedLayout = layout(second)
        #expect(TerminalBidi._contentCacheHits > hitsBefore,
                "identical content did not reuse the content cache")

        TerminalBidi._testResetCaches()
        let freshLayout = layout(second)
        #expect(equalLayouts(servedLayout, freshLayout))
        #expect(equalLayouts(firstLayout, freshLayout))
    }

    /// Scrolling rotates the circular line list, so the same paragraph lands
    /// on different absolute rows. The layout served at the new position must
    /// match a fresh computation for that position.
    @Test func scrolledParagraphIsNotServedStale() {
        let arabic = "هذا نص عربي"
        let terminal = makeTerminal(rows: 4, scrollback: 2, feed: arabic)
        // Enough filler to exhaust the scrollback and force line recycling,
        // shifting every absolute row index.
        for index in 0..<8 {
            terminal.feed(text: "\r\nfiller\(index)")
            terminal.feed(text: "\r\n\(arabic)")
        }
        let buffer = terminal.buffer
        for row in 0..<buffer.lines.count {
            let cached = layout(terminal, row: row)
            TerminalBidi._testResetCaches()
            let fresh = layout(terminal, row: row)
            #expect(equalLayouts(cached, fresh),
                    "row \(row) rendered a layout that differs from a fresh computation")
        }
    }

    /// Overwriting one cell must change the served layout: the neighbors'
    /// contextual Arabic forms depend on it, and an entry keyed on the old
    /// content must not survive the edit.
    @Test func mutatedCellIsNotServedStale() {
        let terminal = makeTerminal(feed: "ابج")
        let before = layout(terminal)
        #expect(before != nil)

        // Overwrite the middle letter (column 2, 1-based) with a different
        // joining class: ب (dual-joining) -> د (right-joining).
        terminal.feed(text: "\u{1b}[1;2Hد")
        let after = layout(terminal)

        TerminalBidi._testResetCaches()
        let fresh = layout(terminal)
        #expect(equalLayouts(after, fresh),
                "post-edit layout differs from a fresh computation")
        #expect(!equalLayouts(after, before),
                "the edit changed joining context but the served layout did not change")
    }

    /// Two paragraphs that differ only in a trailing letter must each get
    /// their own layout: the appended letter switches the previous letter
    /// from final to medial form, so sharing either entry renders a wrong
    /// contextual shape.
    @Test func nearIdenticalContentIsNotShared() {
        let base = makeTerminal(feed: "ابج")
        let baseLayout = layout(base)
        let extended = makeTerminal(feed: "ابجد")
        let extendedLayout = layout(extended)
        #expect(!equalLayouts(baseLayout, extendedLayout))

        TerminalBidi._testResetCaches()
        #expect(equalLayouts(baseLayout, layout(base)))
        TerminalBidi._testResetCaches()
        #expect(equalLayouts(extendedLayout, layout(extended)))
    }

    /// The same content under a different presentation state must not reuse
    /// the other state's layout (box mirroring changes display substitutions).
    @Test func presentationStateIsPartOfTheKey() {
        let text = "ש┌ש"
        let mirroringState = BidiPresentationState(supportMode: .implicit,
                                                   autodetectDirection: true,
                                                   fallbackDirection: .leftToRight,
                                                   boxMirroring: true)
        let plainState = BidiPresentationState(supportMode: .implicit,
                                               autodetectDirection: true,
                                               fallbackDirection: .leftToRight,
                                               boxMirroring: false)
        let mirrored = layout(makeTerminal(state: mirroringState, feed: text))
        let plain = layout(makeTerminal(state: plainState, feed: text))
        #expect(!equalLayouts(mirrored, plain),
                "box mirroring state was ignored by the cache key")

        TerminalBidi._testResetCaches()
        #expect(equalLayouts(mirrored, layout(makeTerminal(state: mirroringState, feed: text))))
    }

    /// The same content at a different terminal width must be laid out for
    /// that width.
    @Test func columnCountIsPartOfTheKey() {
        let text = "שלום עולם"
        let wide = makeTerminal(cols: 20, feed: text)
        let narrow = makeTerminal(cols: 12, feed: text)
        let wideLayout = layout(wide, cols: 20)
        let narrowLayout = layout(narrow, cols: 12)
        #expect(wideLayout?.logicalToVisualCol.count == 20)
        #expect(narrowLayout?.logicalToVisualCol.count == 12)

        TerminalBidi._testResetCaches()
        #expect(equalLayouts(wideLayout, layout(wide, cols: 20)))
        TerminalBidi._testResetCaches()
        #expect(equalLayouts(narrowLayout, layout(narrow, cols: 12)))
    }
}
#endif
