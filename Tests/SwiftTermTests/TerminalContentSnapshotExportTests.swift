import Foundation
import Testing
@testable import SwiftTerm

/// Buffer selection, whole-buffer and ranged regions, palette capture and
/// the ANSI export of `TerminalContentSnapshot`.
struct TerminalContentSnapshotExportTests {
    private final class Fixture {
        let delegate = TerminalTestDelegate()
        let terminal: Terminal

        init(cols: Int = 12, rows: Int = 4, scrollback: Int = 20) {
            terminal = Terminal(
                delegate: delegate,
                options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
        }

        func feed(_ text: String) {
            terminal.terminalLock.withLock {
                terminal.feed(text: text)
            }
        }

        func snapshot(_ region: TerminalContentRegion = .all,
                      kind: Terminal.BufferKind = .active) -> TerminalContentSnapshot {
            terminal.contentSnapshot(region: region, kind: kind)
        }
    }

    private func lines(_ range: ClosedRange<Int>) -> String {
        range.map { "line\($0)" }.joined(separator: "\r\n")
    }

    /// Control characters spelled out, so a failed comparison stays on one
    /// readable line.
    private func visible(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1b}", with: "<ESC>")
            .replacingOccurrences(of: "\r", with: "<CR>")
            .replacingOccurrences(of: "\n", with: "<LF>")
    }

    @Test func defaultRegionCopiesTheWholeRetainedBuffer() {
        let fixture = Fixture()
        fixture.feed(lines(1...10))
        let all = fixture.terminal.contentSnapshot()
        #expect(all.rows.count == 10)
        #expect(all.capturedRange == 0..<10)
        #expect(all.liveTopRow == 6)
        #expect(all.rows.map(\.text) == (1...10).map { "line\($0)" })
        #expect(all == fixture.snapshot(.history(maximumScrollbackRows: 100)))
        #expect(fixture.snapshot(.history(maximumScrollbackRows: 1)).rows.count == 5)
        #expect(fixture.snapshot(.viewport).rows.map(\.text) == ["line7", "line8", "line9", "line10"])
    }

    @Test func rowsRegionUsesScrollInvariantNumbersAndClamps() {
        let fixture = Fixture()
        fixture.feed(lines(1...10))
        let middle = fixture.snapshot(.rows(3..<6))
        #expect(middle.capturedRange == 3..<6)
        #expect(middle.rows.map(\.absoluteRow) == [3, 4, 5])
        #expect(middle.rows.map(\.text) == ["line4", "line5", "line6"])
        #expect(fixture.snapshot(.rows(8..<50)).capturedRange == 8..<10)
        #expect(fixture.snapshot(.rows(20..<30)).rows.isEmpty)

        let trimmed = Fixture()
        trimmed.feed(lines(1...40))
        let kept = trimmed.snapshot()
        let top = kept.capturedRange.lowerBound
        #expect(top > 0)
        #expect(kept.rows.count == 24)
        let partlyGone = trimmed.snapshot(.rows((top - 6)..<(top + 2)))
        #expect(partlyGone.capturedRange == top..<(top + 2))
        #expect(partlyGone.rows.map(\.text) == kept.rows.prefix(2).map(\.text))
    }

    @Test func kindSelectsTheNormalOrAlternateBuffer() {
        let fixture = Fixture()
        fixture.feed("normal text")
        fixture.feed("\u{1b}[?1049h\u{1b}[Halt text")
        let active = fixture.snapshot()
        #expect(active.bufferKind == .alt)
        #expect(active.inputState.isAlternateBuffer)
        #expect(active.rows.first?.text == "alt text")
        #expect(active == fixture.snapshot(kind: .alt))

        let normal = fixture.snapshot(kind: .normal)
        #expect(normal.bufferKind == .normal)
        #expect(normal.rows.first?.text == "normal text")
        #expect(normal.inputState.isAlternateBuffer)

        fixture.feed("\u{1b}[?1049l")
        #expect(fixture.snapshot().bufferKind == .normal)
        #expect(fixture.snapshot().rows.first?.text == "normal text")
        #expect(fixture.snapshot(kind: .alt).bufferKind == .alt)
    }

    @Test func paletteAndDefaultColorsAreCopiedAndStayPut() throws {
        let fixture = Fixture()
        fixture.feed("\u{1b}[31mred")
        let before = fixture.snapshot()
        #expect(before.palette.count == 256)
        #expect(before.foregroundColor == Color.defaultForeground)
        #expect(before.backgroundColor == Color.defaultBackground)
        #expect(before.rows.first?.cells.first?.attribute.fg == .ansi256(code: 1))

        let magenta = try #require(Color.parse("rgb:ff/00/ff"))
        let newForeground = Color(red: 1, green: 2, blue: 3)
        fixture.terminal.terminalLock.withLock {
            fixture.terminal.foregroundColor = newForeground
        }
        fixture.feed("\u{1b}]4;1;rgb:ff/00/ff\u{7}")
        let after = fixture.snapshot()
        #expect(after.palette[1] == magenta)
        #expect(after.foregroundColor == newForeground)
        #expect(before.palette[1] != magenta)
        #expect(before.foregroundColor == Color.defaultForeground)
    }

    @Test func blankCellsKeepTheirBackground() {
        let fixture = Fixture()
        fixture.feed("\u{1b}[44m\u{1b}[2K\u{1b}[0mab")
        let row = fixture.snapshot(.viewport).rows[0]
        #expect(row.cells[0].text == "a")
        #expect(row.cells[0].attribute.bg == .defaultColor)
        #expect(row.cells[5].isBlank)
        #expect(row.cells[5].text == "\u{0}")
        #expect(row.cells[5].attribute.bg == .ansi256(code: 4))
        #expect(row.text == "ab")

        let replay = Fixture()
        replay.feed(fixture.snapshot(.viewport).ansiRepresentation())
        let copied = replay.snapshot(.viewport).rows[0]
        #expect(copied.text == "ab")
        #expect(copied.cells[5].isBlank)
        #expect(copied.cells[5].attribute.bg == .ansi256(code: 4))
        #expect(copied.cells[11].isBlank)
        #expect(copied.cells[11].attribute.bg == .ansi256(code: 4))
    }

