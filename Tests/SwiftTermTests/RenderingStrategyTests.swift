#if canImport(AppKit)
import AppKit
import Testing
@testable import SwiftTerm

@MainActor
final class RenderingStrategyTests {
    private func makeView(cols: Int = 40, rows: Int = 10) -> TerminalView {
        let width = CGFloat(cols) * 8
        let height = CGFloat(rows) * 16
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.resize(cols: cols, rows: rows)
        return view
    }

    private func installLine(in view: TerminalView,
                             cells: [TerminalTestHarness.BufferCell],
                             viewportRow: Int = 0) -> (line: BufferLine, bufferRow: Int) {
        let displayBuffer = view.terminal.displayBuffer
        let bufferRow = displayBuffer.yDisp + viewportRow
        let line = TerminalTestHarness.makeBufferLine(columns: displayBuffer.cols, cells: cells)
        displayBuffer.lines[bufferRow] = line
        return (line, bufferRow)
    }

    private func renderOutput(for view: TerminalView,
                              line: BufferLine,
                              bufferRow: Int,
                              strategy: RenderingStrategy) -> LineRenderOutput {
        view.setRenderingStrategy(strategy)
        return view.lineRenderOutput(row: bufferRow,
                                     bufferRow: bufferRow,
                                     line: line,
                                     cols: view.terminal.displayBuffer.cols)
    }

    private func attributeRuns(for attributedString: NSAttributedString) -> [(range: NSRange, attributes: NSDictionary)] {
        var runs: [(range: NSRange, attributes: NSDictionary)] = []
        attributedString.enumerateAttributes(in: NSRange(location: 0, length: attributedString.length)) { attributes, range, _ in
            runs.append((range, attributes as NSDictionary))
        }
        return runs
    }

    private func assertAttributedStringsEqual(_ lhs: NSAttributedString,
                                              _ rhs: NSAttributedString,
                                              segmentIndex: Int) {
        #expect(lhs.length == rhs.length, "Segment \(segmentIndex) length mismatch")
        #expect(lhs.string == rhs.string, "Segment \(segmentIndex) string mismatch")

        let lhsRuns = attributeRuns(for: lhs)
        let rhsRuns = attributeRuns(for: rhs)
        #expect(lhsRuns.count == rhsRuns.count, "Segment \(segmentIndex) attribute run count mismatch")
        for (runIndex, (left, right)) in zip(lhsRuns, rhsRuns).enumerated() {
            #expect(NSEqualRanges(left.range, right.range), "Segment \(segmentIndex) range mismatch at run \(runIndex)")
            #expect(left.attributes.isEqual(right.attributes), "Segment \(segmentIndex) attributes mismatch at run \(runIndex)")
        }
    }

    private func assertPlaceholdersEqual(_ lhs: [KittyPlaceholderCell],
                                         _ rhs: [KittyPlaceholderCell]) {
        #expect(lhs.count == rhs.count, "Placeholder count mismatch")
        for (index, pair) in zip(lhs, rhs).enumerated() {
            let (left, right) = pair
            #expect(left.row == right.row, "Placeholder \(index) row mismatch")
            #expect(left.col == right.col, "Placeholder \(index) col mismatch")
            #expect(left.imageId == right.imageId, "Placeholder \(index) image mismatch")
            #expect(left.placementId == right.placementId, "Placeholder \(index) placement mismatch")
            #expect(left.placeholderRow == right.placeholderRow, "Placeholder \(index) placeholder row mismatch")
            #expect(left.placeholderCol == right.placeholderCol, "Placeholder \(index) placeholder col mismatch")
            #expect(left.msb == right.msb, "Placeholder \(index) msb mismatch")
        }
    }

    private func assertLineInfoEqual(_ lhs: ViewLineInfo,
                                     _ rhs: ViewLineInfo) {
        #expect(lhs.segments.count == rhs.segments.count, "Segment count mismatch")
        for (index, pair) in zip(lhs.segments, rhs.segments).enumerated() {
            let (legacy, cached) = pair
            #expect(legacy.column == cached.column, "Segment \(index) column mismatch")
            #expect(legacy.columnWidth == cached.columnWidth, "Segment \(index) width mismatch")
            #expect(legacy.characterCount == cached.characterCount, "Segment \(index) character count mismatch")
            assertAttributedStringsEqual(legacy.attributedString, cached.attributedString, segmentIndex: index)
        }

        switch (lhs.images, rhs.images) {
        case (nil, nil):
            break
        case let (left?, right?):
            #expect(left.count == right.count, "Image count mismatch")
        default:
            Issue.record("Image presence mismatch between rendering strategies")
        }

        assertPlaceholdersEqual(lhs.kittyPlaceholders, rhs.kittyPlaceholders)
    }

    @Test
    func testLegacyAndCachedRenderersProduceEquivalentSegmentsForSelectionAndUrls() {
        let view = makeView(cols: 16, rows: 4)
        let baseAttr = Attribute(fg: .ansi256(code: 34), bg: .defaultColor, style: .none)
        let selectionAttr = Attribute(fg: .trueColor(red: 10, green: 200, blue: 90),
                                      bg: .defaultInvertedColor,
                                      style: [.underline, .italic],
                                      underlineColor: .ansi256(code: 196))
        let wideAttr = Attribute(fg: .ansi256(code: 40),
                                 bg: .defaultColor,
                                 style: [.bold],
                                 underlineColor: .trueColor(red: 128, green: 32, blue: 200))

        guard let urlAtom = TinyAtom.lookup(value: "https://swift.org") else {
            Issue.record("Failed to allocate TinyAtom for test payload")
            return
        }

        let cells: [TerminalTestHarness.BufferCell] = [
            .init("H", attribute: baseAttr),
            .init("e", attribute: baseAttr),
            .init("語", attribute: wideAttr, width: 2, payload: urlAtom),
            .init("l", attribute: selectionAttr),
            .init("l", attribute: selectionAttr),
            .init("o", attribute: selectionAttr)
        ]

        let (line, bufferRow) = installLine(in: view, cells: cells)
        view.selection.setSelection(start: Position(col: 2, row: bufferRow),
                                    end: Position(col: 5, row: bufferRow))

        let legacy = renderOutput(for: view, line: line, bufferRow: bufferRow, strategy: .legacy)
        let cached = renderOutput(for: view, line: line, bufferRow: bufferRow, strategy: .cached)

        assertLineInfoEqual(legacy.lineInfo, cached.lineInfo)
        #expect(legacy.ctLines.count == cached.ctLines.count, "CTLine count mismatch")
    }

    @Test
    func testLegacyAndCachedRenderersAgreeOnKittyPlaceholders() {
        let view = makeView(cols: 12, rows: 4)
        let placeholderSequence = "\u{10EEEE}\u{0305}\u{0306}AB"
        view.terminal.feed(text: placeholderSequence)

        let displayBuffer = view.terminal.displayBuffer
        let bufferRow = displayBuffer.yDisp
        let line = displayBuffer.lines[bufferRow]

        let legacy = renderOutput(for: view, line: line, bufferRow: bufferRow, strategy: .legacy)
        let cached = renderOutput(for: view, line: line, bufferRow: bufferRow, strategy: .cached)

        assertLineInfoEqual(legacy.lineInfo, cached.lineInfo)
        #expect(!legacy.lineInfo.kittyPlaceholders.isEmpty, "Expected kitty placeholders in legacy output")
    }
}
#endif
