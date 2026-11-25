//
//  MarkedTextOverlayMetalTests.swift
//
//  Under the Metal renderer the IME marked text and the candidate window
//  follow the cursor, as they do under Core Graphics.
//
#if os(macOS) && canImport(MetalKit)
import AppKit
import Metal
import Testing
@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct MarkedTextOverlayMetalTests {
    nonisolated static var metalIsUsable: Bool {
        MetalTerminalRenderer.shaderLibraryIsAvailable && MTLCreateSystemDefaultDevice() != nil
    }

    /// The rectangle of the cell at `row`, `column` (zero-based, from the top) in view coordinates.
    private func cellRect(_ view: TerminalView, row: Int, column: Int) -> CGRect {
        let cell = view.cellDimension!
        return CGRect(x: CGFloat(column) * cell.width,
                      y: view.frame.height - CGFloat(row + 1) * cell.height,
                      width: cell.width, height: cell.height)
    }

    private func expectNear(_ a: CGRect, _ b: CGRect, _ what: String,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 &&
                abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5,
                "\(what): \(a) is not \(b)", sourceLocation: sourceLocation)
    }

    @Test(.enabled(if: metalIsUsable))
    func markedTextAndCandidateWindowFollowTheCursor() throws {
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 320, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        window.contentView = view
        try view.setUseMetal(true)
        #expect(view.isUsingMetalRenderer)

        // Move the cursor to row 3, column 6.
        view.feed(text: "one\r\ntwo\r\nthree\r\n$ abc")
        let expected = cellRect(view, row: 3, column: 5)
        expectNear(view.caretFrame, expected, "caretFrame")

        view.setMarkedText("ka")
        let overlay = try #require(view.dictationOverlay)
        // Line 1 of the overlay is on the cursor's row, and starts at the cursor.
        #expect(abs(overlay.frame.maxY - expected.maxY) < 0.5,
                "overlay top \(overlay.frame.maxY) is not \(expected.maxY)")
        #expect(abs(overlay.firstLineIndent - expected.minX) < 0.5,
                "overlay indent \(overlay.firstLineIndent) is not \(expected.minX)")

        let candidate = view.firstRect(forCharacterRange: NSRange(location: 0, length: 2),
                                       actualRange: nil)
        let expectedOnScreen = window.convertToScreen(view.convert(expected, to: nil))
        expectNear(candidate, expectedOnScreen, "firstRect")

        // The marked text follows the cursor after it moves.
        view.unmarkText()
        view.feed(text: "\u{1b}[2;3H")
        view.setMarkedText("ka")
        let moved = cellRect(view, row: 1, column: 2)
        let candidateAfterMove = view.firstRect(forCharacterRange: NSRange(location: 0, length: 2),
                                                actualRange: nil)
        expectNear(candidateAfterMove, window.convertToScreen(view.convert(moved, to: nil)),
                   "firstRect after the cursor moves")
    }
}
#endif
