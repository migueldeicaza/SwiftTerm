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

    /// The snapshot fed into a fresh terminal of the same size, copied back.
    private func replay(_ snapshot: TerminalContentSnapshot, scrollback: Int = 20) -> TerminalContentSnapshot {
        let copy = Fixture(cols: snapshot.inputState.dimensions.cols,
                           rows: snapshot.inputState.dimensions.rows,
                           scrollback: scrollback)
        copy.feed(snapshot.ansiRepresentation())
        return copy.snapshot()
    }

    /// Row by row and cell by cell: same text, wraps, blanks, attributes
    /// and colored blanks, and the copy exports to the same bytes.
    private func expectSameContents(_ wanted: TerminalContentSnapshot, _ got: TerminalContentSnapshot,
                                    sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(got.rows.count == wanted.rows.count, sourceLocation: sourceLocation)
        // A styled blank replayed as a space can lengthen the trimmed text.
        func trimmed(_ snapshot: TerminalContentSnapshot) -> [String] {
            snapshot.rows.map { String($0.text.reversed().drop { $0 == " " }.reversed()) }
        }
        #expect(trimmed(got) == trimmed(wanted), sourceLocation: sourceLocation)
        #expect(got.rows.map(\.isWrapped) == wanted.rows.map(\.isWrapped), sourceLocation: sourceLocation)
        for (wantedRow, gotRow) in zip(wanted.rows, got.rows) {
            let row = "row \(wantedRow.absoluteRow)"
            #expect(gotRow.cells.count == wantedRow.cells.count, Comment(rawValue: row), sourceLocation: sourceLocation)
            for (x, y) in zip(wantedRow.cells, gotRow.cells) {
                if x.isBlank, x.width > 0, x.attribute.stylesShowWhenBlank {
                    // Replayed as the space that looks the same.
                    #expect(y.text == " ", Comment(rawValue: row), sourceLocation: sourceLocation)
                    #expect(y.attribute == x.attribute, Comment(rawValue: row), sourceLocation: sourceLocation)
                    continue
                }
                #expect(y.isBlank == x.isBlank, Comment(rawValue: row), sourceLocation: sourceLocation)
                if !x.isBlank {
                    #expect(y.text == x.text, Comment(rawValue: row), sourceLocation: sourceLocation)
                    #expect(y.width == x.width, Comment(rawValue: row), sourceLocation: sourceLocation)
                    #expect(y.attribute == x.attribute, Comment(rawValue: row), sourceLocation: sourceLocation)
                } else {
                    #expect(y.attribute.paintsBackground == x.attribute.paintsBackground, Comment(rawValue: row), sourceLocation: sourceLocation)
                    if x.attribute.paintsBackground {
                        #expect(y.attribute.bg == x.attribute.bg, Comment(rawValue: row), sourceLocation: sourceLocation)
                    }
                }
            }
        }
        #expect(visible(got.ansiRepresentation()) == visible(wanted.ansiRepresentation()), sourceLocation: sourceLocation)
    }

    /// The first visible difference between two snapshots, by the rules of
    /// `expectSameContents`, or nil.
    private func firstDifference(_ wanted: TerminalContentSnapshot, _ got: TerminalContentSnapshot) -> String? {
        guard got.rows.count == wanted.rows.count else { return "row count" }
        for (wantedRow, gotRow) in zip(wanted.rows, got.rows) {
            let row = "row \(wantedRow.absoluteRow)"
            guard gotRow.isWrapped == wantedRow.isWrapped else { return "\(row) wrap" }
            guard gotRow.cells.count == wantedRow.cells.count else { return "\(row) cell count" }
            for (column, (x, y)) in zip(wantedRow.cells, gotRow.cells).enumerated() {
                let cell = "\(row) column \(column)"
                if x.isBlank, x.width > 0, x.attribute.stylesShowWhenBlank {
                    guard y.text == " ", y.attribute == x.attribute else { return "\(cell) styled blank" }
                    continue
                }
                guard y.isBlank == x.isBlank else { return "\(cell) blank \(y.isBlank) wanted \(x.isBlank)" }
                if x.isBlank {
                    guard y.attribute.paintsBackground == x.attribute.paintsBackground,
                          !x.attribute.paintsBackground || y.attribute.bg == x.attribute.bg else { return "\(cell) blank background" }
                } else {
                    guard y.text == x.text, y.width == x.width, y.attribute == x.attribute else { return "\(cell) text or attribute" }
                }
            }
        }
        guard got.ansiRepresentation() == wanted.ansiRepresentation() else { return "export of the copy differs" }
        return nil
    }

    /// A seeded generator, so a failing random screen can be reproduced.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
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

    @Test func bufferAndKindLabelsKeepCursorAndPaletteData() {
        let fixture = Fixture()
        fixture.feed("\u{1b}]4;1;rgb:ff/00/ff\u{7}normal")
        fixture.feed("\u{1b}[?1049halt")
        let normal = fixture.terminal.contentSnapshot(region: .all, buffer: .normal)
        #expect(normal == fixture.terminal.contentSnapshot(region: .all, kind: .normal))
        #expect(normal.cursorRow == normal.liveTopRow)
        #expect(normal.cursorColumn == 6)
        #expect(normal.palette[1] == Color(red: 65535, green: 0, blue: 65535))
        #expect(normal.bufferKind == .normal)
        #expect(normal.inputState.isAlternateBuffer)
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

        expectSameContents(original, replay(original, scrollback: 50))
    }

    @Test func wrappedRowsStartingWithBlankCellsKeepTheirWrap() {
        let source = Fixture(cols: 6, rows: 3)
        source.feed("abcdefg\u{1b}[2;1H\u{1b}[X\u{1b}[2;4Hh")
        let original = source.snapshot()
        #expect(original.rows.map(\.text) == ["abcdef", "   h", ""])
        #expect(original.rows.map(\.isWrapped) == [false, true, false])

        let copy = replay(original)
        #expect(copy.rows.map(\.text) == ["abcdef", "   h", ""])
        #expect(copy.rows.map(\.isWrapped) == [false, true, false])
        expectSameContents(original, copy)

        // A wrapped row with nothing left on it keeps its wrap flag too.
        let empty = Fixture(cols: 6, rows: 3)
        empty.feed("abcdefg\u{1b}[2;1H\u{1b}[X\r\nx")
        #expect(empty.snapshot().rows.map(\.isWrapped) == [false, true, false])
        expectSameContents(empty.snapshot(), replay(empty.snapshot()))
    }

    @Test func rowsScrolledInByAWrapGetTheirDefaultBlanksBack() {
        let source = Fixture(cols: 6, rows: 3)
        source.feed("1\r\n2\r\n\u{1b}[44mabcdefg\u{1b}[0m\u{1b}[K")
        let original = source.snapshot()
        #expect(original.rows[3].text == "g")
        #expect(original.rows[3].cells[1].attribute.bg == .defaultColor)

        let copy = replay(original)
        #expect(copy.rows[3].text == "g")
        #expect(copy.rows[3].cells[1].attribute.bg == .defaultColor)
        #expect(copy.rows[3].cells[5].attribute.bg == .defaultColor)
        expectSameContents(original, copy)

        // Blank cells between characters of such a row are default too.
        let gap = Fixture(cols: 6, rows: 3)
        gap.feed("1\r\n2\r\n\u{1b}[44mabcdefg\u{1b}[0m\u{1b}[K\u{1b}[2Cx")
        let gapCopy = replay(gap.snapshot())
        #expect(gapCopy.rows[3].text == "g  x")
        #expect(gapCopy.rows[3].cells[2].isBlank)
        #expect(gapCopy.rows[3].cells[2].attribute.bg == .defaultColor)
        expectSameContents(gap.snapshot(), gapCopy)
    }

    @Test func erasedCellsAtTheWrapColumnStayErased() {
        let painted = Fixture(cols: 6, rows: 3)
        painted.feed("abcdefg\u{1b}[1;6H\u{1b}[44m\u{1b}[X")
        let original = painted.snapshot()
        #expect(original.rows[0].text == "abcde")
        #expect(original.rows[0].cells[5].isBlank)
        #expect(original.rows[1].isWrapped)

        let copy = replay(original)
        #expect(copy.rows[0].text == "abcde")
        #expect(copy.rows[0].cells[5].isBlank)
        #expect(copy.rows[0].cells[5].attribute.bg == .ansi256(code: 4))
        #expect(copy.rows.map(\.isWrapped) == [false, true, false])
        expectSameContents(original, copy)

        let plain = Fixture(cols: 6, rows: 3)
        plain.feed("abcdefg\u{1b}[1;6H\u{1b}[X")
        let plainCopy = replay(plain.snapshot())
        #expect(plainCopy.rows[0].text == "abcde")
        #expect(plainCopy.rows[0].cells[5].isBlank)
        #expect(!plainCopy.rows[0].cells[5].attribute.paintsBackground)
        #expect(plainCopy.rows.map(\.isWrapped) == [false, true, false])
        expectSameContents(plain.snapshot(), plainCopy)
        #expect(visible(plain.snapshot().ansiRepresentation())
                == visible("\u{1b}[0;39;49mabcde\u{1b}[6G\u{3000}\r\u{1b}[2Xg\r\n"))
    }

    @Test func wrapPlaceholdersDoNotLeakTheirColorIntoTheNextRow() {
        // A colored blank at the wrap column, then a continuation row that
        // starts blank: the erase that restores the blank must not carry the
        // placeholder's color over to the first cell of the next row.
        let fixture = Fixture(cols: 6, rows: 3)
        fixture.feed("abcdefgh\u{1b}[1;5H\u{1b}[44m\u{1b}[2X\u{1b}[2;1H\u{1b}[0m\u{1b}[2X")
        let original = fixture.snapshot()
        #expect(original.rows[0].cells[5].attribute.bg == .ansi256(code: 4))
        #expect(original.rows[1].isWrapped)
        #expect(!original.rows[1].cells[0].attribute.paintsBackground)

        let copy = replay(original)
        #expect(!copy.rows[1].cells[0].attribute.paintsBackground)
        expectSameContents(original, copy)
    }

    @Test func blankCellsWithAVisibleStyleBecomeSpaces() {
        // Overwriting one half of a wide character leaves the other half as
        // a blank that keeps the character's attribute, here in the last
        // column of a wrapping row. An erase cannot put inverse, underline
        // or crossed-out on a blank cell, so the export writes a space that
        // looks the same.
        let stub = Fixture(cols: 6, rows: 3)
        stub.feed("\u{1b}[7mabcd漢g\u{1b}[1;5H\u{1b}[0mx")
        let original = stub.snapshot()
        #expect(original.rows[0].text == "abcdx")
        #expect(original.rows[0].cells[5].isBlank)
        #expect(original.rows[0].cells[5].attribute.style.contains(.inverse))
        #expect(original.rows.map(\.isWrapped) == [false, true, false])

        let copy = replay(original)
        #expect(copy.rows[0].cells[5].text == " ")
        #expect(copy.rows[0].cells[5].attribute == original.rows[0].cells[5].attribute)
        #expect(copy.rows.map(\.isWrapped) == [false, true, false])
        expectSameContents(original, copy)

        // In the middle of a row too, when the erased half is the second.
        let halved = Fixture(cols: 6, rows: 3)
        halved.feed("\u{1b}[4mab漢\u{1b}[1;4H\u{1b}[0m\u{1b}[Kc")
        let halvedOriginal = halved.snapshot()
        #expect(halvedOriginal.rows[0].cells[2].isBlank)
        #expect(halvedOriginal.rows[0].cells[2].attribute.style.contains(.underline))
        let halvedCopy = replay(halvedOriginal)
        #expect(halvedCopy.rows[0].text == "ab c")
        #expect(halvedCopy.rows[0].cells[2].text == " ")
        #expect(halvedCopy.rows[0].cells[2].attribute.style.contains(.underline))
        expectSameContents(halvedOriginal, halvedCopy)
    }

    @Test func blankRunsAreGroupedByWhatAnEraseLeaves() {
        // The blank half of a wide character keeps a foreground color that
        // an erase drops: it joins the erased blanks next to it in one ECH,
        // and the copy exports to the same bytes.
        let fixture = Fixture(cols: 6, rows: 2)
        fixture.feed("\u{1b}[31;44mab漢\u{1b}[1;4H\u{1b}[0;44m\u{1b}[K")
        let original = fixture.snapshot()
        #expect(original.rows[0].cells[2].isBlank)
        #expect(original.rows[0].cells[2].attribute.fg == .ansi256(code: 1))
        #expect(original.rows[0].cells[3].attribute.fg == .defaultColor)
        #expect(visible(original.ansiRepresentation())
                == visible("\u{1b}[0;39;49m\u{1b}[0;31;44mab\u{1b}[0;39;44m\u{1b}[4X\u{1b}[4C\u{1b}[0;39;49m\r\n"))
        expectSameContents(original, replay(original))
    }

    /// Random mixes of `text` pieces, wide characters, colors and styles,
    /// cursor moves, erases, inserts, deletes, scrolls, margins and modes on
    /// a small screen with scrollback, each replayed: the inputs whose copy
    /// differs in appearance or in its export, with the first difference.
    private func replayFailures(seed: UInt64, text: [String]) -> [String] {
        var generator = SplitMix64(seed: seed)
        let pieces: [() -> String] = [
            { text.randomElement(using: &generator)! },
            { ["漢", "界", "日本"].randomElement(using: &generator)! },
            { ["\u{1b}[44m", "\u{1b}[31m", "\u{1b}[7m", "\u{1b}[0m", "\u{1b}[1;33m", "\u{1b}[27m", "\u{1b}[49m",
               "\u{1b}[4m", "\u{1b}[4:3m", "\u{1b}[58;5;1m", "\u{1b}[9m", "\u{1b}[2m", "\u{1b}[24m",
               "\u{1b}[38;5;\(Int.random(in: 0...255, using: &generator))m",
               "\u{1b}[48;2;\(Int.random(in: 0...255, using: &generator));7;9m"].randomElement(using: &generator)! },
            { "\u{1b}[\(Int.random(in: 1...3, using: &generator));\(Int.random(in: 1...6, using: &generator))H" },
            { "\u{1b}[\(Int.random(in: 1...6, using: &generator))\(["X", "C", "D", "@", "P"].randomElement(using: &generator)!)" },
            { ["\u{1b}[K", "\u{1b}[2K", "\u{1b}[J", "\u{1b}[2J", "\u{1b}[L", "\u{1b}[M", "\u{1b}[S", "\u{1b}[T", "\u{1b}M",
               "\u{1b}[2;3r", "\u{1b}[r", "\u{1b}[?7l", "\u{1b}[?7h", "\u{1b}[4h", "\u{1b}[4l"].randomElement(using: &generator)! },
            { ["\r\n", "\n", "\r", "\t", "\u{8}"].randomElement(using: &generator)! },
        ]
        // Mostly text, so rows fill and wrap.
        let choices = [0, 0, 0, 0, 1, 2, 2, 3, 4, 4, 5, 6]
        var failures: [String] = []
        for _ in 0..<2000 {
            var input = ""
            for _ in 0..<Int.random(in: 1...14, using: &generator) {
                input += pieces[choices.randomElement(using: &generator)!]()
            }
            // Enough scrollback that the first copied row is never the
            // continuation of a row that scrolled out.
            let fixture = Fixture(cols: 6, rows: 3, scrollback: 100)
            fixture.feed(input)
            let original = fixture.snapshot()
            if let difference = firstDifference(original, replay(original, scrollback: 100)) {
                failures.append("\(visible(input)): \(difference)")
            }
        }
        return failures
    }

    @Test func replayRoundTripsRandomScreens() {
        let failures = replayFailures(seed: 0x5e1f7e57, text: ["a", "bc", "xyz", " ", "  ", "hello", "mnopqrs"])
        #expect(failures.isEmpty, Comment(rawValue: failures.prefix(5).joined(separator: "\n")))
    }

    @Test func replayRoundTripsRandomScreensWithJoiningScalars() {
        // Scalars the terminal joins to a neighbouring cell: two with the
        // Prepend property, a combining mark on its own and on a base, a
        // Devanagari consonant and virama, a Hangul leading consonant, two
        // regional indicators, an emoji with a zero width joiner and the
        // emoji presentation selector, and a heart the selector widens.
        // An emoji modifier and a Hangul vowel are left out: after a wide
        // character that a terminal with autowrap off dropped, the terminal
        // joins them as if that character had been written.
        let failures = replayFailures(seed: 0x6a01, text: [
            "a", "xyz", "hello", "\u{0d4e}", "\u{0600}", "e\u{0301}", "\u{0301}", "\u{0915}\u{094d}", "\u{0915}",
            "\u{094d}", "\u{1100}", "\u{1f1ea}", "\u{1f1f8}", "👩", "\u{200d}", "\u{fe0f}", "\u{2764}"])
        #expect(failures.isEmpty, Comment(rawValue: failures.prefix(5).joined(separator: "\n")))
    }

    @Test func wrapsSurviveInAOneRowTerminal() {
        // With one row, the row before a wrap is in the scrollback as soon
        // as the wrap happens, so nothing written in its last column could
        // be undone afterwards; the wrap must leave that column alone.
        let fixture = Fixture(cols: 6, rows: 3)
        fixture.feed("abcdefg\u{1b}[1;6H\u{1b}[X\u{1b}[2;2H")
        fixture.terminal.resize(cols: 6, rows: 1)
        let original = fixture.snapshot()
        #expect(original.rows.map(\.text) == ["abcde", "g"])
        #expect(original.rows.map(\.isWrapped) == [false, true])

        let copy = replay(original)
        #expect(copy.rows.map(\.text) == ["abcde", "g"])
        #expect(copy.rows[0].cells[5].isBlank)
        #expect(copy.rows.map(\.isWrapped) == [false, true])
        expectSameContents(original, copy)
    }

    @Test(arguments: [2, 6], [1, 3])
    func wrapCharacterDoesNotJoinAPrependCell(cols: Int, rows: Int) {
        let fixture = Fixture(cols: cols, rows: 3)
        fixture.feed(String(repeating: "a", count: cols) + "g")
        fixture.feed("\u{1b}[1;\(cols - 1)H\u{0d4e}\u{1b}[1;\(cols)H\u{1b}[X\u{1b}[2;2H")
        fixture.terminal.terminalLock.withLock {
            fixture.terminal.resize(cols: cols, rows: rows)
        }
        let original = fixture.snapshot()
        #expect(original.rows[0].text == String(repeating: "a", count: cols - 2) + "\u{0d4e}")
        #expect(original.rows[1].text == "g")
        #expect(original.rows[1].isWrapped)
        expectSameContents(original, replay(original))

        // A cursor command must also break the cluster when the wide wrap
        // character arrives as incomplete UTF-8 in separate feeds.
        let copy = Fixture(cols: cols, rows: rows)
        for byte in original.ansiRepresentation().utf8 {
            copy.terminal.terminalLock.withLock {
                copy.terminal.feed(byteArray: [byte])
            }
        }
        expectSameContents(original, copy.snapshot())
    }

    @Test(arguments: [("\u{0d4e}", "\u{3000}", 1),
                      ("👩\u{200d}", "👩", 2),
                      ("\u{1f1eb}", "\u{1f1f7}", 2),
                      ("👍", "\u{1f3fd}", 2)])
    func separatelyPositionedCellsDoNotJoinOnReplay(sample: (String, String, Int)) {
        let (first, second, width) = sample
        let fixture = Fixture()
        fixture.feed(first)
        fixture.feed("\u{1b}[\(width + 1)G" + second)
        let original = fixture.snapshot()
        #expect(original.rows[0].cells[0].text == first)
        #expect(original.rows[0].cells[width].text == second)
        expectSameContents(original, replay(original))
    }

    @Test func normalBufferKeepsItsOwnSizeWhileTheAlternateIsActive() {
        // A resize reaches the normal buffer when it becomes visible again,
        // so a snapshot of it describes its cells with its own dimensions.
        let fixture = Fixture(cols: 12, rows: 4)
        fixture.feed("abcdefghijkl\u{1b}[?1049h")
        fixture.terminal.resize(cols: 6, rows: 2)
        let snapshot = fixture.snapshot(kind: .normal)
        #expect(snapshot.inputState.dimensions == TerminalDimensions(cols: 12, rows: 4))
        #expect(snapshot.rows.map(\.text) == ["abcdefghijkl", "", "", ""])
        #expect(snapshot.liveTopRow == 0)
        #expect(snapshot.capturedRange == 0..<4)
        #expect(fixture.snapshot(kind: .alt).inputState.dimensions == TerminalDimensions(cols: 6, rows: 2))

        let copy = replay(snapshot)
        #expect(copy.rows.map(\.text) == ["abcdefghijkl", "", "", ""])
        expectSameContents(snapshot, copy)
    }

    @Test func changedPaletteAndDefaultColorsTravelWithTheExport() throws {
        let source = Fixture(cols: 6, rows: 3)
        // Default colors first: a terminal deriving its palette from them
        // rebuilds it when they change, which would undo the OSC 4.
        source.feed("\u{1b}]10;rgb:0a/0b/0c\u{7}\u{1b}]11;rgb:10/20/30\u{7}\u{1b}]4;1;rgb:ff/00/ff\u{7}\u{1b}[31mx")
        let original = source.snapshot()
        let magenta = try #require(Color.parse("rgb:ff/00/ff"))
        #expect(original.palette[1] == magenta)
        #expect(original.defaultPalette[1] != magenta)
        #expect(original.foregroundColor == Color.parse("rgb:0a/0b/0c"))

        let copy = replay(original)
        #expect(copy.palette[1] == magenta)
        #expect(copy.palette == original.palette)
        #expect(copy.foregroundColor == original.foregroundColor)
        #expect(copy.backgroundColor == original.backgroundColor)
        #expect(copy.rows[0].cells[0].attribute.fg == .ansi256(code: 1))
        expectSameContents(original, copy)
        #expect(visible(original.ansiRepresentation()).hasPrefix(visible(
            "\u{1b}]10;rgb:0a0a/0b0b/0c0c\u{7}\u{1b}]11;rgb:1010/2020/3030\u{7}\u{1b}]4;1;rgb:ffff/0000/ffff\u{7}\u{1b}[0;39;49m")))

        // Stock colors do not travel: a plain terminal's export starts with the reset.
        let stock = Fixture(cols: 6, rows: 3)
        stock.feed("x")
        #expect(visible(stock.snapshot().ansiRepresentation()) == visible("\u{1b}[0;39;49mx\r\n\r\n"))
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
        #expect(visible(wideWrap.snapshot(.viewport).ansiRepresentation())
                == visible("\u{1b}[0;39;49m12345\u{1b}[6G\u{3000}\r\u{1b}[2X界\r\n"))

        let erased = Fixture(cols: 6, rows: 2)
        erased.feed("\u{1b}[42m\u{1b}[2K\u{1b}[0mab")
        #expect(visible(erased.snapshot(.viewport).ansiRepresentation())
                == visible("\u{1b}[0;39;49mab\u{1b}[0;39;42m\u{1b}[4X\u{1b}[4C\u{1b}[0;39;49m\r\n"))
    }

    @Test func cellsTheTerminalWouldMergeAreSeparatedByACursorMove() {
        // U+0D4E has the Unicode Prepend property: written in sequence, the
        // terminal extends a cell ending in it with whatever comes next. A
        // cursor move to the next cell's column starts a new cell instead,
        // for a styled blank written as a space as much as for text.
        let fixture = Fixture(cols: 6, rows: 3)
        fixture.feed("\u{1b}[7m漢\u{1b}[1;1H\u{0d4e}\u{1b}[1;3H\u{1b}[0mx\u{1b}[1;5H\u{0d4e}\u{1b}[1;4H\u{0d4e}")
        let original = fixture.snapshot()
        #expect(Array(original.rows[0].cells.map(\.text)[0...4]) == ["\u{0d4e}", "\u{0}", "x", "\u{0d4e}", "\u{0d4e}"])
        #expect(original.rows[0].cells[1].attribute.style.contains(.inverse))
        #expect(visible(original.ansiRepresentation())
                == visible("\u{1b}[0;39;49m\u{1b}[0;7;39;49m\u{0d4e}\u{1b}[2G \u{1b}[0;39;49mx\u{0d4e}\u{1b}[5G\u{0d4e}\r\n\r\n"))
        expectSameContents(original, replay(original))

        // The wrap moves the cursor to the last column, so the wrap character
        // never joins the cell before it.
        let wrapped = Fixture(cols: 6, rows: 3)
        wrapped.feed("abcdefg\u{1b}[1;5H\u{0d4e}\u{1b}[1;6H\u{1b}[X")
        let snapshot = wrapped.snapshot()
        #expect(visible(snapshot.ansiRepresentation())
                == visible("\u{1b}[0;39;49mabcd\u{0d4e}\u{1b}[6G\u{3000}\r\u{1b}[2Xg\r\n"))
        expectSameContents(snapshot, replay(snapshot))
    }

    @Test func cellsOnlyAutowrapOffCanFormAreWrittenWithAutowrapOff() {
        // With autowrap off, a scalar that joins the cell in the last column
        // and would widen it leaves it narrow, since there is no room; with
        // autowrap on the same text moves to the next row as a wide cell.
        let joined = Fixture(cols: 6, rows: 3)
        joined.feed("\u{1b}[?7l\u{1b}[1;6H\u{0d4e}漢")
        let original = joined.snapshot()
        #expect(original.rows[0].cells[5].text == "\u{0d4e}漢")
        #expect(original.rows[0].cells[5].width == 1)
        #expect(visible(original.ansiRepresentation())
                == visible("\u{1b}[0;39;49m\u{1b}[5C\u{1b}[?7l\u{0d4e}漢\u{1b}[?7h\r\n\r\n"))
        expectSameContents(original, replay(original))

        // A combining mark does not widen the cell it joins.
        let plain = Fixture(cols: 6, rows: 3)
        plain.feed("\u{1b}[1;6He\u{301}")
        #expect(visible(plain.snapshot().ansiRepresentation()) == visible("\u{1b}[0;39;49m\u{1b}[5Ce\u{301}\r\n\r\n"))
    }
}
