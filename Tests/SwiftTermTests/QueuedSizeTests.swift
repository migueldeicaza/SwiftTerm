//
//  QueuedSizeTests.swift
//
//  A font change queues the grid's counts for the next frame, measured on the
//  frame the view has then. A later resize applies new counts at once; the
//  next frame must not put the old ones back.
//
#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
@Suite struct QueuedSizeTests {
    @Test func aResizeReplacesTheCountsAFontChangeQueued() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 560))
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let born = view.withTerminal { ($0.cols, $0.rows) }

        view.setFrameSize(NSSize(width: 663, height: 744))
        let resized = view.withTerminal { ($0.cols, $0.rows) }
        #expect(resized != born)

        view.frameTick()
        let afterFrame = view.withTerminal { ($0.cols, $0.rows) }
        #expect(afterFrame == resized)
    }
}
#endif
