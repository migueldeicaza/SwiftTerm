#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
struct TerminalEmbeddingSnapshotTests {
    private func makeView(scrollback: Int = 20) -> TerminalView {
        TerminalView(frame: .zero, font: nil,
                     options: TerminalOptions(cols: 12, rows: 4, scrollback: scrollback))
    }

    @Test func unattachedOwnerReturnsNil() {
        let owner = TerminalRenderOwner()
        #expect(owner.inputStateSnapshot() == nil)
        #expect(owner.contentSnapshot(region: .viewport) == nil)
    }

    @Test func copiedModesReflectActiveBuffer() throws {
        let view = makeView()
        view.feed(text: "\u{1b}[?1049h\u{1b}[?1h\u{1b}[?1002h\u{1b}[>8u")
        let input = try #require(view.terminalInputStateSnapshot())
        #expect(input.dimensions == view.terminalDimensions)
        #expect(input.isAlternateBuffer)
        #expect(input.applicationCursor)
        #expect(input.mouseMode == .buttonEventTracking)
        #expect(input.keyboardEnhancementFlags.contains(.reportAllKeys))
        view.feed(text: "\u{1b}[?1049l")
        #expect(view.terminalInputStateSnapshot()?.isAlternateBuffer == false)
        #expect(view.terminalInputStateSnapshot()?.keyboardEnhancementFlags.isEmpty == true)
        #expect(input.isAlternateBuffer)
    }

    @Test func copiedCellsPreserveTextWidthsAndAttributes() throws {
        let view = makeView()
        let placeholder = "\u{10EEEE}\u{0305}\u{030D}"
        view.feed(text: "\u{1b}[38;2;1;2;3;58;2;4;5;6m" + placeholder + "界e\u{301}")
        let snapshot = try #require(view.terminalContentSnapshot(region: .viewport))
        let row = try #require(snapshot.rows.first)
        #expect(row.cells[0].text == placeholder)
        #expect(row.cells[0].attribute.fg == .trueColor(red: 1, green: 2, blue: 3))
        #expect(row.cells[0].attribute.underlineColor == .trueColor(red: 4, green: 5, blue: 6))
        #expect(row.cells[1].text == "界")
        #expect(row.cells[1].width == 2)
        #expect(row.cells[2].text == "\u{0}")
        #expect(row.cells[2].width == 0)
        #expect(row.text == placeholder + "界\u{0}e\u{301}")
        let copiedRows = snapshot.rows
        view.feed(text: "\u{1b}[2J\u{1b}[Hreplacement\r\nmore\r\nrows\r\ntrim\r\nold")
        view.resize(cols: 8, rows: 2)
        view.feed(text: "\u{1b}[?1049h")
        #expect(snapshot.rows == copiedRows)
        #expect(snapshot.inputState.dimensions == TerminalDimensions(cols: 12, rows: 4))
    }

    @Test func fullCellTextDoesNotUseCharacterProjection() throws {
        let view = makeView()
        let text = "\u{A98F}\u{A9C0}\u{A994}\u{A9B8}"
        view.feed(text: text)
        let row = try #require(view.terminalContentSnapshot(region: .viewport)?.rows.first)
        #expect(row.cells[0].text == text)
        #expect(row.text.hasPrefix(text))
    }

    @Test func historyIsBoundedAndUsesScrollInvariantCoordinates() throws {
        let view = makeView(scrollback: 800)
        view.feed(text: (0..<1_000).map { "row\($0)\r\n" }.joined())
        let bounded = try #require(view.terminalContentSnapshot(
            region: .history(maximumScrollbackRows: 500)))
        #expect(bounded.rows.count == 504)
        #expect(bounded.capturedRange.count == bounded.rows.count)
        #expect(bounded.rows.map(\.absoluteRow) == Array(bounded.capturedRange))
        #expect(bounded.liveTopRow == bounded.capturedRange.upperBound - 4)
        #expect(bounded.capturedRange.lowerBound > 0)
        let all = try #require(view.terminalContentSnapshot(
            region: .history(maximumScrollbackRows: Int.max)))
        #expect(all.rows.count > bounded.rows.count)
        #expect(all.rows.suffix(504).elementsEqual(bounded.rows))
        let live = try #require(view.terminalContentSnapshot(
            region: .history(maximumScrollbackRows: Int.min)))
        #expect(live.rows.count == 4)
        #expect(live.capturedRange.lowerBound == bounded.liveTopRow)
        view.scrollUp(lines: 10)
        let viewport = try #require(view.terminalContentSnapshot(region: .viewport))
        #expect(viewport.rows.count == 4)
        #expect(viewport.capturedRange.lowerBound == bounded.liveTopRow - 10)
        #expect(viewport.liveTopRow == bounded.liveTopRow)
    }

    @Test func contentCopyDoesNotEnterRenderDomain() async {
        let view = makeView()
        let owner = view.renderOwner
        let copied = DispatchSemaphore(value: 0)
        owner.withSnapshotForDrawing(viewState: FrameViewState(view: view)) { _, _ in
            DispatchQueue.global().async {
                #expect(owner.contentSnapshot(region: .viewport) != nil)
                copied.signal()
            }
            #expect(copied.wait(timeout: .now() + 2) == .success)
        }
    }

    @Test func valueTypesAreCheckedSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(TerminalInputStateSnapshot.self)
        requireSendable(TerminalContentRegion.self)
        requireSendable(TerminalCellSnapshot.self)
        requireSendable(TerminalContentRowSnapshot.self)
        requireSendable(TerminalContentSnapshot.self)
    }
}
#endif
