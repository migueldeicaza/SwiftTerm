import Testing
@testable import SwiftTerm

struct PortableRenderSnapshotTests {
    final class ResizeProbe: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        var columns: Int?
        var rows: Int?
        func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? {
            if case .resizeTerminal(let columns, let rows) = command {
                self.columns = columns
                self.rows = rows
            }
            return nil
        }
    }

    @Test func resizeRequestUsesRowsThenColumns() {
        let delegate = ResizeProbe()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: "\u{1b}[8;20;60t")
        #expect(delegate.columns == 60)
        #expect(delegate.rows == 20)
    }

    private func terminal(cols: Int = 8, rows: Int = 4) -> Terminal {
        TerminalTestHarness.makeTerminal(cols: cols, rows: rows).0
    }

    @Test func emptyAndClean() {
        let terminal = terminal()
        let first = terminal.makeRenderSnapshot(scope: .dirty)
        #expect(first.dirtyKind == .full)
        #expect(first.dirtyRange?.endY == 3)
        #expect(first.scrollDirtyRange?.endY == 3)
        #expect(first.lines.count == 4)
        #expect(first.palette.count == 256)
        #expect(first.lines.allSatisfy { $0.cells.count == 8 && $0.cells.allSatisfy { $0.text.isEmpty && $0.width == 1 } })
        #expect(terminal.makeRenderSnapshot(scope: .dirty).dirtyKind == .full)
        terminal.clearUpdateRange()
        let clean = terminal.makeRenderSnapshot(scope: .dirty)
        #expect(clean.dirtyKind == .clean)
        #expect(clean.lines.isEmpty)
        #expect(terminal.makeRenderSnapshot(scope: .full).lines.count == 4)
    }

    @Test func textIsAnOwnedCopy() {
        let terminal = terminal()
        terminal.feed(text: "Ae\u{301}中")
        let snapshot = terminal.makeRenderSnapshot(scope: .full)
        #expect(snapshot.lines[0].cells[0].text == "A")
        #expect(snapshot.lines[0].cells[1].text == "e\u{301}")
        #expect(snapshot.lines[0].cells[2].width == 2)
        #expect(snapshot.lines[0].cells[3].widthState == .spacerTail)
        #expect(snapshot.lines[0].cells[3].text.isEmpty)
        terminal.feed(text: "\u{1b}[2J\u{1b}[Hnew")
        #expect(snapshot.lines[0].cells[0].text == "A")
        #expect(snapshot.lines[0].cells[1].text == "e\u{301}")
    }

    @Test func cursorDamageIncludesBothRows() {
        let terminal = terminal()
        _ = terminal.makeRenderSnapshot(scope: .full)
        terminal.clearUpdateRange()
        terminal.feed(text: "\u{1b}[3;2H")
        let snapshot = terminal.makeRenderSnapshot(scope: .dirty)
        #expect(snapshot.dirtyRange?.startY == 0)
        #expect(snapshot.dirtyRange?.endY == 2)
        #expect(snapshot.cursor.x == 1)
        #expect(snapshot.cursor.y == 2)
        #expect(snapshot.lines.map(\.y) == [0, 1, 2])
        terminal.clearUpdateRange()
        #expect(terminal.makeRenderSnapshot(scope: .dirty).dirtyKind == .clean)
    }

    @Test func paletteAndDefaultColorsCauseFullDamage() {
        let terminal = terminal()
        _ = terminal.makeRenderSnapshot(scope: .full)
        terminal.clearUpdateRange()
        terminal.feed(text: "\u{1b}]4;1;#123456\u{7}")
        let palette = terminal.makeRenderSnapshot(scope: .dirty)
        #expect(palette.dirtyKind == .full)
        #expect(palette.palette[1].red == 0x1212)
        terminal.clearUpdateRange()
        terminal.foregroundColor = Color(red: 1, green: 2, blue: 3)
        let changed = terminal.makeRenderSnapshot(scope: .dirty)
        #expect(changed.dirtyKind == .full)
        #expect(changed.foregroundColor.red == 1)
        #expect(palette.foregroundColor.red != 1)
    }

    @Test func colorsAndAttributesRemainSemantic() {
        let terminal = terminal()
        terminal.feed(text: "\u{1b}[1;2;3;4:3;5;7;8;9;38;2;1;2;3;48;5;123;58;2;4;5;6mX")
        let cell = terminal.makeRenderSnapshot(scope: .full).lines[0].cells[0]
        #expect(cell.attribute.fg == .trueColor(red: 1, green: 2, blue: 3))
        #expect(cell.attribute.bg == .ansi256(code: 123))
        #expect(cell.attribute.style.rawValue == 255)
        #expect(cell.attribute.underlineStyle == .curly)
        #expect(cell.attribute.underlineColor == .trueColor(red: 4, green: 5, blue: 6))
    }

    @Test func wrappingAndRenderMode() {
        let terminal = terminal(cols: 4)
        terminal.feed(text: "abc中")
        let snapshot = terminal.makeRenderSnapshot(scope: .full)
        #expect(snapshot.lines[0].wrapsToNext)
        #expect(!snapshot.lines[0].isWrapped)
        #expect(snapshot.lines[1].isWrapped)
        // The parser can leave a narrow blank at this boundary. Also check
        // the distinct spacer state that reflow and packed storage can use.
        let line = terminal.buffer.lines[0]
        line.setPackedCell(line.packedCell(at: 3).replacingWidthState(.spacerHead), at: 3)
        let spacer = terminal.makeRenderSnapshot(scope: .full).lines[0].cells[3]
        #expect(spacer.widthState == .spacerHead)
        #expect(spacer.width == 0)
        #expect(spacer.text.isEmpty)
        terminal.clearUpdateRange()
        terminal.feed(text: "\u{1b}#6")
        let double = terminal.makeRenderSnapshot(scope: .dirty)
        #expect(double.dirtyKind == .full)
        #expect(double.lines[1].renderMode == .doubleWidth)
    }

    @Test func bufferReverseCursorAndSyncState() {
        let terminal = terminal()
        _ = terminal.makeRenderSnapshot(scope: .full)
        terminal.clearUpdateRange()
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[?5h\u{1b}[?25l\u{1b}[6 q\u{1b}[?2026h")
        let snapshot = terminal.makeRenderSnapshot(scope: .dirty)
        #expect(snapshot.dirtyKind == .full)
        #expect(snapshot.isAlternateScreen)
        #expect(snapshot.reverseVideo)
        #expect(snapshot.cursor.hidden)
        #expect(snapshot.cursor.style == .steadyBar)
        #expect(!snapshot.cursor.blink)
        #expect(snapshot.synchronizedOutputActive)
        terminal.feed(text: "\u{1b}[?2026l")
    }

    @Test func protectionSemanticAndPayloadAreCopied() {
        let terminal = terminal()
        terminal.feed(text: "\u{1b}]133;A\u{7}\u{1b}]8;;https://example.test\u{7}X")
        let line = terminal.buffer.lines[0]
        line.setPackedCell(line.packedCell(at: 0).replacingProtection(true), at: 0)
        let cell = terminal.makeRenderSnapshot(scope: .full).lines[0].cells[0]
        #expect(cell.isProtected)
        #expect(cell.semanticContent == .prompt(.initial))
        #expect(cell.payloadID != nil)
    }

    @Test func resetAndResizeInvalidateAllRows() {
        let terminal = terminal()
        _ = terminal.makeRenderSnapshot(scope: .full)
        terminal.clearUpdateRange()
        terminal.resetToInitialState()
        #expect(terminal.makeRenderSnapshot(scope: .dirty).dirtyKind == .full)
        terminal.clearUpdateRange()
        terminal.resize(cols: 12, rows: 6)
        let resized = terminal.makeRenderSnapshot(scope: .dirty)
        #expect(resized.dirtyKind == .full)
        #expect(resized.lines.count == 6)
        #expect(resized.lines.allSatisfy { $0.cells.count == 12 })
    }

    @Test func scrollRangeKeepsBufferCoordinates() {
        let terminal = terminal(cols: 8, rows: 2)
        terminal.feed(text: "a\r\nb\r\nc\r\nd")
        let full = terminal.makeRenderSnapshot(scope: .full)
        #expect(full.scrollDirtyRange?.startY == terminal.buffer.yDisp)
        #expect(full.scrollDirtyRange?.endY == terminal.buffer.yDisp + 1)
        terminal.clearUpdateRange()
        terminal.feed(text: "X")
        let snapshot = terminal.makeRenderSnapshot(scope: .dirty)
        #expect(snapshot.scrollDirtyRange?.startY == terminal.buffer.yDisp + 1)
        #expect(snapshot.dirtyRange?.startY == 1)
        #expect(snapshot.dirtyRange?.endY == 1)
    }
}
