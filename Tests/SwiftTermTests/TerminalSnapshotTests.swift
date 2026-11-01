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

    @Test func viewStateReportsBracketedPasteMode() {
        let view = makeView()

        #expect(!view.terminalStateSnapshot().bracketedPasteMode)

        view.feed(text: "\u{1b}[?2004h")
        #expect(view.terminalStateSnapshot().bracketedPasteMode)

        view.feed(text: "\u{1b}[?2004l")
        #expect(!view.terminalStateSnapshot().bracketedPasteMode)
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

    @Test func outputPreservesSelectionWhenItWritesTheSameText() {
        let view = makeView()
        view.feed(text: "selected\r\none")
        view.withTerminal { _ in
            view.selection.setSelection(
                start: Position(col: 0, row: 0),
                end: Position(col: 8, row: 0))
        }

        view.feed(text: "\u{1b}[1;1Hselected")

        view.withTerminal { _ in
            #expect(view.selection.active)
            #expect(view.selection.getSelectedText() == "selected")
        }
    }

    /// A shell's prompt mark arriving on a selected row leaves the selected
    /// text as it was.
    @Test func outputPreservesSelectionWhenAPromptMarkOnItChanges() {
        let view = makeView()
        view.feed(text: "$ make\r\none")
        view.withTerminal { _ in
            view.selection.setSelection(
                start: Position(col: 0, row: 0),
                end: Position(col: 6, row: 0))
        }

        view.feed(text: "\u{1b}[1;1H\u{1b}]133;A\u{7}")

        view.withTerminal { terminal in
            #expect(terminal.buffer.lines[0].semanticMarks.contains { $0.kind == .initial })
            #expect(view.selection.active)
            #expect(view.selection.getSelectedText() == "$ make")
        }
    }

    /// DECCOLM resizes every line, but a selection above the screen holds the
    /// same cells after it, wider or narrower.
    @Test func aColumnModeChangeKeepsASelectionAboveTheScreen() {
        let view = makeView()
        view.feed(text: "hello\r\n1\r\n2\r\n3\r\n4")
        view.withTerminal { terminal in
            #expect(terminal.buffer.yBase == 1)
            view.selection.setSelection(
                start: Position(col: 0, row: 0),
                end: Position(col: 5, row: 0))
        }

        view.feed(text: "\u{1b}[?40h\u{1b}[?3h")

        view.withTerminal { terminal in
            #expect(terminal.cols == 132)
            #expect(view.selection.active)
            #expect(view.selection.getSelectedText() == "hello")
        }

        view.feed(text: "\u{1b}[?3l")

        view.withTerminal { terminal in
            #expect(terminal.cols == 80)
            #expect(view.selection.active)
            #expect(view.selection.getSelectedText() == "hello")
        }
    }

    @Test func aColumnModeChangeKeepsAPartialSelectionWhenOtherTextReflows() {
        let view = makeView(cols: 132)
        view.feed(text: "hello" + String(repeating: " ", count: 95) + "tail\r\n1\r\n2\r\n3\r\n4")
        view.withTerminal { terminal in
            #expect(terminal.buffer.yBase == 1)
            view.selection.setSelection(
                start: Position(col: 0, row: 0),
                end: Position(col: 5, row: 0))
        }

        view.feed(text: "\u{1b}[?40h\u{1b}[?3l")

        view.withTerminal { terminal in
            #expect(terminal.cols == 80)
            #expect(terminal.buffer.lines[1].isWrapped)
            #expect(view.selection.active)
            #expect(view.selection.getSelectedText() == "hello")
        }
    }

    /// Blank cells a resize adds or drops leave a line's content as it was,
    /// but dropping text changes it, so a selection over the blanks that
    /// widening adds again is cleared.
    @Test func aResizeChangesTheLineContentOnlyWhenItDropsOrAddsText() {
        let line = BufferLine(cols: 6)
        line[4] = CharData(attribute: CharData.defaultAttr, code: 65, size: 1)
        let generation = line.contentGeneration

        line.resize(cols: 8, fillData: CharData.Null)
        line.resize(cols: 6, fillData: CharData.Null)
        #expect(line.contentGeneration == generation)

        line.resize(cols: 4, fillData: CharData.Null)
        #expect(line.contentGeneration != generation)

        let narrowed = line.contentGeneration
        line.resize(cols: 6, fillData: CharData(attribute: CharData.defaultAttr, code: 66, size: 1))
        #expect(line.contentGeneration != narrowed)
    }

    /// Complete history rows use their content generation. Only screen rows
    /// and the partial rows at a selection's boundaries need copied cells.
    @Test func outputUnderALargeSelectionCopiesOnlyScreenAndPartialRows() throws {
        let view = TerminalView(frame: .zero, font: nil,
                                options: TerminalOptions(cols: 200, rows: 50, scrollback: 10_000))
        let line = String(repeating: "y", count: 199)
        view.feed(text: (1...6_000).map { _ in line }.joined(separator: "\r\n"))
        view.withTerminal { _ in
            view.selection.setSelection(
                start: Position(col: 1, row: 0),
                end: Position(col: 198, row: 4_999))
        }

        try view.withTerminal { terminal in
            #expect(terminal.buffer.yBase > 4_999)
            let snapshot = try #require(view.selection.captureSelectedContent())
            #expect(snapshot.rows.count == 5_000)
            #expect(snapshot.rows.dropFirst().dropLast().allSatisfy { $0.cells == nil })
            #expect(snapshot.rows.first?.cells?.count == 199)
            #expect(snapshot.rows.last?.cells?.count == 198)
        }

        let batch = (1...10).map { "out \($0)" }.joined(separator: "\r\n") + "\r\n"
        for _ in 0..<20 {
            view.feed(text: batch)
        }

        view.withTerminal { _ in
            #expect(view.selection.active)
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

    @Test func multiCharacterCellUsesFullScalarCountForBidiIsolation() throws {
        let view = makeView()
        view.feed(text: "אxx")
        view.withTerminal { terminal in
            let scalars: [UInt32] = [0x61, 0x62]
            let cell = terminal.buffer.cellArena.pack(
                styleID: 0, scalars: scalars, widthState: .narrow)!
            terminal.buffer.lines[terminal.buffer.yBase].setPackedCell(cell, at: 1)
        }

        let snapshot = TerminalSnapshot()
        #expect(refresh(snapshot, from: view) == .refreshed)
        let row = try #require(snapshot.rows.first)
        #expect(row.bidiLayout != nil)
        #expect(row.resolvedText[1] == "ab")

        let context = SnapshotRenderContext(viewState: FrameViewState(view: view),
                                            snapshot: snapshot)
        let rendered = view.textBuilder.buildAttributedString(
            row: row, absoluteRow: snapshot.firstRow, context: context)
        let isolated = try #require(rendered.segments.first {
            $0.attributedString.string == "ab"
        })
        #expect(isolated.columnWidth == 1)
        #expect(isolated.characterCount == 1)
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
