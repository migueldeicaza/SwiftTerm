import Testing
@testable import SwiftTerm

final class TerminalCoreTests {
    private let esc = "\u{1b}"

    @Test func testWraparoundEnabled() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 2)
        terminal.feed(text: "helloX")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "hello")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "X")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 1, row: 1)
    }

    @Test func testWraparoundDisabled() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 2)
        terminal.feed(text: "\(esc)[?7l")
        terminal.feed(text: "helloX")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "hellX")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "")
    }

    @Test func testUnicodeRunWithWraparoundDisabledOverwritesLastCell() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 2)
        terminal.feed(text: "\(esc)[?7l")
        terminal.feed(text: "αβγδεζ")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "αβγδζ")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "")
    }

    @Test func testWideBatchFallsBackBeforeNarrowMarginWrap() {
        // The narrowest region that DECSLRM accepts has two columns. With the
        // cursor on the right margin, the first wide glyph does not fit and
        // the batch is rejected.
        func run(_ chunks: [String]) -> Terminal {
            let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 4)
            terminal.feed(text: "\(esc)[?69h\(esc)[3;4s\(esc)[1;4H")
            for chunk in chunks {
                terminal.feed(text: chunk)
            }
            return terminal
        }
        let batched = run(["中界"])
        let scalar = run(["中", "界"])

        // The scalar behavior wraps each glyph one time. The batch
        // rejection must not add an extra wrap before the scalar fallback.
        TerminalTestHarness.assertCursor(batched.buffer, col: 3, row: 2)
        TerminalTestHarness.assertCursor(scalar.buffer, col: 3, row: 2)
        for row in 0..<4 {
            #expect(TerminalTestHarness.lineText(buffer: batched.buffer, row: row) ==
                    TerminalTestHarness.lineText(buffer: scalar.buffer, row: row))
        }
        TerminalTestHarness.assertLineText(batched.buffer, row: 1, equals: "  中")
        TerminalTestHarness.assertLineText(batched.buffer, row: 2, equals: "  界")
    }

    @Test func testBatchableScalarAtChunkEndDoesNotReadPastInput() {
        // The batcher looks one scalar ahead before it sets up its scratch
        // buffers. A batchable scalar that ends the chunk leaves nothing to
        // look at, so the lookahead must stop at the input end.
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 2)
        for chunk in ["\u{3b1}", "\u{3b2}", "\u{3b3}"] {
            terminal.feed(text: chunk)
        }

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "\u{3b1}\u{3b2}\u{3b3}")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 3, row: 0)
    }

    @Test func testReverseWraparoundBackspace() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 2)
        terminal.feed(text: "\(esc)[?45h")
        terminal.feed(text: "helloX")
        terminal.feed(text: "\u{8}\u{8}")

        TerminalTestHarness.assertCursor(terminal.buffer, col: 4, row: 0)
    }

    @Test func testOriginModeWithScrollRegion() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 4)
        terminal.feed(text: "\(esc)[2;3r")
        terminal.feed(text: "\(esc)[?6h")
        terminal.feed(text: "\(esc)[1;1H")
        terminal.feed(text: "X")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 1, col: 0)
        #expect(cell?.getCharacter() == "X")
    }

    @Test func testLeftRightMarginsWithOriginMode() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 2)
        terminal.feed(text: "\(esc)[?6h")
        terminal.feed(text: "\(esc)[?69h")
        terminal.feed(text: "\(esc)[2;4s")
        terminal.feed(text: "\(esc)[1;1H")
        terminal.feed(text: "ABC")

        let aCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 1)
        let bCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 2)
        let cCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 3)
        #expect(aCell?.getCharacter() == "A")
        #expect(bCell?.getCharacter() == "B")
        #expect(cCell?.getCharacter() == "C")
    }

    @Test func testInsertLinesInScrollRegion() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 4)
        terminal.feed(text: "AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD")
        terminal.feed(text: "\(esc)[2;3r")
        terminal.feed(text: "\(esc)[2;1H")
        terminal.feed(text: "\(esc)[L")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "AAAAA")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "BBBBB")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 3, equals: "DDDDD")
    }

    @Test func testDeleteLinesInScrollRegion() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 4)
        terminal.feed(text: "AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD")
        terminal.feed(text: "\(esc)[2;3r")
        terminal.feed(text: "\(esc)[2;1H")
        terminal.feed(text: "\(esc)[M")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "AAAAA")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 1, equals: "CCCCC")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 2, equals: "")
        TerminalTestHarness.assertLineText(terminal.buffer, row: 3, equals: "DDDDD")
    }

    @Test func testCursorSaveRestore() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 3)
        terminal.feed(text: "\(esc)[2;4H")
        terminal.feed(text: "\(esc)7")
        terminal.feed(text: "\(esc)[1;1H")
        terminal.feed(text: "\(esc)8")

        TerminalTestHarness.assertCursor(terminal.buffer, col: 3, row: 1)
    }
}
