import Testing
@testable import SwiftTerm

private let asciiA: UInt8 = 97
private let ascii0: UInt8 = 48
private let hanScalar = UnicodeScalar(0x6C49)!
private let yuScalar = UnicodeScalar(0x8BED)!
private let grinScalar = UnicodeScalar(0x1F601)!

private let hanString = String(hanScalar)
private let yuString = String(yuScalar)
private let grinString = String(grinScalar)

private func asciiScalar(_ value: UInt8) -> UnicodeScalar {
    UnicodeScalar(Int(value))!
}

private func makeBuffer(cols: Int, rows: Int, scrollback: Int?) -> Buffer {
    let buffer = Buffer(cols: cols, rows: rows, tabStopWidth: 8, scrollback: scrollback)
    buffer.scroll = { _ in }
    buffer.fillViewportRows()
    return buffer
}

private func lineText(
    _ buffer: Buffer,
    lineIndex: Int,
    trimRight: Bool = true,
    characterProvider: ((CharData) -> Character)? = nil
) -> String {
    buffer.translateBufferLineToString(
        lineIndex: lineIndex,
        trimRight: trimRight,
        startCol: 0,
        endCol: -1,
        skipNullCellsFollowingWide: true,
        characterProvider: characterProvider
    ).replacingOccurrences(of: "\u{0}", with: " ")
}

private func lineString(
    _ line: BufferLine,
    trimRight: Bool = true,
    characterProvider: ((CharData) -> Character)? = nil
) -> String {
    line.translateToString(
        trimRight: trimRight,
        startCol: 0,
        endCol: -1,
        skipNullCellsFollowingWide: true,
        characterProvider: characterProvider
    ).replacingOccurrences(of: "\u{0}", with: " ")
}

private func setAsciiSequence(_ line: BufferLine, start: UInt8, count: Int) {
    let limit = min(count, line.count)
    for i in 0..<limit {
        let scalar = UnicodeScalar(Int(start) + i)!
        line[i] = CharData(attribute: CharData.defaultAttr, scalar: scalar, size: 1)
    }
}

private func setChar(_ line: BufferLine, index: Int, scalar: UnicodeScalar, width: Int8 = 1) {
    line[index] = CharData(attribute: CharData.defaultAttr, scalar: scalar, size: width)
}

private func setWide(_ line: BufferLine, index: Int, scalar: UnicodeScalar) {
    setChar(line, index: index, scalar: scalar, width: 2)
    if index + 1 < line.count {
        line[index + 1] = CharData(attribute: CharData.defaultAttr, scalar: UnicodeScalar(0)!, size: 0)
    }
}

private func fillWideLine(_ line: BufferLine, scalars: [UnicodeScalar]) {
    var col = 0
    for scalar in scalars {
        if col >= line.count {
            break
        }
        setWide(line, index: col, scalar: scalar)
        col += 2
    }
}

private func prependBlankLines(_ buffer: Buffer, count: Int) {
    var lines: [BufferLine] = []
    lines.reserveCapacity(count)
    for _ in 0..<count {
        lines.append(buffer.getBlankLine(attribute: CharData.defaultAttr, isWrapped: false))
    }
    buffer.lines.splice(start: 0, deleteCount: 0, items: lines, change: { _ in })
}

private func assertWrappedLines(_ buffer: Buffer, expected: Set<Int>) {
    for i in 0..<buffer.lines.count {
        #expect(buffer.lines[i].isWrapped == expected.contains(i))
    }
}

private func makeReflowLargerBuffer() -> Buffer {
    let buffer = makeBuffer(cols: 2, rows: 10, scrollback: 10)
    setChar(buffer.lines[0], index: 0, scalar: asciiScalar(asciiA))
    setChar(buffer.lines[0], index: 1, scalar: asciiScalar(asciiA + 1))
    setChar(buffer.lines[1], index: 0, scalar: asciiScalar(asciiA + 2))
    setChar(buffer.lines[1], index: 1, scalar: asciiScalar(asciiA + 3))
    buffer.lines[1].isWrapped = true
    setChar(buffer.lines[2], index: 0, scalar: asciiScalar(asciiA + 4))
    setChar(buffer.lines[2], index: 1, scalar: asciiScalar(asciiA + 5))
    setChar(buffer.lines[3], index: 0, scalar: asciiScalar(asciiA + 6))
    setChar(buffer.lines[3], index: 1, scalar: asciiScalar(asciiA + 7))
    buffer.lines[3].isWrapped = true
    setChar(buffer.lines[4], index: 0, scalar: asciiScalar(asciiA + 8))
    setChar(buffer.lines[4], index: 1, scalar: asciiScalar(asciiA + 9))
    setChar(buffer.lines[5], index: 0, scalar: asciiScalar(asciiA + 10))
    setChar(buffer.lines[5], index: 1, scalar: asciiScalar(asciiA + 11))
    buffer.lines[5].isWrapped = true
    return buffer
}

