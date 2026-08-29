import Testing

@testable import SwiftTerm

@Suite("Ghostty fuzz regressions", .serialized)
struct GhosttyFuzzRegressionTests {
    private let esc = "\u{1b}"

    @Test func overflowingTabClearParameterDoesNotTrap() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        let parser = EscapeSequenceParser()
        parser.parse(data: Array("\(esc)[388888888888888888888888888888888888g\(esc)[0m".utf8)[...], terminal)
        #expect(parser.currentState == .ground)
    }

    @Test func trailingColonUnderlineColorDoesNotTrap() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        let parser = EscapeSequenceParser()
        parser.parse(data: Array("\(esc)[58:4:m".utf8)[...], terminal)
        #expect(parser.currentState == .ground)
    }

    @Test func csiWWithPrivateMarkerAndNoParametersDoesNotTrap() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        let parser = EscapeSequenceParser()
        parser.parse(data: Array("\(esc)[?W".utf8)[...], terminal)
        #expect(parser.currentState == .ground)
    }

    @Test func oscPaletteResetRejectsNegativeIndices() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        terminal.feed(byteArray: [
            0x00, 0x00, 0x00, 0x10, 0x00, 0x5d, 0xbb, 0xb6, 0x0a,
            0x1b, 0x5d, 0x31, 0x30, 0x34, 0x3b, 0x35, 0x37, 0x3b,
            0x37, 0x3b, 0x2d, 0x37, 0x3b, 0x37, 0x3b, 0x2d, 0x38,
            0x3b, 0x39, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x4d,
            0x1b, 0x6c,
        ])

        #expect(terminal.ansiColors.count == 256)
    }

    @Test func dcsParameterOverflowIsDropped() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        let parser = EscapeSequenceParser()
        let handler = CountingDcsHandler()
        parser.dcsHandlerFactory = { _, _, _ in handler }
        let parameters = Array(repeating: "6", count: EscapeSequenceParser.maximumParameterCount + 1)
            .joined(separator: ";")

        parser.parse(data: Array("\(esc)P\(parameters)p".utf8)[...], terminal)

        #expect(handler.hookCount == 0)
    }

    @Test func oversizedOscIsDroppedAndItsStorageIsReleased() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        let parser = EscapeSequenceParser()
        var handlerCallCount = 0
        parser.oscHandlers[999] = { _ in handlerCallCount += 1 }

        parser.parse(data: [0x1b, 0x5d, 0x39, 0x39, 0x39, 0x3b][...], terminal)
        let payload = [UInt8](
            repeating: UInt8(ascii: "a"),
            count: EscapeSequenceParser.maximumOscBytes)
        parser.parse(data: payload[...], terminal)
        parser.parse(data: [UInt8(ascii: "b")][...], terminal)

        #expect(parser._osc.count == EscapeSequenceParser.maximumOscBytes)
        #expect(parser._oscLimitExceeded)

        parser.parse(data: [0x07][...], terminal)

        #expect(handlerCallCount == 0)
        #expect(parser._osc.isEmpty)
        #expect(parser._osc.capacity <= EscapeSequenceParser.maximumRetainedOscBytes)
    }

    @Test func overwritingWideCharacterDoesNotCorruptPreviousRow() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 3)
        terminal.feed(text: String(repeating: "中", count: 10))
        terminal.feed(text: "\(esc)[2;1HA")

        let row = terminal.buffer.lines[terminal.buffer.yBase]
        #expect(row.packedView(at: 8).packed.widthState == .wide)
        #expect(row.packedView(at: 9).packed.widthState == .spacerTail)
        try assertWideCellIntegrity(terminal)
    }

    @Test func wideCharacterAtRightEdgeWithHyperlinkKeepsValidCells() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 5)
        terminal.feed(text: "\(esc)]8;;https://example.com\u{7}\(esc)[1;10H中")

        let first = terminal.buffer.lines[terminal.buffer.yBase]
        let second = terminal.buffer.lines[terminal.buffer.yBase + 1]
        #expect((0..<terminal.cols).contains { first.packedView(at: $0).hasPayload } ||
                (0..<terminal.cols).contains { second.packedView(at: $0).hasPayload })
        #expect(TerminalTestHarness.visibleLinesText(buffer: terminal.buffer, terminal: terminal)
            .joined().contains("中"))
        try assertWideCellIntegrity(terminal)
    }

    @Test func repeatEraseAndHyperlinkSequenceKeepsPayloadsValid() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 200, rows: 50, scrollback: 100)
        terminal.feed(text: "A\(esc)[48111b\(esc)]8;;x\u{7}\(esc)[11A\(esc)[22JB\(esc)]8;;\u{7}")

        for lineIndex in 0..<terminal.buffer.lines.count {
            let line = terminal.buffer.lines[lineIndex]
            for column in 0..<terminal.cols where line.packedView(at: column).hasPayload {
                let cell = line[column]
                #expect(cell.getPayload() != nil)
            }
        }
        try assertWideCellIntegrity(terminal)
    }

    @Test func insertCharactersAtWideRightMarginKeepsValidCells() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 5)
        terminal.feed(text: "ABCD橋\(esc)[?69h\(esc)[1;5s\(esc)[1;3H\(esc)[@")

        TerminalTestHarness.assertLineText(terminal.buffer, terminal: terminal, row: 0, equals: "AB CD")
        try assertWideCellIntegrity(terminal)
    }

    @Test func fullWidthInsertionDoesNotLeaveOrphanedWideTail() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 5)
        terminal.feed(text: "中中中中中\(esc)[?69h\(esc)[1;9s\(esc)[1;1Ha\(esc)[8@")

        TerminalTestHarness.assertLineText(terminal.buffer, terminal: terminal, row: 0, equals: "a")
        try assertWideCellIntegrity(terminal)
    }

    @Test func resizeWithMarginsAndLargeRepeatKeepsCursorInBounds() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 70, rows: 23)
        terminal.feed(text: "\(esc)[?69h0\(esc)[2;70s")
        terminal.resize(cols: 70, rows: 23)
        terminal.feed(text: "\(esc)[1850b")
        terminal.resize(cols: 70, rows: 23)

        #expect(terminal.buffer.x >= 0 && terminal.buffer.x < terminal.cols)
        #expect(terminal.buffer.y >= 0 && terminal.buffer.y < terminal.rows)
        try assertWideCellIntegrity(terminal)
    }

    @Test func fullScrollWithWideCharacterAtMarginKeepsValidCells() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[10;39H中\(esc)[?69h\(esc)[5;39s\(esc)[24S")
        try assertWideCellIntegrity(terminal)
    }

    @Test func wideningAlternateScreenClearsStaleSpacerHeads() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 3)
        terminal.feed(text: "\(esc)[?1049h")
        terminal.resize(cols: 5, rows: 3)
        terminal.feed(text: "ABCD中")

        terminal.resize(cols: 10, rows: 3)

        try assertWideCellIntegrity(terminal)
    }

    @Test func chunkedAndSingleBatchOperationsStayEquivalent() throws {
        var generator = DeterministicGenerator(state: 0xC0FFEE)
        for (cols, rows, iterations) in [(80, 24, 500), (10, 4, 500), (5, 2, 500), (2, 2, 200)] {
            try runDifferentialOperations(
                cols: cols,
                rows: rows,
                iterations: iterations,
                generator: &generator)
        }
    }

    private static let printAlphabet: [Character] = [
        "a", "b", "Z", "0", " ", "é", "ÿ", "\u{301}", "中", "丁", "😀", "\u{200d}",
        "\u{fe0f}", "x", "y", "🧑", "\u{308}", "あ", "가", "q", "r", "s", "t", "u",
        "v", "w", "1", "2", "🇦", "🇧", "ᄀ", "ᅡ", "ᆨ", "\u{200c}", "а", "α",
    ]

    private func runDifferentialOperations(
        cols: Int,
        rows: Int,
        iterations: Int,
        generator: inout DeterministicGenerator
    ) throws {
        let (whole, _) = TerminalTestHarness.makeTerminal(cols: cols, rows: rows)
        let (chunked, _) = TerminalTestHarness.makeTerminal(cols: cols, rows: rows)
        whole.silentLog = true
        chunked.silentLog = true

        for _ in 0..<iterations {
            switch generator.next() % 20 {
            case 0...9:
                let count = 1 + Int(generator.next() % 64)
                var text = ""
                for _ in 0..<count {
                    text.append(Self.printAlphabet[
                        Int(generator.next() % UInt64(Self.printAlphabet.count))])
                }
                let bytes = Array(text.utf8)
                whole.feed(byteArray: bytes)

                var offset = 0
                while offset < bytes.count {
                    let remaining = bytes.count - offset
                    let chunkSize = 1 + Int(generator.next() % UInt64(remaining))
                    chunked.feed(buffer: bytes[offset..<(offset + chunkSize)])
                    offset += chunkSize
                }
            case 10:
                feedControl("\r\n", to: whole, and: chunked)
            case 11:
                let row = 1 + Int(generator.next() % UInt64(rows))
                let column = 1 + Int(generator.next() % UInt64(cols))
                feedControl("\(esc)[\(row);\(column)H", to: whole, and: chunked)
            case 12:
                let sequence: String
                switch generator.next() % 4 {
                case 0:
                    sequence = "\(esc)[0m"
                case 1:
                    sequence = "\(esc)[1m"
                case 2:
                    let red = generator.next() % 256
                    let green = generator.next() % 256
                    let blue = generator.next() % 256
                    sequence = "\(esc)[38;2;\(red);\(green);\(blue)m"
                default:
                    sequence = "\(esc)[31m"
                }
                feedControl(sequence, to: whole, and: chunked)
            case 13:
                let setting = generator.next() & 1 == 0 ? "h" : "l"
                feedControl("\(esc)[4\(setting)", to: whole, and: chunked)
            case 14:
                let setting = generator.next() & 1 == 0 ? "h" : "l"
                feedControl("\(esc)[?7\(setting)", to: whole, and: chunked)
            case 15:
                feedControl("\(esc)[?69h", to: whole, and: chunked)
                let left = 1 + Int(generator.next() % UInt64(max(1, cols / 2)))
                let rightRange = max(1, cols - left)
                let right = min(cols, left + 1 + Int(generator.next() % UInt64(rightRange)))
                feedControl("\(esc)[\(left);\(right)s", to: whole, and: chunked)
            case 16:
                feedControl("\(esc)[1;\(cols)s", to: whole, and: chunked)
            case 17:
                feedControl("\(esc)]8;;https://example.com\u{7}", to: whole, and: chunked)
            case 18:
                feedControl("\(esc)]8;;\u{7}", to: whole, and: chunked)
            default:
                let charset = generator.next() & 1 == 0 ? "0" : "B"
                feedControl("\(esc)(\(charset)", to: whole, and: chunked)
            }

            try assertTerminalsEqual(whole, chunked)
        }

        try assertWideCellIntegrity(whole)
        try assertWideCellIntegrity(chunked)
    }

    private func feedControl(_ text: String, to first: Terminal, and second: Terminal) {
        let bytes = Array(text.utf8)
        first.feed(byteArray: bytes)
        second.feed(byteArray: bytes)
    }

    private func assertTerminalsEqual(_ first: Terminal, _ second: Terminal) throws {
        #expect(first.cols == second.cols)
        #expect(first.rows == second.rows)
        #expect(first.buffer.x == second.buffer.x)
        #expect(first.buffer.y == second.buffer.y)
        #expect(first.buffer.yBase == second.buffer.yBase)
        #expect(first.buffer.yDisp == second.buffer.yDisp)
        #expect(first.buffer.lines.count == second.buffer.lines.count)
        guard first.buffer.lines.count == second.buffer.lines.count else { return }

        for lineIndex in 0..<first.buffer.lines.count {
            let lhs = first.buffer.lines[lineIndex]
            let rhs = second.buffer.lines[lineIndex]
            #expect(lhs.isWrapped == rhs.isWrapped)
            for column in 0..<first.cols {
                let lhsView = lhs.packedView(at: column)
                let rhsView = rhs.packedView(at: column)
                // Payload codes are process-wide identities. Two terminals
                // can use different codes for the same payload value.
                let valueMask = ~PackedCell.payloadMask
                #expect(lhsView.packed.rawValue & valueMask ==
                        rhsView.packed.rawValue & valueMask)
                #expect(lhsView.hasPayload == rhsView.hasPayload)
                if lhsView.hasPayload, rhsView.hasPayload {
                    #expect(String(describing: lhsView.getPayload()) ==
                            String(describing: rhsView.getPayload()))
                }
            }
        }
    }

    private func assertWideCellIntegrity(_ terminal: Terminal) throws {
        for lineIndex in 0..<terminal.buffer.lines.count {
            let line = terminal.buffer.lines[lineIndex]
            for column in 0..<terminal.cols {
                switch line.packedView(at: column).packed.widthState {
                case .narrow:
                    break
                case .wide:
                    #expect(column + 1 < terminal.cols)
                    if column + 1 < terminal.cols {
                        #expect(line.packedView(at: column + 1).packed.widthState == .spacerTail)
                    }
                case .spacerTail:
                    #expect(column > 0)
                    if column > 0 {
                        #expect(line.packedView(at: column - 1).packed.widthState == .wide)
                    }
                case .spacerHead:
                    Issue.record("Unexpected spacer head at row \(lineIndex), column \(column)")
                }
            }
        }
    }
}

private final class CountingDcsHandler: DcsHandler {
    var hookCount = 0

    func hook(collect: cstring, parameters: [Int], flag: UInt8) {
        hookCount += 1
    }

    func put(data: ArraySlice<UInt8>) {}
    func unhook() {}
}

private struct DeterministicGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
