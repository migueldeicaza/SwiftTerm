#if canImport(AppKit)
import AppKit
import Testing
@testable import SwiftTerm

@MainActor
final class ViewLineInfoTests {
    private func makeView(cols: Int = 40, rows: Int = 10) -> TerminalView {
        let width = CGFloat(cols) * 8
        let height = CGFloat(rows) * 16
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.resize(cols: cols, rows: rows)
        return view
    }

    private func lineInfo(for view: TerminalView, row: Int) -> ViewLineInfo {
        let displayBuffer = view.terminal.displayBuffer
        let bufferRow = displayBuffer.yDisp + row
        let line = displayBuffer.lines[bufferRow]
        return view.buildAttributedString(row: bufferRow, line: line, cols: displayBuffer.cols)
    }

    private func installLine(_ line: BufferLine, in view: TerminalView, row: Int = 0) {
        let displayBuffer = view.terminal.displayBuffer
        let bufferRow = displayBuffer.yDisp + row
        displayBuffer.lines[bufferRow] = line
    }

    @Test func testSegmentsRespectWideCharacters() {
        let view = makeView(cols: 8, rows: 2)
        view.terminal.feed(text: "語!")

        let info = lineInfo(for: view, row: 0)
        guard let firstSegment = info.segments.first else {
            Issue.record("Expected at least one segment")
            return
        }

        #expect(firstSegment.columnWidth == 2)
        #expect(firstSegment.columnSpan == 2)
    }

    @Test func testMixedWidthsProduceDistinctSegments() {
        let view = makeView(cols: 8, rows: 1)
        let attr = Attribute(fg: .defaultColor, bg: .defaultInvertedColor, style: .none)
        let line = TerminalTestHarness.makeBufferLine(columns: view.terminal.cols, cells: [
            TerminalTestHarness.BufferCell("A", attribute: attr),
            TerminalTestHarness.BufferCell("語", attribute: attr, width: 2),
            TerminalTestHarness.BufferCell("B", attribute: attr)
        ])
        installLine(line, in: view)

        let segments = lineInfo(for: view, row: 0).segments
        #expect(segments.count == 3)
        #expect(segments[0].column == 0)
        #expect(segments[1].column == 1)
        #expect(segments[1].columnWidth == 2)
        #expect(segments[2].column == 3)
    }

    @Test func testSelectionAddsBackgroundAttribute() {
        let view = makeView(cols: 12, rows: 2)
        view.terminal.feed(text: "hello world")

        view.selection?.setSelection(start: Position(col: 0, row: view.terminal.displayBuffer.yDisp),
                                     end: Position(col: 4, row: view.terminal.displayBuffer.yDisp))

        let info = lineInfo(for: view, row: 0)
        let highlighted = info.segments.contains { segment in
            var found = false
            segment.attributedString.enumerateAttributes(in: NSRange(location: 0, length: segment.attributedString.length)) { attributes, _, stop in
                if attributes.keys.contains(.selectionBackgroundColor) {
                    found = true
                    stop.pointee = true
                }
            }
            return found
        }

        #expect(highlighted)
    }

    @Test func testUrlAttributesPreserved() {
        let view = makeView(cols: 6, rows: 1)
        let attr = Attribute(fg: .ansi256(code: 2), bg: .defaultInvertedColor, style: .none)
        guard let atom = TinyAtom.lookup(value: "https://example.com") else {
            Issue.record("Unable to allocate TinyAtom for url payload")
            return
        }
        let line = TerminalTestHarness.makeBufferLine(columns: view.terminal.cols, cells: [
            TerminalTestHarness.BufferCell("語", attribute: attr, width: 2, payload: atom),
            TerminalTestHarness.BufferCell("i", attribute: attr)
        ])
        installLine(line, in: view)

        let info = lineInfo(for: view, row: 0)
        #expect(info.segments.count == 2)
        guard let urlSegment = info.segments.first,
              info.segments.count > 1 else {
            Issue.record("Expected url and non-url segments")
            return
        }
        let nonUrlSegment = info.segments[1]

        let urlAttributes = urlSegment.attributedString.attributes(at: 0, effectiveRange: nil)
        let underlineStyle = urlAttributes[.underlineStyle] as? Int ?? 0
        #expect(underlineStyle & NSUnderlineStyle.patternDash.rawValue != 0)

        let nonUrlAttributes = nonUrlSegment.attributedString.attributes(at: 0, effectiveRange: nil)
        let secondaryStyle = nonUrlAttributes[.underlineStyle] as? Int ?? 0
        #expect(secondaryStyle == 0)
    }

    @Test func testKittyPlaceholderCollection() {
        let view = makeView(cols: 10, rows: 2)
        view.terminal.feed(text: "\u{10EEEE}\u{0305}\u{0305}")

        let info = lineInfo(for: view, row: 0)
        #expect(info.kittyPlaceholders.count == 1)
        guard let placeholder = info.kittyPlaceholders.first else {
            Issue.record("Expected kitty placeholder entry")
            return
        }
        #expect(placeholder.row == view.terminal.displayBuffer.yDisp)
        #expect(placeholder.placeholderRow == 0)
        #expect(placeholder.placeholderCol == 0)
    }

    @Test func testKittyPlaceholderHonorsEncodedCoordinates() {
        let view = makeView(cols: 10, rows: 2)
        let rowScalar: UInt32 = 0x030D
        let colScalar: UInt32 = 0x030E
        let placeholderScalar: UInt32 = 0x10EEEE
        let text = String(UnicodeScalar(placeholderScalar)!)
            + String(UnicodeScalar(rowScalar)!)
            + String(UnicodeScalar(colScalar)!)
        view.terminal.feed(text: text)

        let info = lineInfo(for: view, row: 0)
        guard let placeholder = info.kittyPlaceholders.first else {
            Issue.record("Expected kitty placeholder entry with explicit coordinates")
            return
        }

        let expectedRow = KittyPlaceholder.diacriticIndex[rowScalar] ?? -1
        let expectedCol = KittyPlaceholder.diacriticIndex[colScalar] ?? -1
        #expect(expectedRow >= 0)
        #expect(expectedCol >= 0)
        #expect(placeholder.placeholderRow == expectedRow)
        #expect(placeholder.placeholderCol == expectedCol)
    }
}
#endif