private func makeReflowSmallerBuffer() -> Buffer {
    let buffer = makeBuffer(cols: 4, rows: 10, scrollback: 20)
    setAsciiSequence(buffer.lines[0], start: asciiA, count: 4)
    setAsciiSequence(buffer.lines[1], start: asciiA + 4, count: 4)
    setAsciiSequence(buffer.lines[2], start: asciiA + 8, count: 4)
    return buffer
}

final class ReflowPortedTests {
    @Test func testReflowDiscardWrappedLinesOutOfScrollback() {
        let buffer = makeBuffer(cols: 10, rows: 5, scrollback: 1)
        let lastLine = buffer.lines[3]
        setAsciiSequence(lastLine, start: asciiA, count: 10)

        buffer.y = 4
        buffer.resize(newCols: 2, newRows: 5)

        #expect(buffer.y == 4)
        #expect(buffer.yBase == 1)
        #expect(buffer.lines.count == 6)
        #expect(lineText(buffer, lineIndex: 0, trimRight: false) == "ab")
        #expect(lineText(buffer, lineIndex: 1, trimRight: false) == "cd")
        #expect(lineText(buffer, lineIndex: 2, trimRight: false) == "ef")
        #expect(lineText(buffer, lineIndex: 3, trimRight: false) == "gh")
        #expect(lineText(buffer, lineIndex: 4, trimRight: false) == "ij")
        #expect(lineText(buffer, lineIndex: 5, trimRight: false) == "  ")

        buffer.resize(newCols: 1, newRows: 5)

        #expect(buffer.y == 4)
        #expect(buffer.yBase == 1)
        #expect(buffer.lines.count == 6)
        #expect(lineText(buffer, lineIndex: 0, trimRight: false) == "f")
        #expect(lineText(buffer, lineIndex: 1, trimRight: false) == "g")
        #expect(lineText(buffer, lineIndex: 2, trimRight: false) == "h")
        #expect(lineText(buffer, lineIndex: 3, trimRight: false) == "i")
        #expect(lineText(buffer, lineIndex: 4, trimRight: false) == "j")
        #expect(lineText(buffer, lineIndex: 5, trimRight: false) == " ")

        buffer.resize(newCols: 10, newRows: 5)

        #expect(buffer.y == 1)
        #expect(buffer.yBase == 0)
        #expect(buffer.lines.count == 5)
        #expect(lineText(buffer, lineIndex: 0, trimRight: false) == "fghij" + String(repeating: " ", count: 5))
        #expect(lineText(buffer, lineIndex: 1, trimRight: false) == String(repeating: " ", count: 10))
        #expect(lineText(buffer, lineIndex: 2, trimRight: false) == String(repeating: " ", count: 10))
        #expect(lineText(buffer, lineIndex: 3, trimRight: false) == String(repeating: " ", count: 10))
        #expect(lineText(buffer, lineIndex: 4, trimRight: false) == String(repeating: " ", count: 10))
    }

    @Test func testReflowLargerRemovesCorrectRows() {
        let buffer = makeBuffer(cols: 10, rows: 10, scrollback: 10)
        buffer.y = 2
        setAsciiSequence(buffer.lines[0], start: asciiA, count: 10)
        setAsciiSequence(buffer.lines[1], start: ascii0, count: 10)

        #expect(buffer.lines.count == 10)
        #expect(lineText(buffer, lineIndex: 0, trimRight: false) == "abcdefghij")
        #expect(lineText(buffer, lineIndex: 1, trimRight: false) == "0123456789")
        for i in 2..<10 {
            #expect(lineText(buffer, lineIndex: i, trimRight: false) == String(repeating: " ", count: 10))
        }

        buffer.resize(newCols: 2, newRows: 10)

        #expect(buffer.yBase == 1)
        #expect(buffer.lines.count == 11)
        #expect(lineText(buffer, lineIndex: 0, trimRight: false) == "ab")
        #expect(lineText(buffer, lineIndex: 1, trimRight: false) == "cd")
        #expect(lineText(buffer, lineIndex: 2, trimRight: false) == "ef")
        #expect(lineText(buffer, lineIndex: 3, trimRight: false) == "gh")
        #expect(lineText(buffer, lineIndex: 4, trimRight: false) == "ij")
        #expect(lineText(buffer, lineIndex: 5, trimRight: false) == "01")
        #expect(lineText(buffer, lineIndex: 6, trimRight: false) == "23")
        #expect(lineText(buffer, lineIndex: 7, trimRight: false) == "45")
        #expect(lineText(buffer, lineIndex: 8, trimRight: false) == "67")
        #expect(lineText(buffer, lineIndex: 9, trimRight: false) == "89")
        #expect(lineText(buffer, lineIndex: 10, trimRight: false) == "  ")

        buffer.resize(newCols: 10, newRows: 10)

        #expect(buffer.yBase == 0)
        #expect(buffer.lines.count == 10)
        #expect(lineText(buffer, lineIndex: 0, trimRight: false) == "abcdefghij")
        #expect(lineText(buffer, lineIndex: 1, trimRight: false) == "0123456789")
        for i in 2..<10 {
            #expect(lineText(buffer, lineIndex: i, trimRight: false) == String(repeating: " ", count: 10))
        }
    }

