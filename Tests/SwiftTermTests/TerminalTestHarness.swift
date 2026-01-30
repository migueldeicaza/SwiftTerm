import Testing
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
    struct BufferCell {
        let character: Character
        let attribute: Attribute
        let width: Int
        let payload: TinyAtom?

        init(_ character: Character,
             attribute: Attribute = .empty,
             width: Int = 1,
             payload: TinyAtom? = nil) {
            self.character = character
            self.attribute = attribute
            self.width = width
            self.payload = payload
        }
    }
    static func makeTerminal(cols: Int = 80, rows: Int = 24, scrollback: Int = 0) -> (terminal: Terminal, delegate: TerminalTestDelegate) {
        let delegate = TerminalTestDelegate()
        let options = TerminalOptions(cols: cols, rows: rows, scrollback: scrollback)
        let terminal = Terminal(delegate: delegate, options: options)
        return (terminal, delegate)
    }

    static func makeBufferLine(columns: Int, cells: [BufferCell], fill: CharData = .Null) -> BufferLine {
        let line = BufferLine(cols: columns, fillData: fill)
        var columnIndex = 0
        for cell in cells {
            guard columnIndex < columns else { break }
            guard let scalar = cell.character.unicodeScalars.first else {
                columnIndex += cell.width
                continue
            }
            var charData = CharData(attribute: cell.attribute, scalar: scalar, size: Int8(cell.width))
            if let payload = cell.payload {
                charData.setPayload(atom: payload)
            }
            line[columnIndex] = charData
            columnIndex += cell.width
        }
        return line
    }

    static func visibleLinesText(buffer: Buffer, terminal: Terminal? = nil, trimRight: Bool = true) -> [String] {
        let start = buffer.yDisp
        let end = min(buffer.yDisp + buffer.rows, buffer.lines.count)
        guard start < end else { return [] }
        let characterProvider = makeCharacterProvider(terminal)
        return (start..<end).map {
            bufferLineText(buffer: buffer, lineIndex: $0, trimRight: trimRight, characterProvider: characterProvider)
        }
    }

    static func lineText(buffer: Buffer, terminal: Terminal? = nil, row: Int, trimRight: Bool = true) -> String? {
        guard row >= 0, row < buffer.rows else { return nil }
        let index = buffer.yDisp + row
        guard index >= 0, index < buffer.lines.count else { return nil }
        return bufferLineText(
            buffer: buffer,
            lineIndex: index,
            trimRight: trimRight,
            characterProvider: makeCharacterProvider(terminal)
        )
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

    static func assertCursor(_ buffer: Buffer, col: Int, row: Int) {
        #expect(buffer.x == col)
        #expect(buffer.y == row)
    }

    static func assertLineText(_ buffer: Buffer, terminal: Terminal? = nil, row: Int, equals expected: String) {
        let actual = lineText(buffer: buffer, terminal: terminal, row: row) ?? ""
        #expect(actual == expected)
    }
}

private func bufferLineText(
    buffer: Buffer,
    lineIndex: Int,
    trimRight: Bool,
    characterProvider: ((CharData) -> Character)? = nil
) -> String {
    return buffer.translateBufferLineToString(
        lineIndex: lineIndex,
        trimRight: trimRight,
        startCol: 0,
        endCol: -1,
        skipNullCellsFollowingWide: true,
        characterProvider: characterProvider
    ).replacingOccurrences(of: "\u{0}", with: " ")
}

private func makeCharacterProvider(_ terminal: Terminal?) -> ((CharData) -> Character)? {
    guard let terminal else { return nil }
    return { terminal.getCharacter(for: $0) }
}
