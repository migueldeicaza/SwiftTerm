import Testing
@testable import SwiftTerm

struct StyleArenaReclamationTests {
    private let esc = "\u{1b}"

    private func animation(_ count: Int) -> String {
        var text = ""
        text.reserveCapacity(count * 55)
        for color in 0..<count {
            let r = (color >> 16) & 255
            let g = (color >> 8) & 255
            let b = color & 255
            text += "\(esc)[38;2;\(r);\(g);\(b)m\(esc)[48;2;\(255 - r);\(255 - g);\(255 - b)m\(esc)[2;1HX"
        }
        return text
    }

    @Test func animatedRGBSurvivesMoreThanOneStyleTable() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 3)
        terminal.feed(text: "\(esc)[?1049h")
        terminal.feed(text: animation(150_000))
        let cell = try #require(terminal.getCharData(col: 0, row: 1))
        let last = 149_999
        #expect(cell.attribute.fg == .trueColor(red: UInt8(last >> 16),
                                              green: UInt8((last >> 8) & 255),
                                              blue: UInt8(last & 255)))
        #expect(cell.attribute.bg == .trueColor(red: UInt8(255 - (last >> 16)),
                                              green: UInt8(255 - ((last >> 8) & 255)),
                                              blue: UInt8(255 - (last & 255))))
        #expect(terminal.currentAttribute == cell.attribute)

        // Erase cells cache packed style IDs separately from printed cells.
        terminal.feed(text: "\(esc)[3;1H\(esc)[K")
        #expect(terminal.getCharData(col: 0, row: 2)?.attribute.bg == cell.attribute.bg)
    }

    @Test func reclamationPreservesBothBuffersAndFrozenRows() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 3)
        terminal.feed(text: "\(esc)[1;3;4;38;2;12;34;56;48;2;78;90;123m\(esc)[1\"q\(esc)]8;;https://example.test\(esc)\\界e\u{301}\(esc)]8;;\(esc)\\")
        let normal = terminal.normalBuffer.lines[0].getData()
        terminal.feed(text: "\(esc)[?1049h\(esc)[38;2;201;117;43mA")
        let live = terminal.altBuffer.lines[0]
        let oldGeneration = live.generation
        let oldContentGeneration = live.contentGeneration
        let oldArena = live.cellArena.snapshotCopy()
        let frozen = BufferLine(cols: 8, fillData: nil, arena: oldArena)
        frozen.copyForSnapshot(from: live, arena: oldArena)
        let original = frozen.getData()

        terminal.feed(text: animation(70_000))

        #expect(live.getData().map(\.attribute) == original.map(\.attribute))
        #expect(live.getData().map { $0.getText() } == original.map { $0.getText() })
        #expect(terminal.normalBuffer.lines[0].getData().map(\.attribute) == normal.map(\.attribute))
        #expect(terminal.normalBuffer.lines[0].getData().map(\.width) == normal.map(\.width))
        #expect(terminal.normalBuffer.lines[0].getData().map { $0.payload.code } == normal.map { $0.payload.code })
        #expect(terminal.normalBuffer.lines[0].getData().map(\.isProtected) == normal.map(\.isProtected))
        #expect(frozen.getData().map(\.attribute) == original.map(\.attribute))
        #expect(frozen.getData().map { $0.getText() } == original.map { $0.getText() })
        #expect(live.generation != oldGeneration)
        #expect(live.contentGeneration == oldContentGeneration)
        #expect(!oldArena.preservesEncoding(from: live.cellArena))
        #expect(terminal.normalBuffer.cellArena === terminal.altBuffer.cellArena)
        terminal.feed(text: "\(esc)[?1049l")
        #expect(terminal.getCharacter(col: 0, row: 0) == "界")
        #expect(terminal.getCharacter(col: 2, row: 0) == "e\u{301}")
    }

    @Test func aFullLiveTableCanRecoverAfterItsCellsAreCleared() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 2, scrollback: 1_000)
        var text = ""
        for color in 0..<66_000 {
            text += "\(esc)[38;2;\((color >> 16) & 255);\((color >> 8) & 255);\(color & 255)mX"
        }
        terminal.feed(text: text)
        #expect(terminal.buffer.cellArena.attributeCount <= Int(UInt16.max))
        let retryBytes = terminal.styleReclamationRetryBytes
        #expect(retryBytes > 0)
        let nextBatch = "\(esc)[38;2;231;42;122mX"
        terminal.feed(text: nextBatch)
        #expect(terminal.styleReclamationRetryBytes == retryBytes - nextBatch.utf8.count)

        terminal.feed(text: "\(esc)[3J\(esc)[2J\(esc)[H\(esc)[38;2;231;42;123mR")
        #expect(terminal.getCharData(col: 0, row: 0)?.attribute.fg == .trueColor(red: 231, green: 42, blue: 123))
    }

    @Test func nearFullLiveTableDoesNotRemapForAFewFreeStyles() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 2, scrollback: 1_000)
        var text = ""
        for color in 0..<65_500 {
            text += "\(esc)[38;2;0;\(color >> 8);\(color & 255)mX"
        }
        terminal.feed(text: text)
        let arena = terminal.buffer.cellArena
        terminal.feed(text: "\(esc)[?1049h" + animation(100))
        #expect(terminal.buffer.cellArena === arena)
        #expect(terminal.styleReclamationRetryBytes > 0)
    }

    @Test func arenaAdoptionDoesNotReuseTrimmedRows() {
        let buffer = Buffer(cols: 8, rows: 2, tabStopWidth: 8, scrollback: 4)
        buffer.fillViewportRows()
        let trimmed = buffer.lines[0]
        let oldArena = trimmed.cellArena
        buffer.lines.trimStart(count: 1)
        let arena = CellArena()
        buffer.adoptArena(arena)
        buffer.lines.count = buffer.lines.maxLength
        for index in 0..<buffer.lines.count {
            #expect(buffer.lines[index].cellArena === arena)
        }
        #expect(trimmed.cellArena === oldArena)
    }
}
