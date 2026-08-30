#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
struct TerminalSnapshotTests {
    private func requireSendable<T: Sendable> (_ type: T.Type) {}

    private func makeView (cols: Int = 12, rows: Int = 4) -> TerminalView {
        TerminalView(frame: .zero, font: nil,
                     options: TerminalOptions(cols: cols, rows: rows, scrollback: 20))
    }

    @discardableResult
    private func refresh (_ snapshot: TerminalSnapshot, from view: TerminalView,
                          deferBidiTypesetting: Bool = false)
        -> TerminalSnapshot.RefreshResult
    {
        view.withTerminal { terminal in
            snapshot.refresh(terminal: terminal, viewState: FrameViewState(view: view),
                             selection: SnapshotSelectionState(selection: view.selection),
                             deferBidiTypesetting: deferBidiTypesetting)
        }
    }

    private func text (in row: TerminalSnapshot.Row, cols: Int) -> String {
        var result = ""
        var column = 0
        while column < min(cols, row.line.count) {
            let cell = row.line.packedView(at: column)
            result.append(contentsOf: row.text(at: column, cell: cell))
            column += max(1, Int(cell.width))
        }
        return result
    }

    @Test func contentCorrectnessAfterFeed() throws {
        let view = makeView()
        view.feed(text: "snapshot")
        let snapshot = TerminalSnapshot()

        #expect(refresh(snapshot, from: view) == .refreshed)
        let row = try #require(snapshot.rows.first)
        #expect(text(in: row, cols: snapshot.cols).hasPrefix("snapshot"))
        #expect(row.sourceIdentity != nil)
        #expect(snapshot.cursor?.logicalCol == 8)
    }

    @Test func frameBoundaryMessagesAreCheckedSendable() {
        requireSendable(FrameViewState.self)
        requireSendable(MainFrameEffects.self)
        requireSendable(TerminalRenderOwner.self)
        requireSendable(RenderLoop.self)
    }

    @Test func drawingDoesNotBlockParserFeed() {
        let view = makeView()
        let owner = view.renderOwner
        let completed = DispatchSemaphore(value: 0)

        owner.withSnapshotForDrawing(viewState: FrameViewState(view: view)) { _, _ in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = owner.feed(text: "x")
                completed.signal()
            }

            #expect(completed.wait(timeout: .now() + 1) == .success)
        }
    }

    @Test func outputPreservesSelectionWhileSelectedRowsRemainBuffered() {
        let view = makeView()
        view.feed(text: "selected\r\none\r\ntwo\r\nthree")
        view.withTerminal { _ in
            view.selection.setSelection(
                start: Position(col: 0, row: 0),
                end: Position(col: 8, row: 0))
        }

        // Move the selected row into scrollback. Its buffer position stays valid.
        view.feed(text: "\r\nfour")

        view.withTerminal { _ in
            #expect(view.selection.active)
            #expect(view.selection.start == Position(col: 0, row: 0))
            #expect(view.selection.end == Position(col: 8, row: 0))
            #expect(view.selection.getSelectedText() == "selected")
        }
    }

    @Test(arguments: [
        "\u{1b}[?1049h",
        "\u{1b}[2J",
        "\u{1b}[1;1Hoverwrite",
    ])
    func outputClearsSelectionWhenSelectedContentChanges(_ output: String) {
        let view = makeView()
        view.feed(text: "selected\r\none\r\ntwo\r\nthree")
        view.withTerminal { _ in
            view.selection.setSelection(
                start: Position(col: 0, row: 0),
                end: Position(col: 8, row: 0))
        }

        view.feed(text: output)

        view.withTerminal { _ in
            #expect(view.selection.active == false)
        }
    }

    @Test func outputPreservesSelectionWhenAnInPlaceScrollMovesItsContent() {
        let view = makeView(cols: 12, rows: 5)
        view.feed(text: "\u{1b}[?1049h")
        for row in 1...5 {
            view.feed(text: "\u{1b}[\(row);1HLINE_\(row)")
        }
        view.withTerminal { _ in
            view.selection.setSelection(
                start: Position(col: 0, row: 2),
                end: Position(col: 6, row: 2))
        }

        view.feed(text: "\u{1b}[2;5r\u{1b}[5;1H\r\n\u{1b}[1;5r")

        view.withTerminal { _ in
            #expect(view.selection.active)
            #expect(view.selection.start.row == 1)
            #expect(view.selection.end.row == 1)
            #expect(view.selection.getSelectedText() == "LINE_3")
        }
    }

    @Test func frameColorPreservesSRGBAlpha() {
        let view = makeView()
        let captured = FrameColor(
            NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.25),
            view: view)

        #expect(abs(captured.red - 0.2) < 0.001)
        #expect(abs(captured.green - 0.4) < 0.001)
        #expect(abs(captured.blue - 0.6) < 0.001)
        #expect(abs(captured.alpha - 0.25) < 0.001)
    }

    @Test func mutationAfterSnapshotIsIsolatedUntilRefresh() throws {
        let view = makeView()
        view.feed(text: "before")
        let snapshot = TerminalSnapshot()
        #expect(refresh(snapshot, from: view) == .refreshed)
        let row = try #require(snapshot.rows.first)
        let captured = text(in: row, cols: snapshot.cols)
        let capturedArena = row.line.cellArena

        view.feed(text: "-after")
        #expect(text(in: row, cols: snapshot.cols) == captured)

        #expect(refresh(snapshot, from: view) == .refreshed)
        #expect(text(in: try #require(snapshot.rows.first), cols: snapshot.cols)
            .hasPrefix("before-after"))
        #expect(snapshot.rows.first?.line.cellArena === capturedArena)
    }