    @Test func testReflowLargerViewportNotFilledMovesCursorUp() {
        let buffer = makeReflowLargerBuffer()
        buffer.y = 6

        buffer.resize(newCols: 4, newRows: 10)

        #expect(buffer.y == 3)
        #expect(buffer.yDisp == 0)
        #expect(buffer.yBase == 0)
        #expect(buffer.lines.count == 10)
        #expect(lineText(buffer, lineIndex: 0, trimRight: false) == "abcd")
        #expect(lineText(buffer, lineIndex: 1, trimRight: false) == "efgh")
        #expect(lineText(buffer, lineIndex: 2, trimRight: false) == "ijkl")
        for i in 3..<10 {
            #expect(lineText(buffer, lineIndex: i, trimRight: false) == String(repeating: " ", count: 4))
        }
        assertWrappedLines(buffer, expected: [])
    }

    @Test func testReflowLargerViewportFilledMovesCursorUp() {
        let buffer = makeReflowLargerBuffer()
        buffer.y = 9

        buffer.resize(newCols: 4, newRows: 10)

        #expect(buffer.y == 6)
        #expect(buffer.yDisp == 0)
        #expect(buffer.yBase == 0)
        #expect(buffer.lines.count == 10)
        #expect(lineText(buffer, lineIndex: 0, trimRight: false) == "abcd")
        #expect(lineText(buffer, lineIndex: 1, trimRight: false) == "efgh")
        #expect(lineText(buffer, lineIndex: 2, trimRight: false) == "ijkl")
        for i in 3..<10 {
            #expect(lineText(buffer, lineIndex: i, trimRight: false) == String(repeating: " ", count: 4))
        }
        assertWrappedLines(buffer, expected: [])
    }

    @Test func testReflowLargerAdjustsViewportWhenYdispMatchesYbase() {
        let buffer = makeReflowLargerBuffer()
        buffer.y = 9
        prependBlankLines(buffer, count: 10)
        buffer.yBase = 10
        buffer.yDisp = 10

        buffer.resize(newCols: 4, newRows: 10)

        #expect(buffer.y == 9)
        #expect(buffer.yDisp == 7)
        #expect(buffer.yBase == 7)
        #expect(buffer.lines.count == 17)
        for i in 0..<10 {
            #expect(lineText(buffer, lineIndex: i, trimRight: false) == String(repeating: " ", count: 4))
        }
        #expect(lineText(buffer, lineIndex: 10, trimRight: false) == "abcd")
        #expect(lineText(buffer, lineIndex: 11, trimRight: false) == "efgh")
        #expect(lineText(buffer, lineIndex: 12, trimRight: false) == "ijkl")
        for i in 13..<17 {
            #expect(lineText(buffer, lineIndex: i, trimRight: false) == String(repeating: " ", count: 4))
        }
        assertWrappedLines(buffer, expected: [])
    }

    @Test func testReflowLargerKeepsYdispWhenYdispDiffersFromYbase() {
        let buffer = makeReflowLargerBuffer()
        buffer.y = 9
        prependBlankLines(buffer, count: 10)
        buffer.yBase = 10
        buffer.yDisp = 5

        buffer.resize(newCols: 4, newRows: 10)

        #expect(buffer.y == 9)
        #expect(buffer.yDisp == 5)
        #expect(buffer.yBase == 7)
        #expect(buffer.lines.count == 17)
        for i in 0..<10 {
            #expect(lineText(buffer, lineIndex: i, trimRight: false) == String(repeating: " ", count: 4))
        }
        #expect(lineText(buffer, lineIndex: 10, trimRight: false) == "abcd")
        #expect(lineText(buffer, lineIndex: 11, trimRight: false) == "efgh")
        #expect(lineText(buffer, lineIndex: 12, trimRight: false) == "ijkl")
        for i in 13..<17 {
            #expect(lineText(buffer, lineIndex: i, trimRight: false) == String(repeating: " ", count: 4))
        }
        assertWrappedLines(buffer, expected: [])
    }

