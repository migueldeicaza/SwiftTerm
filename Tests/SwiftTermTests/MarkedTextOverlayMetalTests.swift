//
//  MarkedTextOverlayMetalTests.swift
//
//  The IME marked text and the candidate window go to the cursor. Under Metal
//  the renderer draws the cursor and does not move `caretView`, so
//  `caretFrame` gets the cell from the terminal's cursor. Under Core Graphics
//  it stays at the cursor that the last frame drew.
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

    private let frame = CGRect(x: 0, y: 0, width: 320, height: 160)

    /// Makes a view in a window, so that `firstRect` can convert to the screen.
    private func makeView(metal: Bool) throws -> (TerminalView, NSWindow) {
        let window = NSWindow(contentRect: frame.offsetBy(dx: 100, dy: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TerminalView(frame: frame)
        window.contentView = view
        if metal {
            try view.setUseMetal(true)
            #expect(view.isUsingMetalRenderer)
        }
        return (view, window)
    }

    private func close(_ view: TerminalView, _ window: NSWindow) {
        window.close()
        view.updateUiClosed()
    }

    /// The rectangle of `width` cells at `row`, `column` (zero-based, from the top) in view coordinates.
    private func cellRect(_ view: TerminalView, row: Int, column: Int, width: Int = 1) -> CGRect {
        let cell = view.cellDimension!
        return CGRect(x: CGFloat(column) * cell.width,
                      y: view.frame.height - CGFloat(row + 1) * cell.height,
                      width: CGFloat(width) * cell.width, height: cell.height)
    }

    private func expectNear(_ a: CGRect, _ b: CGRect, _ what: String,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 &&
                abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5,
                "\(what): \(a) is not \(b)", sourceLocation: sourceLocation)
    }

    private func candidateRect(_ view: TerminalView) -> CGRect {
        view.firstRect(forCharacterRange: NSRange(location: 0, length: 2), actualRange: nil)
    }

    private func onScreen(_ rect: CGRect, _ view: TerminalView, _ window: NSWindow) -> CGRect {
        window.convertToScreen(view.convert(rect, to: nil))
    }

    /// The caret frame that Core Graphics draws for `text`, as the reference.
    private func coreGraphicsCaretFrame(_ text: String) throws -> CGRect {
        let (view, window) = try makeView(metal: false)
        defer { close(view, window) }
        view.feed(text: text)
        view.frameTick()
        return view.caretFrame
    }

    /// Refreshes the render snapshot as the render loop does. The window is
    /// not on the screen, so the loop does not draw.
    private func refreshSnapshot(_ view: TerminalView) throws {
        let viewState = try #require(view.captureFrameViewState())
        _ = view.prepareFrame(viewState: viewState)
    }

    @Test(.enabled(if: metalIsUsable))
    func markedTextAndCandidateWindowFollowTheCursor() throws {
        let (view, window) = try makeView(metal: true)
        defer { close(view, window) }

        // Move the cursor to row 3, column 5.
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
        expectNear(candidateRect(view), onScreen(expected, view, window), "firstRect")

        // The marked text follows the cursor after it moves.
        view.unmarkText()
        view.feed(text: "\u{1b}[2;3H")
        view.setMarkedText("ka")
        expectNear(candidateRect(view), onScreen(cellRect(view, row: 1, column: 2), view, window),
                   "firstRect after the cursor moves")
    }

    /// On a wide character, the caret covers its two cells.
    @Test(.enabled(if: metalIsUsable))
    func caretCoversAWideCharacter() throws {
        let text = "\u{3042}\u{3044}\u{1b}[3G"
        let (view, window) = try makeView(metal: true)
        defer { close(view, window) }
        view.feed(text: text)
        let expected = cellRect(view, row: 0, column: 2, width: 2)
        expectNear(view.caretFrame, expected, "caretFrame")
        expectNear(view.caretFrame, try coreGraphicsCaretFrame(text), "Metal and Core Graphics")
    }

    /// On a double-width line (DECDWL), each column takes two cells.
    @Test(.enabled(if: metalIsUsable))
    func caretOnADoubleWidthLine() throws {
        let text = "\u{1b}#6ab"
        let (view, window) = try makeView(metal: true)
        defer { close(view, window) }
        view.feed(text: text)
        let expected = cellRect(view, row: 0, column: 4, width: 2)
        expectNear(view.caretFrame, expected, "caretFrame")
        expectNear(view.caretFrame, try coreGraphicsCaretFrame(text), "Metal and Core Graphics")
    }

    /// On a right-to-left row, the caret goes to the visual column of the cursor.
    @Test(.enabled(if: metalIsUsable))
    func caretOnARightToLeftRow() throws {
        // The cursor is on the second letter (logical column 1).
        let text = "\u{05E9}\u{05DC}\u{05D5}\u{05DD}\u{1b}[2G"
        let reference = try coreGraphicsCaretFrame(text)
        let (view, window) = try makeView(metal: true)
        defer { close(view, window) }
        view.feed(text: text)
        try refreshSnapshot(view)
        #expect(view.renderOwner.snapshotVisualColumn(absoluteRow: 0, logicalColumn: 1) != nil)
        // Make sure that the test is not vacuous: the visual column is not the logical one.
        #expect(abs(reference.minX - cellRect(view, row: 0, column: 1).minX) > 0.5)
        expectNear(view.caretFrame, reference, "Metal and Core Graphics")
    }

    /// When the user scrolls back, the marked text goes on the nearest visible
    /// row, at the cursor column, not at the bottom-left corner.
    @Test(.enabled(if: metalIsUsable))
    func markedTextStaysAtTheCursorColumnInTheScrollback() throws {
        let (view, window) = try makeView(metal: true)
        defer { close(view, window) }
        view.feed(text: (0..<60).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n$ abc")
        let rows = view.withTerminal { $0.rows }
        view.scrollUp(lines: 5)
        #expect(view.withTerminal { $0.displayBuffer.yDisp < $0.displayBuffer.yBase })

        let expected = cellRect(view, row: rows - 1, column: 5)
        expectNear(view.caretFrame, expected, "caretFrame")
        view.setMarkedText("ka")
        let overlay = try #require(view.dictationOverlay)
        #expect(abs(overlay.firstLineIndent - expected.minX) < 0.5,
                "overlay indent \(overlay.firstLineIndent) is not \(expected.minX)")
        expectNear(candidateRect(view), onScreen(expected, view, window), "firstRect")
    }

    /// A delegate callback can hold the terminal lock. Reading `caretFrame`
    /// there must not take the lock again.
    @Test(.enabled(if: metalIsUsable), arguments: [true, false])
    func caretFrameCanBeReadUnderTheTerminalLock(metal: Bool) throws {
        let (view, window) = try makeView(metal: metal)
        defer { close(view, window) }
        view.feed(text: "$ abc")
        view.frameTick()
        let outside = view.caretFrame
        let inside = view.withTerminal { _ in view.caretFrame }
        expectNear(inside, outside, "caretFrame under the lock")
        expectNear(inside, cellRect(view, row: 0, column: 5), "caretFrame")
    }

    /// Under Core Graphics the marked text goes to the cursor on the screen.
    /// While synchronized output (DECSET 2026) is on, the terminal's cursor
    /// can be on a different row, for example while a TUI paints a status line.
    @Test func coreGraphicsUsesTheDrawnCursorDuringSynchronizedOutput() throws {
        let (view, window) = try makeView(metal: false)
        defer { close(view, window) }
        view.feed(text: "$ abc")
        view.frameTick()
        let drawn = cellRect(view, row: 0, column: 5)
        expectNear(view.caretFrame, drawn, "caretFrame before the update")

        view.feed(text: "\u{1b}[?2026h\u{1b}[5;10Hstatus")
        view.frameTick()
        expectNear(view.caretFrame, drawn, "caretFrame during the update")
        view.setMarkedText("ka")
        let overlay = try #require(view.dictationOverlay)
        #expect(abs(overlay.frame.maxY - drawn.maxY) < 0.5,
                "overlay top \(overlay.frame.maxY) is not \(drawn.maxY)")
        expectNear(candidateRect(view), onScreen(drawn, view, window), "firstRect")
        view.unmarkText()
        view.feed(text: "\u{1b}[?2026l")
    }
}
#endif