#if DEBUG
    @Test func unchangedRowsUseGenerationSkip() {
        let view = makeView()
        let snapshot = TerminalSnapshot()
        #expect(refresh(snapshot, from: view) == .refreshed)

        view.feed(text: "x")
        #expect(refresh(snapshot, from: view) == .refreshed)
        #expect(snapshot.rowsCopied == 1)
        #expect(snapshot.rowsSkipped == snapshot.rows.count - 1)
    }
#endif

    @Test func extendedGraphemeIsResolvedInSnapshot() throws {
        let view = makeView()
        let grapheme: Character = "e\u{301}"
        view.feed(text: String(grapheme))
        let snapshot = TerminalSnapshot()
        #expect(refresh(snapshot, from: view) == .refreshed)

        let row = try #require(snapshot.rows.first)
        #expect(!row.line.packedView(at: 0).isSimpleRune)
        #expect(row.resolvedCharacters[0] == grapheme)
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view),
                                            snapshot: snapshot)
        let rendered = view.textBuilder.buildAttributedString(row: row,
                                                  absoluteRow: snapshot.firstRow,
                                                  context: context)
        #expect(rendered.segments.map { $0.attributedString.string }.joined()
            .hasPrefix(String(grapheme)))
    }

    @Test func gb9cGraphemePreservesAllTextInSnapshot() throws {
        let view = makeView()
        let grapheme = "\u{A98F}\u{A9C0}\u{A994}\u{A9B8}"
        view.feed(text: grapheme)
        let snapshot = TerminalSnapshot()
        #expect(refresh(snapshot, from: view) == .refreshed)

        let row = try #require(snapshot.rows.first)
        #expect(row.resolvedText[0] == grapheme)
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view),
                                            snapshot: snapshot)
        let rendered = view.textBuilder.buildAttributedString(
            row: row, absoluteRow: snapshot.firstRow, context: context)
        #expect(rendered.segments.map { $0.attributedString.string }.joined()
            .hasPrefix(grapheme))
    }

    @Test func middleWrappedRtlEditRefreshesDependentRows() throws {
        let view = makeView(cols: 5, rows: 4)
        view.feed(text: "אבגדהוזחטיכל")
        let snapshot = TerminalSnapshot()
        #expect(refresh(snapshot, from: view) == .refreshed)
        let before = snapshot.rows.prefix(3).map(\.revision)
        let beforeBidi = snapshot.rows.prefix(3).map(\.bidiParagraphRevision)
        #expect(snapshot.rows[1].line.isWrapped)
        #expect(snapshot.rows[2].line.isWrapped)

        view.feed(text: "\u{1b}[2;2Hמ")
        #expect(refresh(snapshot, from: view) == .refreshed)

        let after = snapshot.rows.prefix(3).map(\.revision)
        let afterBidi = snapshot.rows.prefix(3).map(\.bidiParagraphRevision)
        #expect(afterBidi.allSatisfy { $0 != beforeBidi[0] })
        #expect(zip(after, before).allSatisfy { $0 > $1 })
    }

    @Test func deferredLtrLayoutResetsCursorVisualColumn() throws {
        let view = TerminalView(
            frame: .zero,
            font: nil,
            options: TerminalOptions(
                cols: 12,
                rows: 4,
                scrollback: 20,
                initialBidiState: BidiPresentationState(
                    autodetectDirection: true,
                    fallbackDirection: .rightToLeft)))
        let snapshot = TerminalSnapshot()
        view.feed(text: "אבג")

        #expect(refresh(snapshot, from: view,
                        deferBidiTypesetting: true) == .refreshed)
        snapshot.completePendingBidi()
        let rtlCursor = try #require(snapshot.cursor)
        #expect(rtlCursor.visualCol != rtlCursor.logicalCol)

        view.feed(text: "\r\u{1b}[2Kabc")
        #expect(refresh(snapshot, from: view,
                        deferBidiTypesetting: true) == .refreshed)
        #expect(snapshot.cursor?.visualCol == rtlCursor.visualCol)

        snapshot.completePendingBidi()

        #expect(snapshot.rows.first?.bidiLayout == nil)
        #expect(snapshot.cursor?.logicalCol == 3)
        #expect(snapshot.cursor?.visualCol == snapshot.cursor?.logicalCol)
    }

    @Test func synchronizedOutputFreezesExistingRows() throws {
        let view = makeView()
        view.feed(text: "stable")
        let snapshot = TerminalSnapshot()
        #expect(refresh(snapshot, from: view) == .refreshed)
        let row = try #require(snapshot.rows.first)
        let captured = text(in: row, cols: snapshot.cols)
        let revision = row.revision

        view.feed(text: "\u{1b}[?2026h-mutated")
        #expect(refresh(snapshot, from: view) == .frozen)
        #expect(text(in: row, cols: snapshot.cols) == captured)
        #expect(row.revision == revision)

        view.feed(text: "\u{1b}[?2026l")
    }
}
#endif