    @Test func testReflowSmallerViewportNotFilledMovesCursorDown() {
        let buffer = makeReflowSmallerBuffer()
        buffer.y = 3

        buffer.resize(newCols: 2, newRows: 10)

        #expect(buffer.y == 6)
        #expect(buffer.yDisp == 0)
        #expect(buffer.yBase == 0)
        #expect(buffer.lines.count == 10)
        #expect(lineText(buffer, lineIndex: 0, trimRight: false) == "ab")
        #expect(lineText(buffer, lineIndex: 1, trimRight: false) == "cd")
        #expect(lineText(buffer, lineIndex: 2, trimRight: false) == "ef")
        #expect(lineText(buffer, lineIndex: 3, trimRight: false) == "gh")
        #expect(lineText(buffer, lineIndex: 4, trimRight: false) == "ij")
        #expect(lineText(buffer, lineIndex: 5, trimRight: false) == "kl")
        for i in 6..<10 {
            #expect(lineText(buffer, lineIndex: i, trimRight: false) == "  ")
        }
        assertWrappedLines(buffer, expected: [1, 3, 5])
    }

    @Test func testReflowSmallerViewportFilledTrimsTop() {
        let buffer = makeReflowSmallerBuffer()
        buffer.y = 9

        buffer.resize(newCols: 2, newRows: 10)

        #expect(buffer.y == 9)
        #expect(buffer.yDisp == 3)
        #expect(buffer.yBase == 3)
        #expect(buffer.lines.count == 13)
        #expect(lineText(buffer, lineIndex: 0, trimRight: false) == "ab")
        #expect(lineText(buffer, lineIndex: 1, trimRight: false) == "cd")
        #expect(lineText(buffer, lineIndex: 2, trimRight: false) == "ef")
        #expect(lineText(buffer, lineIndex: 3, trimRight: false) == "gh")
        #expect(lineText(buffer, lineIndex: 4, trimRight: false) == "ij")
        #expect(lineText(buffer, lineIndex: 5, trimRight: false) == "kl")
        for i in 6..<13 {
            #expect(lineText(buffer, lineIndex: i, trimRight: false) == "  ")
        }
        assertWrappedLines(buffer, expected: [1, 3, 5])
    }

    @Test func testReflowSmallerAdjustsViewportWhenYdispMatchesYbase() {
        let buffer = makeReflowSmallerBuffer()
        buffer.y = 9
        prependBlankLines(buffer, count: 10)
        buffer.yBase = 10
        buffer.yDisp = 10

        buffer.resize(newCols: 2, newRows: 10)

        #expect(buffer.yDisp == 13)
        #expect(buffer.yBase == 13)
        #expect(buffer.lines.count == 23)
        for i in 0..<10 {
            #expect(lineText(buffer, lineIndex: i, trimRight: false) == "  ")
        }
        #expect(lineText(buffer, lineIndex: 10, trimRight: false) == "ab")
        #expect(lineText(buffer, lineIndex: 11, trimRight: false) == "cd")
        #expect(lineText(buffer, lineIndex: 12, trimRight: false) == "ef")
        #expect(lineText(buffer, lineIndex: 13, trimRight: false) == "gh")
        #expect(lineText(buffer, lineIndex: 14, trimRight: false) == "ij")
        #expect(lineText(buffer, lineIndex: 15, trimRight: false) == "kl")
        for i in 16..<23 {
            #expect(lineText(buffer, lineIndex: i, trimRight: false) == "  ")
        }
        assertWrappedLines(buffer, expected: [11, 13, 15])
    }

    @Test func testReflowSmallerKeepsYdispWhenYdispDiffersFromYbase() {
        let buffer = makeReflowSmallerBuffer()
        buffer.y = 9
        prependBlankLines(buffer, count: 10)
        buffer.yBase = 10
        buffer.yDisp = 5

        buffer.resize(newCols: 2, newRows: 10)

        #expect(buffer.yDisp == 5)
        #expect(buffer.yBase == 13)
        #expect(buffer.lines.count == 23)
        for i in 0..<10 {
            #expect(lineText(buffer, lineIndex: i, trimRight: false) == "  ")
        }
        #expect(lineText(buffer, lineIndex: 10, trimRight: false) == "ab")
        #expect(lineText(buffer, lineIndex: 11, trimRight: false) == "cd")
        #expect(lineText(buffer, lineIndex: 12, trimRight: false) == "ef")
        #expect(lineText(buffer, lineIndex: 13, trimRight: false) == "gh")
        #expect(lineText(buffer, lineIndex: 14, trimRight: false) == "ij")
        #expect(lineText(buffer, lineIndex: 15, trimRight: false) == "kl")
        for i in 16..<23 {
            #expect(lineText(buffer, lineIndex: i, trimRight: false) == "  ")
        }
        assertWrappedLines(buffer, expected: [11, 13, 15])
    }