    @Test func sgrParametersRoundTripEveryAttribute() {
        let samples: [Attribute] = [
            Attribute(fg: .ansi256(code: 16), bg: .ansi256(code: 16), style: .none),
            Attribute(fg: .ansi256(code: 7), bg: .ansi256(code: 8), style: [.bold, .dim, .italic]),
            Attribute(fg: .ansi256(code: 15), bg: .ansi256(code: 231),
                      style: [.blink, .inverse, .invisible, .crossedOut]),
            Attribute(fg: .trueColor(red: 1, green: 2, blue: 3), bg: .trueColor(red: 4, green: 5, blue: 6),
                      style: .underline, underlineStyle: .curly,
                      underlineColor: .trueColor(red: 7, green: 8, blue: 9)),
            Attribute(fg: .defaultColor, bg: .defaultColor, style: .underline,
                      underlineStyle: .double, underlineColor: .ansi256(code: 200)),
            Attribute(fg: .ansi256(code: 0), bg: .defaultColor, style: .underline,
                      underlineStyle: .dotted, underlineColor: nil),
            Attribute(fg: .ansi256(code: 9), bg: .ansi256(code: 255), style: .underline,
                      underlineStyle: .dashed, underlineColor: nil),
        ]
        #expect(samples[0].sgrParameters() == "0;38;5;16;48;5;16")
        #expect(samples[1].sgrParameters() == "0;1;2;3;37;100")
        #expect(samples[3].sgrParameters() == "0;4:3;38;2;1;2;3;48;2;4;5;6;58;2;7;8;9")
        #expect(Attribute.empty.sgrSequence == "\u{1b}[0;39;49m")

        for sample in samples {
            let fixture = Fixture()
            fixture.feed("\u{1b}[1;4;31;43;58;5;7m")
            fixture.feed(sample.sgrSequence + "x")
            let cell = fixture.snapshot(.viewport).rows[0].cells[0]
            #expect(cell.text == "x")
            #expect(cell.attribute == sample, "\(sample.sgrParameters())")
        }
    }

    @Test func ansiRepresentationReplaysContentsAtTheSameWidth() {
        let source = Fixture(cols: 8, rows: 3, scrollback: 50)
        source.feed("\u{1b}[1;32mgreen\u{1b}[0m 12345678901234")
        source.feed("\r\n\u{1b}[45m\u{1b}[2K\u{1b}[0mx\r\n")
        source.feed("wide 界界界\r\n")
        source.feed("\u{1b}[4:3;58;5;200mcurly\u{1b}[0m end")
        source.feed("\r\ngap\u{1b}[2Cx\r\n\u{1b}[7mrev\u{1b}[0m")
        let original = source.snapshot()
        #expect(original.rows.contains { $0.isWrapped })
        #expect(original.rows.count > 3)

        let replay = Fixture(cols: 8, rows: 3, scrollback: 50)
        replay.feed(original.ansiRepresentation())
        let copy = replay.snapshot()
        #expect(copy.rows.count == original.rows.count)
        #expect(copy.rows.map(\.text) == original.rows.map(\.text))
        #expect(copy.rows.map(\.isWrapped) == original.rows.map(\.isWrapped))
        for (wanted, got) in zip(original.rows, copy.rows) {
            #expect(got.cells.count == wanted.cells.count)
            for (x, y) in zip(wanted.cells, got.cells) {
                #expect(y.isBlank == x.isBlank, "row \(wanted.absoluteRow)")
                if !x.isBlank {
                    #expect(y.text == x.text)
                    #expect(y.width == x.width)
                    #expect(y.attribute == x.attribute, "row \(wanted.absoluteRow)")
                } else if x.attribute.paintsBackground {
                    #expect(y.attribute.bg == x.attribute.bg, "row \(wanted.absoluteRow)")
                }
            }
        }
        #expect(visible(copy.ansiRepresentation()) == visible(original.ansiRepresentation()))
    }

    @Test func ansiRepresentationLeavesUnwrittenCellsAlone() {
        let fixture = Fixture(cols: 6, rows: 2)
        fixture.feed("ab\r\n")
        #expect(visible(fixture.snapshot(.viewport).ansiRepresentation()) == visible("\u{1b}[0;39;49mab\r\n"))

        let gap = Fixture(cols: 6, rows: 2)
        gap.feed("a\u{1b}[2Cb")
        #expect(visible(gap.snapshot(.viewport).ansiRepresentation()) == visible("\u{1b}[0;39;49ma\u{1b}[2Cb\r\n"))

        let wideWrap = Fixture(cols: 6, rows: 3)
        wideWrap.feed("12345界")
        #expect(wideWrap.snapshot(.viewport).rows[1].isWrapped)
        #expect(visible(wideWrap.snapshot(.viewport).ansiRepresentation()) == visible("\u{1b}[0;39;49m12345界\r\n"))

        let erased = Fixture(cols: 6, rows: 2)
        erased.feed("\u{1b}[42m\u{1b}[2K\u{1b}[0mab")
        #expect(visible(erased.snapshot(.viewport).ansiRepresentation())
                == visible("\u{1b}[0;39;49mab\u{1b}[0;39;42m\u{1b}[4X\u{1b}[4C\u{1b}[0;39;49m\r\n"))
    }
}
