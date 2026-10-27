import Foundation
import Testing
@testable import SwiftTerm

@Suite(.serialized)
struct ColumnModeTests {
    private let esc = "\u{1b}"

    private struct TestImage: TerminalImage {
        var pixelWidth = 1
        var pixelHeight = 1
        var col = 0
    }

    private func margins(_ buffer: Buffer) -> [Int] {
        [buffer.scrollTop, buffer.scrollBottom, buffer.marginLeft, buffer.marginRight]
    }

    private final class Delegate: TerminalDelegate {
        var sent: [[UInt8]] = []

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            sent.append(Array(data))
        }

        var observations: [(columns: Int, cursor: [Int], margins: [Int], page: [String], mouse: Terminal.MouseMode)] = []

        func sizeChanged(source: Terminal) {
            let buffer = source.buffer
            observations.append((source.cols, [buffer.x, buffer.y],
                [buffer.scrollTop, buffer.scrollBottom, buffer.marginLeft, buffer.marginRight],
                TerminalTestHarness.visibleLinesText(buffer: buffer, terminal: source), source.mouseMode))
        }
    }

    @Test(arguments: [80, 132])
    func columnChangePreservesStateAndNotifiesAfterPageReset(columns: Int) {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 100, rows: 5, scrollback: 20))
        terminal.feed(text: "history\r\nline2\r\nline3\r\nline4\r\nline5\r\npage")
        let historyCount = terminal.buffer.yBase
        let history = terminal.buffer.lines[0].translateToString(trimRight: true)
        terminal.feed(text: "\(esc)[62;0\"p\(esc) G\(esc)]7;file://host/tmp\(esc)\\")
        terminal.feed(text: "\(esc)[?1003;1006;2004;40;69h\(esc)[2;4r\(esc)[3;50s\(esc)[?6h\(esc)[2;4H")
        terminal.feed(text: "\(esc)_Ga=T,f=24,s=1,v=1,t=d,c=1,r=1,i=1;AQID\(esc)\\")
        #expect(terminal.kittyGraphicsState.imagesById[1] != nil)
        #expect(!terminal.kittyGraphicsState.placementsByKey.isEmpty)
        terminal.buffer.attachImage(TestImage(), toLineAt: terminal.buffer.yBase + 2)
        terminal.feed(text: "\(esc)[?3\(columns == 132 ? "h" : "l")")

        #expect(terminal.buffer.yBase == historyCount)
        #expect(terminal.buffer.lines[0].translateToString(trimRight: true) == history)
        #expect(terminal.mouseMode == .anyEvent)
        terminal.feed(text: "\(esc)[?1006$p")
        #expect(delegate.sent.last == [0x9b] + Array("?1006;1$y".utf8))
        #expect(terminal.bracketedPasteMode)
        #expect(terminal.originMode)
        #expect(terminal.conformance == .vt200)
        #expect(terminal.cc.send8bit)
        #expect(terminal.hostCurrentDirectory == "file://host/tmp")
        #expect(terminal.allow80To132)
        #expect(!terminal.marginMode)
        // The page clear removes the inline images and the Kitty images on the screen.
        #expect(!terminal.buffer.hasAnyImages)
        #expect(terminal.kittyGraphicsState.imagesById.isEmpty)
        #expect(terminal.kittyGraphicsState.placementsByKey.isEmpty)
        #expect(delegate.observations.count == 1)
        guard let observation = delegate.observations.first else { return }
        #expect(observation.columns == columns)
        #expect(observation.cursor == [0, 0])
        #expect(observation.margins == [0, 4, 0, columns - 1])
        #expect(observation.page.allSatisfy { $0.isEmpty })
        #expect(observation.mouse == .anyEvent)
    }

    @Test func columnChangeResetsMarginsOnTheInactiveBuffer() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 5)
        terminal.feed(text: "\(esc)[?40h\(esc)[?3h")
        #expect(margins(terminal.altBuffer) == [0, 4, 0, 131])

        terminal.feed(text: "\(esc)[?3l\(esc)[2;4r\(esc)[?1049h\(esc)[?3h\(esc)[?1049l")
        #expect(terminal.buffer === terminal.normalBuffer)
        #expect(terminal.buffer.cols == 132)
        #expect(margins(terminal.buffer) == [0, 4, 0, 131])
    }

    @Test func columnChangeDropsCellsPastTheNewWidth() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 5)
        terminal.feed(text: "\(esc)[?40h\(esc)[?1049h\(esc)[?3h\(esc)[1;100Hstale\(esc)[?3l")
        #expect(terminal.buffer.lines[terminal.buffer.yBase].count == 80)
        terminal.resize(cols: 132, rows: 5)
        #expect(TerminalTestHarness.lineText(buffer: terminal.buffer, terminal: terminal, row: 0) == "")
    }

    @Test func columnChangeClearsKittyImagesOnTheScreenAsGhosttyDoes() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 5, scrollback: 20)
        let pixel = "f=24,s=1,v=1,t=d,q=2"
        terminal.feed(text: "\(esc)[?40h\(esc)[?3h")
        // Image 1 goes into scrollback. Image 2 is on the screen. Image 3 has no placement.
        // Image 4 has only a virtual placement. Image 5 starts past column 80.
        terminal.feed(text: "\(esc)_Ga=T,\(pixel),c=1,r=1,i=1;AQID\(esc)\\")
        terminal.feed(text: String(repeating: "\r\n", count: 10))
        terminal.feed(text: "\(esc)_Ga=T,\(pixel),c=1,r=1,i=2;AQID\(esc)\\")
        terminal.feed(text: "\(esc)_Ga=t,\(pixel),i=3;AQID\(esc)\\")
        terminal.feed(text: "\(esc)_Ga=t,\(pixel),i=4;AQID\(esc)\\\(esc)_Ga=p,U=1,q=2,i=4,c=1,r=1\(esc)\\")
        terminal.feed(text: "\(esc)[1;100H\(esc)_Ga=T,\(pixel),c=1,r=1,i=5;AQID\(esc)\\")
        let state = terminal.kittyGraphicsState
        #expect(Set(state.placementsByKey.keys.map(\.imageId)) == [1, 2, 4, 5])
        #expect(Set(state.imagesById.keys) == [1, 2, 3, 4, 5])

        terminal.feed(text: "\(esc)[?3l")
        #expect(Set(state.placementsByKey.keys.map(\.imageId)) == [1, 4])
        #expect(Set(state.imagesById.keys) == [1, 4])
    }

    @Test func noClearModeKeepsPageDataAndSupportsQueriesAndReset() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(rows: 5)
        terminal.feed(text: "page\(esc)[?40;95h\(esc)[?3h")
        #expect(TerminalTestHarness.lineText(buffer: terminal.buffer, terminal: terminal, row: 0) == "page")
        terminal.feed(text: "\(esc)[?3l")
        #expect(TerminalTestHarness.lineText(buffer: terminal.buffer, terminal: terminal, row: 0) == "page")
        terminal.feed(text: "\(esc)[?95$p\(esc)[?95l\(esc)[?95$p\(esc)[?3h")
        #expect(delegate.sentData.map { String(decoding: $0, as: UTF8.self) } == ["\(esc)[?95;1$y", "\(esc)[?95;2$y"])
        #expect(TerminalTestHarness.visibleLinesText(buffer: terminal.buffer, terminal: terminal).allSatisfy { $0.isEmpty })
        terminal.feed(text: "\(esc)[?95h\(esc)c")
        #expect(!terminal.noClearOnColumnChange)
    }

    @Test func noClearModeNeedsConformanceLevelFive() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(rows: 5)
        terminal.feed(text: "\(esc)[64;1\"p\(esc)[?40;95h1\(esc)[?3h")
        #expect(TerminalTestHarness.visibleLinesText(buffer: terminal.buffer, terminal: terminal).allSatisfy { $0.isEmpty })

        terminal.feed(text: "\(esc)[65;1\"p\(esc)[?95h2\(esc)[?3l")
        #expect(TerminalTestHarness.lineText(buffer: terminal.buffer, terminal: terminal, row: 0) == "2")
    }

    @Test func softResetTurnsOffLeftRightMarginMode() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(rows: 5)
        terminal.feed(text: "\(esc)[?69h\(esc)[!p")
        #expect(!terminal.marginMode)
    }
}