    @Test func testReflowSmallerTrimsWhenBufferIsFull() {
        let buffer = makeReflowSmallerBuffer()
        buffer.changeHistorySize(10)
        prependBlankLines(buffer, count: 10)
        buffer.yBase = 10
        buffer.yDisp = 10
        buffer.y = 13

        buffer.resize(newCols: 2, newRows: 10)

        #expect(buffer.yDisp == 10)
        #expect(buffer.yBase == 10)
        #expect(buffer.lines.count == 20)
        for i in 0..<7 {
            #expect(lineText(buffer, lineIndex: i, trimRight: false) == "  ")
        }
        #expect(lineText(buffer, lineIndex: 7, trimRight: false) == "ab")
        #expect(lineText(buffer, lineIndex: 8, trimRight: false) == "cd")
        #expect(lineText(buffer, lineIndex: 9, trimRight: false) == "ef")
        #expect(lineText(buffer, lineIndex: 10, trimRight: false) == "gh")
        #expect(lineText(buffer, lineIndex: 11, trimRight: false) == "ij")
        #expect(lineText(buffer, lineIndex: 12, trimRight: false) == "kl")
        for i in 13..<20 {
            #expect(lineText(buffer, lineIndex: i, trimRight: false) == "  ")
        }
        assertWrappedLines(buffer, expected: [8, 10, 12])
    }

    @Test func testReflowShouldNotWrapEmptyLines() {
        let buffer = makeBuffer(cols: 10, rows: 10, scrollback: 10)
        #expect(buffer.lines.count == 10)

        buffer.resize(newCols: 5, newRows: 10)

        #expect(buffer.lines.count == 10)
    }

    @Test func testReflowShrinksRowLength() {
        let buffer = makeBuffer(cols: 10, rows: 10, scrollback: 10)

        buffer.resize(newCols: 5, newRows: 10)

        #expect(buffer.lines.count == 10)
        for i in 0..<10 {
            #expect(buffer.lines[i].count == 5)
        }
    }

    @Test func testReflowWrapAndUnwrapLines() {
        let buffer = makeBuffer(cols: 5, rows: 10, scrollback: 10)
        let firstLine = buffer.lines[0]
        setAsciiSequence(firstLine, start: asciiA, count: 5)
        buffer.y = 1

        #expect(lineText(buffer, lineIndex: 0, trimRight: false) == "abcde")

        buffer.resize(newCols: 1, newRows: 10)

        #expect(buffer.lines.count == 10)
        #expect(lineText(buffer, lineIndex: 0, trimRight: false) == "a")
        #expect(lineText(buffer, lineIndex: 1, trimRight: false) == "b")
        #expect(lineText(buffer, lineIndex: 2, trimRight: false) == "c")
        #expect(lineText(buffer, lineIndex: 3, trimRight: false) == "d")
        #expect(lineText(buffer, lineIndex: 4, trimRight: false) == "e")
        for i in 5..<10 {
            #expect(lineText(buffer, lineIndex: i, trimRight: false) == " ")
        }

        buffer.resize(newCols: 5, newRows: 10)

        #expect(buffer.lines.count == 10)
        #expect(lineText(buffer, lineIndex: 0, trimRight: false) == "abcde")
        for i in 1..<10 {
            #expect(lineText(buffer, lineIndex: i, trimRight: false) == String(repeating: " ", count: 5))
        }
    }

    @Test func testReflowTransfersCombinedCharData() {
        let buffer = makeBuffer(cols: 4, rows: 3, scrollback: 10)
        buffer.y = 2
        let line = buffer.lines[0]
        setChar(line, index: 0, scalar: asciiScalar(asciiA))
        setChar(line, index: 1, scalar: asciiScalar(asciiA + 1))
        setChar(line, index: 2, scalar: asciiScalar(asciiA + 2))
        line[3] = CharData(attribute: CharData.defaultAttr, scalar: grinScalar, size: 1)

        #expect(lineText(buffer, lineIndex: 0, trimRight: false) == "abc" + grinString)

        buffer.resize(newCols: 2, newRows: 3)

        #expect(lineText(buffer, lineIndex: 0, trimRight: false) == "ab")
        #expect(lineText(buffer, lineIndex: 1, trimRight: false) == "c" + grinString)
    }

