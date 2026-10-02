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
}
