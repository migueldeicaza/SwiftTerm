import XCTest
@testable import SwiftTerm

final class TerminalTestDelegate: TerminalDelegate {
    private(set) var sentData: [[UInt8]] = []

    func showCursor(source: Terminal) {}
    func hideCursor(source: Terminal) {}
    func setTerminalTitle(source: Terminal, title: String) {}
    func setTerminalIconTitle(source: Terminal, title: String) {}
    func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { return nil }
    func sizeChanged(source: Terminal) {}
    func scrolled(source: Terminal, yDisp: Int) {}
    func linefeed(source: Terminal) {}
    func bufferActivated(source: Terminal) {}
    func bell(source: Terminal) {}

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        sentData.append(Array(data))
    }
}

enum TerminalTestHarness {
    static func makeTerminal(cols: Int = 80, rows: Int = 24, scrollback: Int = 0) -> (terminal: Terminal, delegate: TerminalTestDelegate) {
        let delegate = TerminalTestDelegate()
        let options = TerminalOptions(cols: cols, rows: rows, scrollback: scrollback)
        let terminal = Terminal(delegate: delegate, options: options)
        return (terminal, delegate)
    }

    static func visibleLinesText(buffer: Buffer, trimRight: Bool = true) -> [String] {
        let start = buffer.yDisp
        let end = min(buffer.yDisp + buffer.rows, buffer.lines.count)
        guard start < end else { return [] }
        return (start..<end).map { bufferLineText(buffer: buffer, lineIndex: $0, trimRight: trimRight) }
    }

    static func lineText(buffer: Buffer, row: Int, trimRight: Bool = true) -> String? {
        guard row >= 0, row < buffer.rows else { return nil }
        let index = buffer.yDisp + row
        guard index >= 0, index < buffer.lines.count else { return nil }
        return bufferLineText(buffer: buffer, lineIndex: index, trimRight: trimRight)
    }

    static func charData(buffer: Buffer, row: Int, col: Int) -> CharData? {
        guard row >= 0, row < buffer.rows, col >= 0, col < buffer.cols else { return nil }
        let index = buffer.yDisp + row
        guard index >= 0, index < buffer.lines.count else { return nil }
        return buffer.lines[index][col]
    }

    static func isWrapped(buffer: Buffer, row: Int) -> Bool? {
        guard row >= 0, row < buffer.rows else { return nil }
        let index = buffer.yDisp + row
        guard index >= 0, index < buffer.lines.count else { return nil }
        return buffer.lines[index].isWrapped
    }

    static func cursorPosition(buffer: Buffer) -> Position {
        return Position(col: buffer.x, row: buffer.y)
    }

    static func assertCursor(_ buffer: Buffer, col: Int, row: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(buffer.x, col, file: file, line: line)
        XCTAssertEqual(buffer.y, row, file: file, line: line)
    }

    static func assertLineText(_ buffer: Buffer, row: Int, equals expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let actual = lineText(buffer: buffer, row: row) ?? ""
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

private func bufferLineText(buffer: Buffer, lineIndex: Int, trimRight: Bool) -> String {
    return buffer.translateBufferLineToString(
        lineIndex: lineIndex,
        trimRight: trimRight,
        startCol: 0,
        endCol: -1,
        skipNullCellsFollowingWide: true
    ).replacingOccurrences(of: "\u{0}", with: " ")
}