    @Test func testReflowWrappedLinesEndingInZeroSpaceLarger() {
        let buffer = makeBuffer(cols: 4, rows: 10, scrollback: 10)
        buffer.y = 2
        setChar(buffer.lines[0], index: 0, scalar: asciiScalar(asciiA))
        setChar(buffer.lines[0], index: 1, scalar: asciiScalar(asciiA + 1))
        setChar(buffer.lines[1], index: 0, scalar: asciiScalar(asciiA + 2))
        setChar(buffer.lines[1], index: 1, scalar: asciiScalar(asciiA + 3))
        buffer.lines[1].isWrapped = true

        buffer.resize(newCols: 5, newRows: 10)

        #expect(buffer.yBase == 0)
        #expect(buffer.lines.count == 10)
        #expect(lineText(buffer, lineIndex: 0, trimRight: true) == "ab  c")
        #expect(lineText(buffer, lineIndex: 1, trimRight: false) == "d    ")

        buffer.resize(newCols: 6, newRows: 10)

        #expect(buffer.yBase == 0)
        #expect(buffer.lines.count == 10)
        #expect(lineText(buffer, lineIndex: 0, trimRight: true) == "ab  cd")
        #expect(lineText(buffer, lineIndex: 1, trimRight: false) == "      ")
    }

    @Test func testReflowWrappedLinesEndingInZeroSpaceSmaller() {
        let buffer = makeBuffer(cols: 4, rows: 10, scrollback: 10)
        buffer.y = 2
        setChar(buffer.lines[0], index: 0, scalar: asciiScalar(asciiA))
        setChar(buffer.lines[0], index: 1, scalar: asciiScalar(asciiA + 1))
        setChar(buffer.lines[1], index: 0, scalar: asciiScalar(asciiA + 2))
        setChar(buffer.lines[1], index: 1, scalar: asciiScalar(asciiA + 3))
        buffer.lines[1].isWrapped = true

        buffer.resize(newCols: 3, newRows: 10)

        #expect(buffer.y == 2)
        #expect(buffer.yBase == 0)
        #expect(buffer.lines.count == 10)
        #expect(lineText(buffer, lineIndex: 0, trimRight: false) == "ab ")
        #expect(lineText(buffer, lineIndex: 1, trimRight: false) == " cd")

        buffer.resize(newCols: 2, newRows: 10)

        #expect(buffer.y == 3)
        #expect(buffer.yBase == 0)
        #expect(buffer.lines.count == 10)
        #expect(lineText(buffer, lineIndex: 0, trimRight: false) == "ab")
        #expect(lineText(buffer, lineIndex: 1, trimRight: false) == "  ")
        #expect(lineText(buffer, lineIndex: 2, trimRight: false) == "cd")
    }

    @Test func testReflowWideCharactersLarger() {
        let buffer = makeBuffer(cols: 12, rows: 10, scrollback: 10)
        buffer.y = 2

        let pattern = [hanScalar, yuScalar, hanScalar, yuScalar, hanScalar, yuScalar]
        fillWideLine(buffer.lines[0], scalars: pattern)
        fillWideLine(buffer.lines[1], scalars: pattern)
        buffer.lines[1].isWrapped = true

        #expect(lineText(buffer, lineIndex: 0, trimRight: true) == hanString + yuString + hanString + yuString + hanString + yuString)
        #expect(lineText(buffer, lineIndex: 1, trimRight: true) == hanString + yuString + hanString + yuString + hanString + yuString)

        buffer.resize(newCols: 13, newRows: 10)

        #expect(buffer.yBase == 0)
        #expect(buffer.lines.count == 10)
        #expect(lineText(buffer, lineIndex: 0, trimRight: true) == hanString + yuString + hanString + yuString + hanString + yuString)
        #expect(lineText(buffer, lineIndex: 0, trimRight: false) == hanString + yuString + hanString + yuString + hanString + yuString + " ")
        #expect(lineText(buffer, lineIndex: 1, trimRight: true) == hanString + yuString + hanString + yuString + hanString + yuString)
        #expect(lineText(buffer, lineIndex: 1, trimRight: false) == hanString + yuString + hanString + yuString + hanString + yuString + " ")

        buffer.resize(newCols: 14, newRows: 10)

        #expect(lineText(buffer, lineIndex: 0, trimRight: true) == hanString + yuString + hanString + yuString + hanString + yuString + hanString)
        #expect(lineText(buffer, lineIndex: 1, trimRight: true) == yuString + hanString + yuString + hanString + yuString)
    }

