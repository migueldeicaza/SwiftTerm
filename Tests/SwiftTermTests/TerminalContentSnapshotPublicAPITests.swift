import Testing
import SwiftTerm

struct TerminalContentSnapshotPublicAPITests {
    @Test func publicInitializersAreUsableWithoutTestableImport() {
        let dimensions = TerminalDimensions(cols: 2, rows: 1)
        let input = TerminalInputStateSnapshot(
            dimensions: dimensions,
            isAlternateBuffer: false,
            applicationCursor: false,
            applicationKeypad: false,
            bracketedPasteMode: false,
            mouseMode: .off,
            keyboardEnhancementFlags: [],
            focusReportingEnabled: false)
        let cell = TerminalCellSnapshot(text: "x", width: 1, attribute: .empty)
        let row = TerminalContentRowSnapshot(
            absoluteRow: 7,
            cells: [cell],
            isWrapped: true)
        let snapshot = TerminalContentSnapshot(
            inputState: input,
            capturedRange: 7..<8,
            liveTopRow: 7,
            rows: [row])

        #expect(snapshot.inputState.dimensions == dimensions)
        #expect(snapshot.rows.first?.isWrapped == true)
        #expect(snapshot.rows.first?.text == "x")
    }

    @Test func publicInitializerUsesDisplayRowTextConversion() {
        let row = TerminalContentRowSnapshot(
            absoluteRow: 8,
            cells: [
                TerminalCellSnapshot(text: "界", width: 2, attribute: .empty),
                TerminalCellSnapshot(text: "\u{0}", width: 0, attribute: .empty),
                TerminalCellSnapshot(text: "", width: 1, attribute: .empty),
                TerminalCellSnapshot(text: "x", width: 1, attribute: .empty),
                TerminalCellSnapshot(text: " ", width: 1, attribute: .empty),
                TerminalCellSnapshot(text: " ", width: 1, attribute: .empty),
                TerminalCellSnapshot(text: "\u{0}", width: 1, attribute: .empty),
            ],
            isWrapped: false)

        #expect(row.text == "界 x  ")
        #expect(!row.text.contains("\u{0}"))
    }

    @Test func publicInitializerHandlesOutOfRangeSyntheticWidths() {
        let row = TerminalContentRowSnapshot(
            absoluteRow: 9,
            cells: [
                TerminalCellSnapshot(text: "a", width: Int.max, attribute: .empty),
            ])

        #expect(row.text == "a")
    }
}
