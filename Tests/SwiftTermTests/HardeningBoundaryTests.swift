import Testing
@testable import SwiftTerm

@Suite("Wide-cell and OSC hardening boundaries")
struct HardeningBoundaryTests {
    private let esc = "\u{1b}"

    @Test func asciiOverwriteRepairsWideCellsAtBothSeams() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
        terminal.feed(text: "ab中cd中ef")

        // Replace the lead of the left wide cell and the tail of the right one.
        terminal.feed(text: "\(esc)[1;3HL\(esc)[1;8HR")

        TerminalTestHarness.assertLineText(terminal.buffer, terminal: terminal, row: 0,
                                           equals: "abL cd Ref")
        assertWideCellIntegrity(terminal)
    }

    @Test(arguments: ["@", "P", "X"])
    func characterEditingAtMarginSeamsKeepsCellsAndExteriorValid(command: String) {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
        terminal.feed(text: "ab中cd中ef")
        terminal.feed(text: "\(esc)[?69h\(esc)[3;8s\(esc)[1;3H\(esc)[6\(command)")

        // The operation is restricted to columns 3 through 8.
        assertCharacterEditingExteriorIsUnchanged(terminal)
        assertWideCellIntegrity(terminal)
    }

    @Test(arguments: ["L", "M", "S", "T"])
    func verticalMarginOperationsKeepExteriorAndWideMarginsValid(command: String) {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 5)
        for row in 0..<5 {
            terminal.feed(text: "\(esc)[\(row + 1);1H\(row)A中bc中XY")
        }
        terminal.feed(text: "\(esc)[2;4r\(esc)[?69h\(esc)[3;8s")

        // IL and DL need a cursor inside both margin regions. SU and SD use
        // the configured regions directly.
        if command == "L" || command == "M" {
            terminal.feed(text: "\(esc)[2;3H")
        }
        terminal.feed(text: "\(esc)[1\(command)")

        assertVerticalOperationExteriorIsUnchanged(terminal)
        assertWideCellIntegrity(terminal)
    }

    @Test func chunkedOscAtExactLimitDispatchesAndRecovers() {
        let (parser, terminal) = makeParser(maximumOscBytes: 12)
        var received: [String] = []
        parser.oscHandlers[77] = { received.append(String(decoding: $0, as: UTF8.self)) }

        feed(parser, terminal, "\(esc)]77;abc")
        feed(parser, terminal, "defghi\u{7}") // "77;" plus nine bytes is exactly 12 bytes.
        feed(parser, terminal, "\(esc)]77;ok\u{7}")

        #expect(received == ["abcdefghi", "ok"])
        #expect(parser._osc.isEmpty)
        #expect(!parser._oscLimitExceeded)
    }

    @Test func chunkedOscOverLimitIsDroppedAndNextOscRecovers() {
        let (parser, terminal) = makeParser(maximumOscBytes: 12)
        var received: [String] = []
        parser.oscHandlers[77] = { received.append(String(decoding: $0, as: UTF8.self)) }

        feed(parser, terminal, "\(esc)]77;abcdefgh")
        feed(parser, terminal, "ij\u{7}")
        feed(parser, terminal, "\(esc)]77;ok\u{7}")

        #expect(received == ["ok"])
        #expect(parser._osc.isEmpty)
        #expect(!parser._oscLimitExceeded)
    }

    @Test func largeOscStorageIsReleasedAfterTermination() {
        let limit = EscapeSequenceParser.maximumRetainedOscBytes + 1
        let (parser, terminal) = makeParser(maximumOscBytes: limit)
        let prefix = "\(esc)]77;"
        let payload = String(repeating: "a", count: limit - "77;".utf8.count)

        feed(parser, terminal, prefix)
        feed(parser, terminal, payload)
        feed(parser, terminal, "\u{7}")

        #expect(parser._osc.isEmpty)
        #expect(parser._osc.capacity <= EscapeSequenceParser.maximumRetainedOscBytes)
    }

    private func makeParser(maximumOscBytes: Int) -> (EscapeSequenceParser, Terminal) {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 5)
        terminal.silentLog = true
        return (EscapeSequenceParser(maximumOscBytes: maximumOscBytes), terminal)
    }

    private func feed(_ parser: EscapeSequenceParser, _ terminal: Terminal, _ text: String) {
        let bytes = Array(text.utf8)
        parser.parse(data: bytes[...], terminal)
    }

    private func assertCharacterEditingExteriorIsUnchanged(_ terminal: Terminal) {
        #expect(character(in: terminal, row: 0, col: 0) == "a")
        #expect(character(in: terminal, row: 0, col: 1) == "b")
        #expect(character(in: terminal, row: 0, col: 8) == "e")
        #expect(character(in: terminal, row: 0, col: 9) == "f")
    }

    private func assertVerticalOperationExteriorIsUnchanged(_ terminal: Terminal) {
        for row in 0..<5 {
            #expect(character(in: terminal, row: row, col: 0) == String(row).first)
            #expect(character(in: terminal, row: row, col: 1) == "A")
            #expect(character(in: terminal, row: row, col: 8) == "X")
            #expect(character(in: terminal, row: row, col: 9) == "Y")
        }
    }

    private func character(in terminal: Terminal, row: Int, col: Int) -> Character? {
        guard let charData = TerminalTestHarness.charData(buffer: terminal.buffer, row: row, col: col) else {
            return nil
        }
        return terminal.getCharacter(for: charData)
    }

    /// Soak test for the destination-keyed seam repair in
    /// `BufferLine.repairSeamsForWrite`. That repair reasons from the cells a
    /// write is about to overwrite instead of from their neighbours, which is
    /// only sound while the wide-cell invariant holds everywhere. Hammer the
    /// buffer with randomised wide and narrow writes, cursor jumps, editing
    /// commands, and scrolls, and check the invariant after each step.
    ///
    /// Horizontal margins (DECLRMM plus DECSLRM) are deliberately absent. They
    /// break the same invariant on this branch with the previous neighbour-based
    /// repair as well, so they are a separate defect rather than a property of
    /// this repair.
    @Test func randomisedWideAndNarrowWritesKeepCellsValid() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 12, rows: 6)
        var seed: UInt64 = 0x9E3779B97F4A7C15

        func next(_ bound: Int) -> Int {
            // xorshift64*: a deterministic sequence, so a failure reproduces.
            seed ^= seed >> 12
            seed ^= seed << 25
            seed ^= seed >> 27
            return Int((seed &* 0x2545F4914F6CDD1D) >> 33) % bound
        }

        let glyphs = ["中", "a", "😀", "b", "界", " ", "組", "z"]
        for _ in 0..<4000 {
            switch next(7) {
            case 0:
                terminal.feed(text: "\(esc)[\(next(6) + 1);\(next(12) + 1)H")
            case 1:
                terminal.feed(text: glyphs[next(glyphs.count)])
            case 2:
                terminal.feed(text: glyphs[next(glyphs.count)] + glyphs[next(glyphs.count)])
            case 3:
                terminal.feed(text: "\(esc)[\(next(5) + 1)\(["@", "P", "X"][next(3)])")
            case 4:
                terminal.feed(text: "\(esc)[\(next(4) + 1)\(["L", "M", "S", "T"][next(4)])")
            case 5:
                terminal.feed(text: "\(esc)[\(next(3))K")
            default:
                terminal.feed(text: "\(esc)[\(next(4) + 1);\(next(2) + 5)r")
            }
            assertWideCellIntegrity(terminal)
        }
    }

    private func assertWideCellIntegrity(_ terminal: Terminal) {
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