    @Test func testReflowWideCharactersSmaller() {
        let buffer = makeBuffer(cols: 12, rows: 10, scrollback: 10)
        buffer.y = 2

        let pattern = [hanScalar, yuScalar, hanScalar, yuScalar, hanScalar, yuScalar]
        fillWideLine(buffer.lines[0], scalars: pattern)
        fillWideLine(buffer.lines[1], scalars: pattern)
        buffer.lines[1].isWrapped = true

        buffer.resize(newCols: 11, newRows: 10)
        #expect(buffer.yBase == 0)
        #expect(buffer.lines.count == 10)
        #expect(lineText(buffer, lineIndex: 0, trimRight: true) == hanString + yuString + hanString + yuString + hanString)
        #expect(lineText(buffer, lineIndex: 1, trimRight: true) == yuString + hanString + yuString + hanString + yuString)
        #expect(lineText(buffer, lineIndex: 2, trimRight: true) == hanString + yuString)

        buffer.resize(newCols: 10, newRows: 10)
        #expect(lineText(buffer, lineIndex: 0, trimRight: true) == hanString + yuString + hanString + yuString + hanString)
        #expect(lineText(buffer, lineIndex: 1, trimRight: true) == yuString + hanString + yuString + hanString + yuString)
        #expect(lineText(buffer, lineIndex: 2, trimRight: true) == hanString + yuString)

        buffer.resize(newCols: 9, newRows: 10)
        #expect(lineText(buffer, lineIndex: 0, trimRight: true) == hanString + yuString + hanString + yuString)
        #expect(lineText(buffer, lineIndex: 1, trimRight: true) == hanString + yuString + hanString + yuString)
        #expect(lineText(buffer, lineIndex: 2, trimRight: true) == hanString + yuString + hanString + yuString)

        buffer.resize(newCols: 8, newRows: 10)
        #expect(lineText(buffer, lineIndex: 0, trimRight: true) == hanString + yuString + hanString + yuString)
        #expect(lineText(buffer, lineIndex: 1, trimRight: true) == hanString + yuString + hanString + yuString)
        #expect(lineText(buffer, lineIndex: 2, trimRight: true) == hanString + yuString + hanString + yuString)

        buffer.resize(newCols: 7, newRows: 10)
        #expect(lineText(buffer, lineIndex: 0, trimRight: true) == hanString + yuString + hanString)
        #expect(lineText(buffer, lineIndex: 1, trimRight: true) == yuString + hanString + yuString)
        #expect(lineText(buffer, lineIndex: 2, trimRight: true) == hanString + yuString + hanString)
        #expect(lineText(buffer, lineIndex: 3, trimRight: true) == yuString + hanString + yuString)

        buffer.resize(newCols: 6, newRows: 10)
        #expect(lineText(buffer, lineIndex: 0, trimRight: true) == hanString + yuString + hanString)
        #expect(lineText(buffer, lineIndex: 1, trimRight: true) == yuString + hanString + yuString)
        #expect(lineText(buffer, lineIndex: 2, trimRight: true) == hanString + yuString + hanString)
        #expect(lineText(buffer, lineIndex: 3, trimRight: true) == yuString + hanString + yuString)
    }
}

final class ReflowLineLengthTests {
    @Test func testGetNewLineLengthsSmallWideCharacters() {
        let buffer = makeBuffer(cols: 4, rows: 1, scrollback: 10)
        let line = BufferLine(cols: 4)
        setWide(line, index: 0, scalar: hanScalar)
        setWide(line, index: 2, scalar: yuScalar)
        #expect(lineString(line, trimRight: true) == hanString + yuString)
        #expect(buffer.getNewLineLengths(wrappedLines: [line], oldCols: 4, newCols: 3) == [2, 2])
        #expect(buffer.getNewLineLengths(wrappedLines: [line], oldCols: 4, newCols: 2) == [2, 2])
    }

