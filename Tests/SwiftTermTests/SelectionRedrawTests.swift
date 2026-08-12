//
//  SelectionRedrawTests.swift
//  SwiftTermTests
//
//  A selection change has to reach a frame. Drawing reads `currentSnapshot`,
//  and only a frame tick refreshes it, so invalidating the view without waking
//  the frame driver repaints the previous frame — the selection highlight
//  never appears. That shipped on this branch and was reported as "mouse
//  selection is not working".
//

#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct SelectionRedrawTests {
    private func drain() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }

    private func makeView() -> (TerminalView, ManualTickSource, FrameDriver) {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200),
                                font: nil,
                                options: TerminalOptions(cols: 40, rows: 10, scrollback: 50))
        view.frameDriver.invalidate()
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        driver.onTick = { [weak view] in view?.frameTick() }
        view.frameDriver = driver
        return (view, source, driver)
    }

    /// Starting and extending a selection must produce a frame carrying it.
    @Test func selectionReachesTheFrame() async throws {
        let (view, source, driver) = makeView()
        defer { driver.invalidate() }

        view.feed(text: "hello world\r\nsecond line\r\n")
        await drain(); source.tick(); await drain()

        view.selection.startSelection(row: 0, col: 0)
        view.selection.dragExtend(bufferPosition: Position(col: 5, row: 0))
        #expect(view.selection.active)

        // No explicit markDirty: the selection change alone must wake the driver.
        await drain(); source.tick(); await drain()

        #expect(view.currentSnapshot.style.selectionActive)
        let context = try #require(view.currentSnapshot.renderContext)
        #expect(context.selection.columns(forRow: 0) != nil)
    }

    /// And clearing it must too, or the highlight stays on screen.
    @Test func clearingTheSelectionReachesTheFrame() async throws {
        let (view, source, driver) = makeView()
        defer { driver.invalidate() }

        view.feed(text: "hello world\r\n")
        await drain(); source.tick(); await drain()
        view.selection.startSelection(row: 0, col: 0)
        view.selection.dragExtend(bufferPosition: Position(col: 5, row: 0))
        await drain(); source.tick(); await drain()
        #expect(view.currentSnapshot.style.selectionActive)

        view.selection.selectNone()
        await drain(); source.tick(); await drain()

        #expect(!view.currentSnapshot.style.selectionActive)
    }
}
#endif
