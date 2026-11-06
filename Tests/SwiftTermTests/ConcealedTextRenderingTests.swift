#if os(macOS) && !SWIFTTERM_EMBEDDED
import AppKit
import Testing
@testable import SwiftTerm

@MainActor
@Suite("Concealed text (SGR 8) rendering")
struct ConcealedTextRenderingTests {
    private func render(_ text: String) throws -> (view: TerminalView, row: TerminalSnapshot.Row, firstRow: Int, context: SnapshotRenderContext) {
        let view = TerminalView(frame: .zero, font: nil,
                                options: TerminalOptions(cols: 12, rows: 4))
        view.frameDriver.invalidate()
        view.feed(text: text)
        let snapshot = TerminalSnapshot()
        view.withTerminal { terminal in
            _ = snapshot.refresh(terminal: terminal, viewState: FrameViewState(view: view),
                                 selection: SnapshotSelectionState(selection: view.selection))
        }
        let row = try #require(snapshot.rows.first)
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: snapshot)
        return (view, row, snapshot.firstRow, context)
    }

    @Test func shapedRowsDrawNoGlyphOrDecoration() throws {
        // A non-ASCII cell keeps the row off the plain-text path.
        let rendered = try render("\u{1b}[8;4;9;41mSé\u{1b}[0mV")
        let text = SnapshotTextBuilder().buildAttributedString(row: rendered.row, absoluteRow: rendered.firstRow,
                                                               context: rendered.context)
        let drawn = text.segments.map { $0.attributedString.string }.joined()
        #expect(!drawn.contains("S"))
        #expect(!drawn.contains("é"))
        #expect(drawn.contains("V"))
        let concealed = try #require(text.segments.first)
        let attributes = concealed.attributedString.attributes(at: 0, effectiveRange: nil)
        #expect(attributes[.underlineStyle] == nil)
        #expect(attributes[.strikethroughStyle] == nil)
        #expect(attributes[.backgroundColor] != nil)
    }

    @Test func plainRowsDrawNoGlyphOrDecoration() throws {
        let rendered = try render("\u{1b}[8;4;9;41mS\u{1b}[0mV")
        let plain = try #require(SnapshotTextBuilder().plainRow(row: rendered.row, absoluteRow: rendered.firstRow,
                                                                context: rendered.context))
        #expect(plain.codes[0] == 0x20)
        #expect(plain.codes[1] == UInt8(ascii: "V"))
        let run = try #require(plain.runs.first(where: { $0.start <= 0 && $0.end > 0 }))
        #expect(run.style.underline == nil)
        #expect(run.style.strikethrough == nil)
    }

    @Test func concealedTextStaysInTheBuffer() throws {
        let rendered = try render("\u{1b}[8mS")
        let text = rendered.view.withTerminal { $0.getText(col: 0, row: 0) }
        #expect(text == "S")
    }
}
#endif