    @Test func testGetNewLineLengthsLargeWideCharacters() {
        let buffer = makeBuffer(cols: 12, rows: 1, scrollback: 10)
        let line = BufferLine(cols: 12)
        let pattern = [hanScalar, yuScalar, hanScalar, yuScalar, hanScalar, yuScalar]
        fillWideLine(line, scalars: pattern)
        #expect(lineString(line, trimRight: true) == hanString + yuString + hanString + yuString + hanString + yuString)
        #expect(buffer.getNewLineLengths(wrappedLines: [line], oldCols: 12, newCols: 11) == [10, 2])
        #expect(buffer.getNewLineLengths(wrappedLines: [line], oldCols: 12, newCols: 10) == [10, 2])
        #expect(buffer.getNewLineLengths(wrappedLines: [line], oldCols: 12, newCols: 9) == [8, 4])
        #expect(buffer.getNewLineLengths(wrappedLines: [line], oldCols: 12, newCols: 8) == [8, 4])
        #expect(buffer.getNewLineLengths(wrappedLines: [line], oldCols: 12, newCols: 7) == [6, 6])
        #expect(buffer.getNewLineLengths(wrappedLines: [line], oldCols: 12, newCols: 6) == [6, 6])
        #expect(buffer.getNewLineLengths(wrappedLines: [line], oldCols: 12, newCols: 5) == [4, 4, 4])
        #expect(buffer.getNewLineLengths(wrappedLines: [line], oldCols: 12, newCols: 4) == [4, 4, 4])
        #expect(buffer.getNewLineLengths(wrappedLines: [line], oldCols: 12, newCols: 3) == [2, 2, 2, 2, 2, 2])
        #expect(buffer.getNewLineLengths(wrappedLines: [line], oldCols: 12, newCols: 2) == [2, 2, 2, 2, 2, 2])
    }

    @Test func testGetNewLineLengthsWideAndSingleCharacters() {
        let buffer = makeBuffer(cols: 6, rows: 1, scrollback: 10)
        let line = BufferLine(cols: 6)
        setChar(line, index: 0, scalar: asciiScalar(asciiA))
        setWide(line, index: 1, scalar: hanScalar)
        setWide(line, index: 3, scalar: yuScalar)
        setChar(line, index: 5, scalar: asciiScalar(asciiA + 1))
        #expect(lineString(line, trimRight: true) == "a" + hanString + yuString + "b")
        #expect(buffer.getNewLineLengths(wrappedLines: [line], oldCols: 6, newCols: 5) == [5, 1])
        #expect(buffer.getNewLineLengths(wrappedLines: [line], oldCols: 6, newCols: 4) == [3, 3])
        #expect(buffer.getNewLineLengths(wrappedLines: [line], oldCols: 6, newCols: 3) == [3, 3])
        #expect(buffer.getNewLineLengths(wrappedLines: [line], oldCols: 6, newCols: 2) == [1, 2, 2, 1])
    }

    @Test func testGetNewLineLengthsWrappedWideAndSingleCharacters() {
        let buffer = makeBuffer(cols: 6, rows: 1, scrollback: 10)
        let line1 = BufferLine(cols: 6)
        setChar(line1, index: 0, scalar: asciiScalar(asciiA))
        setWide(line1, index: 1, scalar: hanScalar)
        setWide(line1, index: 3, scalar: yuScalar)
        setChar(line1, index: 5, scalar: asciiScalar(asciiA + 1))
        let line2 = BufferLine(cols: 6, isWrapped: true)
        setChar(line2, index: 0, scalar: asciiScalar(asciiA))
        setWide(line2, index: 1, scalar: hanScalar)
        setWide(line2, index: 3, scalar: yuScalar)
        setChar(line2, index: 5, scalar: asciiScalar(asciiA + 1))
        #expect(lineString(line1, trimRight: true) == "a" + hanString + yuString + "b")
        #expect(lineString(line2, trimRight: true) == "a" + hanString + yuString + "b")
        #expect(buffer.getNewLineLengths(wrappedLines: [line1, line2], oldCols: 6, newCols: 5) == [5, 4, 3])
        #expect(buffer.getNewLineLengths(wrappedLines: [line1, line2], oldCols: 6, newCols: 4) == [3, 4, 4, 1])
        #expect(buffer.getNewLineLengths(wrappedLines: [line1, line2], oldCols: 6, newCols: 3) == [3, 3, 3, 3])
        #expect(buffer.getNewLineLengths(wrappedLines: [line1, line2], oldCols: 6, newCols: 2) == [1, 2, 2, 2, 2, 2, 1])
    }

    @Test func testGetNewLineLengthsLineEndingInNullSpace() {
        let buffer = makeBuffer(cols: 4, rows: 1, scrollback: 10)
        let line = BufferLine(cols: 5)
        setWide(line, index: 0, scalar: hanScalar)
        setWide(line, index: 2, scalar: yuScalar)
        line[4] = CharData.Null
        #expect(lineString(line, trimRight: true) == hanString + yuString)
        #expect(lineString(line, trimRight: false) == hanString + yuString + " ")
        #expect(buffer.getNewLineLengths(wrappedLines: [line], oldCols: 4, newCols: 3) == [2, 2])
        #expect(buffer.getNewLineLengths(wrappedLines: [line], oldCols: 4, newCols: 2) == [2, 2])
    }
}
