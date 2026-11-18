//
//  LinkLookupTests.swift
//
//
//  Created by Codex on 1/31/26.
//

import Foundation
import Testing

@testable import SwiftTerm

final class LinkLookupTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {
    }

    private func write(_ text: String, terminal: Terminal, row: Int, col: Int = 0) {
        guard row >= 0 && row < terminal.displayBuffer.lines.count else {
            return
        }
        let line = terminal.displayBuffer.lines[row]
        var x = col
        for ch in text {
            guard x < terminal.cols else { break }
            line[x] = terminal.makeCharData(attribute: CharData.defaultAttr, char: ch)
            x += 1
        }
    }

    @Test func osc8CanBeDisabledAtStartupWithoutDisablingDetectedLinks() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(
            cols: 80, rows: 2, enableOsc8Hyperlinks: false))
        terminal.feed(text: "\u{1b}]8;;https://hidden.example\u{07}https://visible.example\u{1b}]8;;\u{07}")
        let location = Terminal.LinkLookupLocation.screen(Position(col: 2, row: 0))
        #expect(terminal.link(at: location, mode: .explicitOnly) == nil)
        #expect(terminal.link(at: location, mode: .explicitAndImplicit) == "https://visible.example")
        #expect(terminal.getCharData(col: 2, row: 0)?.hasPayload == false)
    }

    @Test func disablingOsc8HidesExistingLinksAndClearsTheActiveTarget() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 2))
        terminal.feed(text: "\u{1b}]8;;https://target.example\u{07}link")
        let location = Terminal.LinkLookupLocation.screen(Position(col: 1, row: 0))
        #expect(terminal.link(at: location, mode: .explicitOnly) == "https://target.example")
        terminal.enableOsc8Hyperlinks = false
        #expect(terminal.link(at: location, mode: .explicitOnly) == nil)
        terminal.enableOsc8Hyperlinks = true
        #expect(terminal.link(at: location, mode: .explicitOnly) == "https://target.example")
        terminal.feed(text: "plain")
        #expect(terminal.link(at: .screen(Position(col: 4, row: 0)), mode: .explicitOnly) == nil)
    }

    @Test func osc8TargetsKeepUTF8ForValidationAndPreview() {
        let terminal = Terminal(delegate: self)
        let target = "https://example.com/日本\u{202E}file"
        terminal.feed(text: "\u{1b}]8;;\(target)\u{07}link\u{1b}]8;;\u{07}")
        #expect(terminal.link(at: .screen(Position(col: 1, row: 0)), mode: .explicitOnly) == target)
    }

    @Test func testExplicitLinkLookup() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 1))
        terminal.feed(text: "abc")

        let payload = "id;https://example.com"
        let atom = terminal.makePayload(value: payload)!
        let line = terminal.displayBuffer.lines[0]
        var cd = line[1]
        cd.setPayload(atom: atom)
        line[1] = cd

        let link = terminal.link(at: .buffer(Position(col: 1, row: 0)), mode: .explicitOnly)
        #expect(link == "https://example.com")
    }

    @Test func testGarbageCollectionDoesNotReleaseAnotherTerminalsPayload() {
        let first = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))
        let second = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 1))

        first.feed(text: "\u{1b}]8;;https://first.example\u{07}first\u{1b}]8;;\u{07}")
        second.feed(text: "\u{1b}]8;;https://second.example\u{07}second\u{1b}]8;;\u{07}")

        let firstAtom = first.displayBuffer.lines[0][0].payload
        let secondAtom = second.displayBuffer.lines[0][0].payload
        #expect(firstAtom.target != nil)
        #expect(secondAtom.target != nil)

        first.feed(text: "\u{1b}[2J")
        first.garbageCollectPayload()

        #expect(firstAtom.target == nil)
        #expect(secondAtom.target != nil)
    }

    @Test func testTinyAtomConcurrentLookupAndRelease() async {
        let allValuesMatched = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for value in 0..<1_000 {
                group.addTask {
                    guard let atom = TinyAtom.lookup(value: value) else {
                        return false
                    }
                    let matched = atom.target as? Int == value
                    atom.release()
                    return matched
                }
            }

            var result = true
            for await matched in group {
                result = result && matched
            }
            return result
        }

        #expect(allValuesMatched)
    }

    @Test func testTerminalOwnedPayloadIsGarbageCollected() throws {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 1))
        terminal.feed(text: "abc")

        let atom = try #require(terminal.makePayload(value: "https://example.com"))
        let line = try #require(terminal.getLine(row: 0))
        var cell = line[0]
        cell.setPayload(atom: atom)
        line[0] = cell

        terminal.feed(text: "\u{1b}[2J")
        terminal.garbageCollectPayload()

        #expect(atom.target == nil)
    }

    @Test func testCallerOwnedPayloadCanBeReleased() throws {
        let atom = try #require(TinyAtom.lookup(value: "https://example.com"))

        atom.release()

        #expect(atom.target == nil)
    }

    @Test func testImplicitUrlLookup() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 40, rows: 1))
        terminal.feed(text: "https://example.com tail")

        let link = terminal.link(at: .buffer(Position(col: 5, row: 0)), mode: .explicitAndImplicit)
        #expect(link == "https://example.com")
    }

    @Test func testImplicitFilePathLookup() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 30, rows: 1))
        terminal.feed(text: "/tmp/example.txt")

        let link = terminal.link(at: .buffer(Position(col: 2, row: 0)), mode: .explicitAndImplicit)
        #expect(link == "/tmp/example.txt")
    }

    @Test func testImplicitUrlLookupAcrossWrappedLines() {
        let url = "https://example.com/path"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 8, rows: 4))
        terminal.feed(text: url)

        let topRowLink = terminal.link(at: .buffer(Position(col: 2, row: 0)), mode: .explicitAndImplicit)
        #expect(topRowLink == url)

        let wrappedRowLink = terminal.link(at: .buffer(Position(col: 1, row: 1)), mode: .explicitAndImplicit)
        #expect(wrappedRowLink == url)
    }

    @Test func testImplicitMatchReportsPerRowRangesAcrossWrap() {
        let url = "https://example.com/path"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 8, rows: 4))
        terminal.feed(text: url)

        guard let match = terminal.linkMatch(at: .buffer(Position(col: 1, row: 1)), mode: .explicitAndImplicit) else {
            Issue.record("Expected implicit link match on wrapped row")
            return
        }
        #expect(match.text == url)
        #expect(match.rowRanges.count >= 2)
        #expect(match.rowRanges.contains { $0.row == 0 })
        #expect(match.rowRanges.contains { $0.row == 1 })
        #expect(match.rowRanges.first(where: { $0.row == 1 })?.range.contains(1) == true)
    }

    private func implicitMatch(_ terminal: Terminal, col: Int, row: Int) -> Terminal.LinkMatch? {
        terminal.linkMatch(at: .buffer(Position(col: col, row: row)), mode: .explicitAndImplicit)
    }

    private func implicitLink(_ terminal: Terminal, col: Int, row: Int) -> String? {
        terminal.link(at: .buffer(Position(col: col, row: row)), mode: .explicitAndImplicit)
    }

    // MARK: - Implicit link boundaries follow recorded wraps (Ghostty)

    @Test func testAutomaticWrapRecordsFullWidthMarkOnEachPrintPath() {
        // ASCII run, scalar run (wide), and single characters.
        for text in ["abcdefghijkl", "日本語日本語", "e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}"] {
            let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 8, rows: 4))
            terminal.feed(text: text)
            let lines = terminal.displayBuffer.lines
            #expect(lines[0].isScreenEdgeWrapped == false)
            #expect(lines[1].isWrapped, "\(text)")
            #expect(lines[1].isScreenEdgeWrapped, "\(text)")
        }
    }

    @Test func testAutomaticWrapThatScrollsRecordsFullWidthMark() {
        let url = "https://example.com/path/file.txt"
        // Normal buffer with scrollback, and the alternate buffer.
        for prefix in ["", "\u{1b}[?1049h"] {
            let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 8, rows: 2))
            terminal.feed(text: prefix + "x\r\ny\r\n" + url)
            let buffer = terminal.displayBuffer
            let last = buffer.lines.count - 1
            #expect(buffer.lines[last].isScreenEdgeWrapped)
            #expect(implicitLink(terminal, col: 0, row: last) == url)
        }
    }

    @Test func testAutomaticWrapInsideScrollRegionRecordsFullWidthMark() {
        // Three rows of text from the last row of a region of three rows.
        let url = "https://example.com/path"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 8, rows: 6))
        terminal.feed(text: "\u{1b}[2;4r\u{1b}[4;1H" + url)
        let lines = terminal.displayBuffer.lines
        #expect(lines[1].isWrapped == false)
        #expect(lines[2].isScreenEdgeWrapped)
        #expect(lines[3].isScreenEdgeWrapped)
        #expect(implicitLink(terminal, col: 0, row: 1) == url)
        #expect(implicitLink(terminal, col: 0, row: 3) == url)
    }

    @Test func testAddressFollowedByRuleIsOneLink() {
        // The `swift package preview-documentation` output at a narrow width.
        let address = "http://localhost:8080/documentation/swiftterm"
        for cols in [address.count, address.count + 1, address.count + 4] {
            let terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: 4))
            terminal.feed(text: address + "\r\n" + String(repeating: "=", count: cols) + "\r\n")
            #expect(terminal.displayBuffer.lines[1].isWrapped == false)
            let match = implicitMatch(terminal, col: 10, row: 0)
            #expect(match?.text == address, "cols \(cols)")
            #expect(match?.rowRanges == [.init(row: 0, range: 0..<address.count)], "cols \(cols)")
            #expect(implicitLink(terminal, col: 3, row: 1) == nil)
        }
    }

    @Test func testUrlThatFillsLastColumnEndsAtHardBreak() {
        let url = "https://example.com/"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: url.count, rows: 4))
        terminal.feed(text: url + "\r\npath/file.txt")
        let first = implicitMatch(terminal, col: 4, row: 0)
        #expect(first?.text == url)
        #expect(first?.rowRanges == [.init(row: 0, range: 0..<url.count)])
        let second = implicitMatch(terminal, col: 2, row: 1)
        #expect(second?.text == "path/file.txt")
        #expect(second?.rowRanges == [.init(row: 1, range: 0..<13)])
    }

    @Test func testUrlWithTrailingSlashNearEdgeEndsAtHardBreak() {
        let url = "https://example.com/docs/"
        for next in ["word", "=========="] {
            let terminal = Terminal(delegate: self, options: TerminalOptions(cols: url.count + 2, rows: 4))
            terminal.feed(text: url + "\r\n" + next)
            let match = implicitMatch(terminal, col: 4, row: 0)
            #expect(match?.text == url, "\(next)")
            #expect(match?.rowRanges == [.init(row: 0, range: 0..<url.count)], "\(next)")
            #expect(implicitLink(terminal, col: 1, row: 1) == nil, "\(next)")
        }
    }

    @Test func testUrlAcrossRecordedWrapMatchesFromEitherRow() {
        let url = "https://example.com/path"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 4))
        terminal.feed(text: url)
        let expected: [Terminal.LinkMatch.RowRange] = [
            .init(row: 0, range: 0..<20),
            .init(row: 1, range: 0..<4)
        ]
        for (col, row) in [(5, 0), (2, 1)] {
            let match = implicitMatch(terminal, col: col, row: row)
            #expect(match?.text == url)
            #expect(match?.rowRanges == expected)
            #expect(match?.row == row)
        }
    }

    @Test func testRowsDrawnWithCursorMovementAreSeparateLines() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 4))
        let firstSegment = "https://example.com/this/is/a/long/url/segment/that/reaches/the/visual/wrap/part"
        #expect(firstSegment.count == 80)
        terminal.feed(text: "\u{1b}[1;1H" + firstSegment + "\u{1b}[2;1H" + "and/keeps/going.txt")
        #expect(terminal.displayBuffer.lines[1].isWrapped == false)

        let first = implicitMatch(terminal, col: 20, row: 0)
        #expect(first?.text == firstSegment)
        #expect(first?.rowRanges == [.init(row: 0, range: 0..<80)])
        let second = implicitMatch(terminal, col: 8, row: 1)
        #expect(second?.text == "and/keeps/going.txt")
        #expect(second?.rowRanges == [.init(row: 1, range: 0..<19)])
    }

    @Test func testWrapMarkWithoutRecordedCauseDoesNotJoinRows() {
        // A host, or reflow of older content, can set `isWrapped` alone.
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 16, rows: 3))
        write("https://example.", terminal: terminal, row: 0)
        write("com/path", terminal: terminal, row: 1)
        terminal.displayBuffer.lines[1].isWrapped = true

        #expect(implicitLink(terminal, col: 3, row: 0) == "https://example")
        #expect(implicitLink(terminal, col: 6, row: 1) == nil)
    }

    @Test func testWrapAtInternalRightMarginDoesNotJoinRows() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 30, rows: 4))
        // DECLRMM, then columns 1 to 20 as the margins.
        terminal.feed(text: "\u{1b}[?69h\u{1b}[1;20s\u{1b}[1;1H" + "https://example.com/path/file.txt")
        let lines = terminal.displayBuffer.lines
        #expect(lines[1].isWrapped)
        #expect(lines[1].isScreenEdgeWrapped == false)

        let first = implicitMatch(terminal, col: 3, row: 0)
        #expect(first?.text == "https://example.com/")
        #expect(first?.rowRanges == [.init(row: 0, range: 0..<20)])
        let second = implicitMatch(terminal, col: 2, row: 1)
        #expect(second?.text == "path/file.txt")
        #expect(second?.rowRanges == [.init(row: 1, range: 0..<13)])
    }

    @Test func testWrapToLeftMarginAfterColumnZeroDoesNotJoinRows() {
        // The cells left of the margin are not part of the text.
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 4))
        terminal.feed(text: "\u{1b}[2;1HREADME.md")
        terminal.feed(text: "\u{1b}[?69h\u{1b}[10;20s\u{1b}[1;10H" + "x http://a.b" + "c")
        let lines = terminal.displayBuffer.lines
        #expect(lines[1].isWrapped)
        #expect(lines[1].isScreenEdgeWrapped == false)
        #expect(implicitLink(terminal, col: 13, row: 0) == "http://a")
        #expect(implicitLink(terminal, col: 2, row: 1) == nil)
    }

    @Test func testLeadingSpacesAfterRecordedWrapRemainABoundary() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 3))
        terminal.feed(text: "https://example.com/" + "    sub/file.txt")
        #expect(terminal.displayBuffer.lines[1].isScreenEdgeWrapped)

        let first = implicitMatch(terminal, col: 3, row: 0)
        #expect(first?.text == "https://example.com/")
        #expect(first?.rowRanges == [.init(row: 0, range: 0..<20)])
        let second = implicitMatch(terminal, col: 6, row: 1)
        #expect(second?.text == "sub/file.txt")
        #expect(second?.rowRanges == [.init(row: 1, range: 4..<16)])
        #expect(implicitLink(terminal, col: 1, row: 1) == nil)
    }

    @Test func testSpacesBeforeRecordedWrapRemainABoundary() {
        // A printed space, and a cell that the cursor moved over.
        for gap in [" ", "\u{1b}[20G"] {
            let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 3))
            terminal.feed(text: "https://a.example/" + gap + "yz/w.txt")
            #expect(terminal.displayBuffer.lines[1].isScreenEdgeWrapped)

            let first = implicitMatch(terminal, col: 3, row: 0)
            #expect(first?.text == "https://a.example/")
            #expect(first?.rowRanges == [.init(row: 0, range: 0..<18)])
            let second = implicitMatch(terminal, col: 2, row: 1)
            #expect(second?.text == "yz/w.txt")
            #expect(second?.rowRanges == [.init(row: 0, range: 19..<20), .init(row: 1, range: 0..<7)])
        }
    }

    @Test func testWideCharacterThatDoesNotFitKeepsLinkAcrossWrap() {
        let url = "https://e.example/日本"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 19, rows: 3))
        terminal.feed(text: url)
        #expect(terminal.displayBuffer.lines[1].isScreenEdgeWrapped)
        #expect(implicitLink(terminal, col: 3, row: 0) == url)
        #expect(implicitLink(terminal, col: 1, row: 1) == url)
    }

    @Test func testOsc8LinkWinsOverImplicitLinkInTheSameCell() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 3))
        terminal.feed(text: "\u{1b}]8;;https://target.example\u{07}https://visible.example/path\u{1b}]8;;\u{07}")
        for (col, row) in [(4, 0), (2, 1)] {
            let match = implicitMatch(terminal, col: col, row: row)
            #expect(match?.text == "https://target.example")
            #expect(match?.isExplicit == true)
        }
    }

    @Test func testSemanticRoleChangeEndsTheLogicalLine() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 4))
        // Prompt "/usr/", then input that wraps at the screen edge.
        terminal.feed(text: "\u{1b}]133;A\u{07}/usr/\u{1b}]133;B\u{07}bin/a.txt/more/long")
        #expect(terminal.displayBuffer.lines[1].isScreenEdgeWrapped)
        #expect(terminal.displayBuffer.lines[0][4].semanticContent != terminal.displayBuffer.lines[0][5].semanticContent)

        let prompt = implicitMatch(terminal, col: 2, row: 0)
        #expect(prompt?.text == "/usr/")
        #expect(prompt?.rowRanges == [.init(row: 0, range: 0..<5)])
        let expected: [Terminal.LinkMatch.RowRange] = [
            .init(row: 0, range: 5..<10),
            .init(row: 1, range: 0..<10),
            .init(row: 2, range: 0..<4)
        ]
        for (col, row) in [(7, 0), (3, 1), (1, 2)] {
            let input = implicitMatch(terminal, col: col, row: row)
            #expect(input?.text == "bin/a.txt/more/long")
            #expect(input?.rowRanges == expected)
        }
    }

    @Test func testOutputWithoutSemanticRolesIsUnaffectedByOutputRole() {
        // Cells with the output role and cells with no role are one class.
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 40, rows: 3))
        terminal.feed(text: "\u{1b}]133;C\u{07}see\u{1b}[5Ghttps://example.com/x")
        #expect(implicitLink(terminal, col: 10, row: 0) == "https://example.com/x")
    }

    // MARK: - The full-width mark follows the row state

    @Test func testLineFeedIntoWrappedRowEndsTheLink() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 4))
        terminal.feed(text: "https://example.com/path")
        #expect(terminal.displayBuffer.lines[1].isScreenEdgeWrapped)
        // Repaint in place: the same rows, now with a hard line break.
        terminal.feed(text: "\u{1b}[1;1H" + "https://example.com/" + "\r\n" + "path")
        #expect(terminal.displayBuffer.lines[1].isWrapped == false)
        #expect(implicitLink(terminal, col: 3, row: 0) == "https://example.com/")
        #expect(implicitLink(terminal, col: 1, row: 1) == nil)
    }

    @Test func testEraseToEndOfLineEndsTheLinkToTheNextRow() {
        for erase in ["\u{1b}[1;13H\u{1b}[K", "\u{1b}[1;13H\u{1b}[2K\u{1b}[1;1Hhttps://exam"] {
            let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 4))
            terminal.feed(text: "https://example.com/path/file.txt")
            terminal.feed(text: erase)
            let line = terminal.displayBuffer.lines[1]
            // Reflow keeps the paragraph. Link lookup does not.
            #expect(line.isWrapped)
            #expect(line.isScreenEdgeWrapped == false)
            #expect(implicitLink(terminal, col: 3, row: 0) == "https://exam")
            #expect(implicitLink(terminal, col: 3, row: 1) == "path/file.txt")
        }
    }

    @Test func testEraseOnContinuationRowKeepsTheLink() {
        // zsh and less: CR and EL on the continuation row, then its text.
        let url = "https://example.com/path/file.txt"
        for erase in ["\r\u{1b}[K", "\r\u{1b}[2K"] {
            let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 4))
            terminal.feed(text: String(url.prefix(21)) + erase + String(url.dropFirst(20)))
            #expect(terminal.displayBuffer.lines[1].isScreenEdgeWrapped, "\(erase.debugDescription)")
            #expect(implicitLink(terminal, col: 3, row: 0) == url, "\(erase.debugDescription)")
            #expect(implicitLink(terminal, col: 3, row: 1) == url, "\(erase.debugDescription)")

            // The link is also complete after reflow.
            terminal.feed(text: "\r\n\r\n")
            terminal.resize(cols: 12, rows: 4)
            let buffer = terminal.displayBuffer
            let row = (0..<buffer.lines.count).first { buffer.lines[$0].translateToString(trimRight: true).hasPrefix("https://") }!
            for offset in 0..<3 {
                #expect(implicitLink(terminal, col: 3, row: row + offset) == url, "\(erase.debugDescription)")
            }
        }
    }

    @Test func testCharacterEditsEndTheLinkToTheNextRow() {
        // ICH, DCH, ECH, and a character in insert mode change the end of
        // the row. Its text then does not continue on the next row.
        let edits = [
            ("\u{1b}[1;1H\u{1b}[@", "\u{0}https://example.com"),
            ("\u{1b}[1;1H\u{1b}[P", "ttps://example.com/"),
            ("\u{1b}[1;20H\u{1b}[X", "https://example.com"),
            ("\u{1b}[1;1H\u{1b}[4h>\u{1b}[4l", ">https://example.com"),
            ("\u{1b}[1;1H\u{1b}[4h日\u{1b}[4l", "日\u{0}https://example.co")
        ]
        for (sequence, firstRow) in edits {
            let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 4))
            terminal.feed(text: "https://example.com/path")
            terminal.feed(text: sequence)
            let lines = terminal.displayBuffer.lines
            #expect(lines[0].translateToString(trimRight: true) == firstRow, "\(sequence.debugDescription)")
            #expect(lines[1].translateToString(trimRight: true) == "path", "\(sequence.debugDescription)")
            #expect(lines[1].isWrapped, "\(sequence.debugDescription)")
            #expect(lines[1].isScreenEdgeWrapped == false, "\(sequence.debugDescription)")
            #expect(implicitLink(terminal, col: 1, row: 1) == nil, "\(sequence.debugDescription)")
            if let match = implicitMatch(terminal, col: 10, row: 0) {
                #expect(match.rowRanges.allSatisfy { $0.row == 0 }, "\(sequence.debugDescription)")
            }
        }
    }

    @Test func testResizeWithoutReflowKeepsTheLink() {
        let url = "https://example.com/path/file.txt"
        // The paragraph with the cursor in the normal buffer, and the
        // alternate buffer.
        for prefix in ["", "\u{1b}[?1049h"] {
            let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 4))
            terminal.feed(text: prefix + url)
            terminal.resize(cols: 30, rows: 4)
            #expect(terminal.displayBuffer.lines[1].isScreenEdgeWrapped)
            let expected: [Terminal.LinkMatch.RowRange] = [
                .init(row: 0, range: 0..<20),
                .init(row: 1, range: 0..<13)
            ]
            for (col, row) in [(3, 0), (3, 1)] {
                let match = implicitMatch(terminal, col: col, row: row)
                #expect(match?.text == url, "\(prefix.debugDescription)")
                #expect(match?.rowRanges == expected, "\(prefix.debugDescription)")
            }
            #expect(implicitLink(terminal, col: 25, row: 0) == nil)
        }
    }

    @Test func testNarrowerResizeWithoutReflowDoesNotJoinCutRows() {
        for prefix in ["", "\u{1b}[?1049h"] {
            let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 4))
            terminal.feed(text: prefix + "https://example.com/path/file.txt")
            terminal.resize(cols: 12, rows: 4)
            let buffer = terminal.displayBuffer
            let row = (0..<buffer.lines.count).first { buffer.lines[$0].translateToString(trimRight: true).hasPrefix("https://") }!
            let match = implicitMatch(terminal, col: 3, row: row)
            #expect(match?.text == "https://exam", "\(prefix.debugDescription)")
            #expect(match?.rowRanges == [.init(row: row, range: 0..<12)], "\(prefix.debugDescription)")
        }
    }

    @Test func testWideCharacterSpacerWithBackgroundColorKeepsLink() {
        let url = "https://e.example/日本"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 19, rows: 3))
        terminal.feed(text: "\u{1b}[44m\u{1b}[K" + url)
        #expect(terminal.displayBuffer.lines[1].isScreenEdgeWrapped)
        #expect(implicitLink(terminal, col: 3, row: 0) == url)
        #expect(implicitLink(terminal, col: 1, row: 1) == url)
    }

    @Test func testMarkedRowBelowTheScrollRegionIsNotANewLine() {
        // The cursor is below the region. The wrap scrolls the region and
        // the cursor stays on its row.
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 8, rows: 6))
        terminal.feed(text: "\u{1b}[1;3r\u{1b}[5;1H" + "https://a.b/c")
        for row in 0..<6 {
            #expect(terminal.displayBuffer.lines[row].isScreenEdgeWrapped == false)
        }
    }

    @Test func testEraseAndResetClearTheMark() {
        for sequence in ["\u{1b}[2J", "\u{1b}c", "\u{1b}[2;1H\u{1b}[L", "\u{1b}[1;1H\u{1b}[M"] {
            let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 4))
            terminal.feed(text: "https://example.com/path/file.txt")
            terminal.feed(text: sequence)
            for line in 0..<4 {
                #expect(terminal.displayBuffer.lines[line].isScreenEdgeWrapped == false, "\(sequence.debugDescription)")
            }
        }
    }

    @Test func testMarkMovesWithScrolledRows() {
        let url = "https://example.com/path"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 3))
        terminal.feed(text: url + "\r\nb\r\nc\r\nd\r\ne")
        let buffer = terminal.displayBuffer
        #expect(buffer.lines[1].isScreenEdgeWrapped)
        #expect(implicitLink(terminal, col: 2, row: 1) == url)
        for row in 2..<buffer.lines.count {
            #expect(buffer.lines[row].isWrapped == false)
        }
    }

    @Test func testReflowRecomputesTheMark() {
        let url = "https://example.com/path/file.txt"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 40, rows: 6))
        terminal.feed(text: url + "\r\n" + "====" + "\r\n")

        terminal.resize(cols: 12, rows: 6)
        var buffer = terminal.displayBuffer
        var row = (0..<buffer.lines.count).first { buffer.lines[$0].translateToString(trimRight: true).hasPrefix("https://") }!
        #expect(buffer.lines[row + 1].isScreenEdgeWrapped)
        #expect(buffer.lines[row + 2].isScreenEdgeWrapped)
        #expect(buffer.lines[row + 3].isWrapped == false)
        #expect(implicitLink(terminal, col: 2, row: row) == url)
        #expect(implicitLink(terminal, col: 2, row: row + 2) == url)

        terminal.resize(cols: 20, rows: 6)
        buffer = terminal.displayBuffer
        row = (0..<buffer.lines.count).first { buffer.lines[$0].translateToString(trimRight: true).hasPrefix("https://") }!
        #expect(buffer.lines[row + 1].isScreenEdgeWrapped)
        #expect(buffer.lines[row + 2].isWrapped == false)
        #expect(implicitLink(terminal, col: 2, row: row + 1) == url)

        terminal.resize(cols: 40, rows: 6)
        buffer = terminal.displayBuffer
        row = (0..<buffer.lines.count).first { buffer.lines[$0].translateToString(trimRight: true).hasPrefix("https://") }!
        #expect(buffer.lines[row + 1].isWrapped == false)
        #expect(implicitLink(terminal, col: 2, row: row) == url)
    }

    @Test func testReflowKeepsAMarginSeamOutOfTheLink() {
        // A wrap at an internal right margin. Reflow keeps the blank cells
        // between the margin and the screen edge, so the two parts do not
        // join at a width that puts the seam inside a row or at a wrap.
        for newCols in [12, 15, 25, 60] {
            let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 30, rows: 6))
            terminal.feed(text: "\u{1b}[?69h\u{1b}[1;20s\u{1b}[1;1H" + "https://example.com/path/file.txt")
            terminal.feed(text: "\u{1b}[?69l\u{1b}[5;1H")
            terminal.resize(cols: newCols, rows: 6)
            let buffer = terminal.displayBuffer
            for row in 0..<buffer.lines.count {
                for col in 0..<newCols {
                    if let link = implicitLink(terminal, col: col, row: row) {
                        #expect(link == "https://example.com/" || link == "path/file.txt", "cols \(newCols)")
                    }
                }
            }
            let row = (0..<buffer.lines.count).first { buffer.lines[$0].translateToString(trimRight: true).hasPrefix("https://") }!
            #expect(implicitLink(terminal, col: 3, row: row) == "https://example.com/", "cols \(newCols)")
        }
    }

    @Test func testReflowKeepsASeamWithoutRecordedCauseAtAWrap() {
        // A seam with no recorded cause that reflow leaves at a wrap.
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 16, rows: 6))
        terminal.feed(text: "https://example.\r\ncom/path\r\n\r\n")
        terminal.displayBuffer.lines[1].isWrapped = true
        terminal.resize(cols: 8, rows: 6)
        let buffer = terminal.displayBuffer
        let row = (0..<buffer.lines.count).first { buffer.lines[$0].translateToString(trimRight: true).hasPrefix("https://") }!
        #expect(buffer.lines[row + 1].isScreenEdgeWrapped)
        #expect(buffer.lines[row + 2].isWrapped)
        #expect(buffer.lines[row + 2].isScreenEdgeWrapped == false)
        #expect(implicitLink(terminal, col: 3, row: row) == "https://example")
        #expect(implicitLink(terminal, col: 3, row: row + 2) == nil)
    }

    @Test func testReflowDoesNotJoinTextAcrossABlankGap() {
        // A tab and a cursor movement leave blank cells between the paths.
        // Reflow can put those cells at the end of a row.
        let cases: [(String, [String])] = [
            ("/tmp/a.txt\t/tmp/b.txt\t/tmp/c.txt", ["/tmp/a.txt", "/tmp/b.txt", "/tmp/c.txt"]),
            ("see ./a.txt\u{1b}[5C./b.txt and more", ["./a.txt", "./b.txt"]),
        ]
        for (text, expected) in cases {
            let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 60, rows: 8))
            terminal.feed(text: text + "\r\n\r\n")
            terminal.resize(cols: 16, rows: 8)
            let buffer = terminal.displayBuffer
            var found: [String] = []
            for row in 0..<buffer.lines.count {
                for col in 0..<16 {
                    if let link = implicitLink(terminal, col: col, row: row), !found.contains(link) {
                        found.append(link)
                    }
                }
            }
            #expect(found == expected, "\(text.debugDescription)")
        }
    }

    @Test func testReflowKeepsALinkThatHasNoGap() {
        let url = "https://example.com/a/long/path/file.txt"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 60, rows: 8))
        terminal.feed(text: "a\t" + url + "\r\n\r\n")
        terminal.resize(cols: 16, rows: 8)
        #expect(implicitLink(terminal, col: 12, row: 0) == url)
        #expect(implicitLink(terminal, col: 3, row: 1) == url)
        #expect(implicitLink(terminal, col: 3, row: 2) == url)
        terminal.resize(cols: 30, rows: 8)
        #expect(implicitLink(terminal, col: 12, row: 0) == url)
        #expect(implicitLink(terminal, col: 3, row: 1) == url)
    }

    @Test func testWideCharacterAfterASkippedGapStartsNewText() {
        // The cursor moves to the last column over blank cells. The wide
        // character does not fit there and wraps.
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 3))
        terminal.feed(text: "./a.txt\u{1b}[1;20H日本.txt")
        let lines = terminal.displayBuffer.lines
        #expect(lines[1].isWrapped)
        #expect(lines[1].isScreenEdgeWrapped == false)
        #expect(implicitLink(terminal, col: 3, row: 0) == "./a.txt")
        #expect(implicitLink(terminal, col: 5, row: 1) != "./a.txt日本.txt")
    }

    // Issue #850: `swift package preview-documentation` prints an address
    // line and then a row of `=` characters. The URL ends near the right
    // edge of a narrow window.
    @Test func testImplicitUrlDoesNotAbsorbBannerRuleOnNextLine() {
        let url = "http://localhost:8080/documentation/tecolot"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 60, rows: 4))
        terminal.feed(text: "  Address: \(url)\r\n========================================\r\n")

        #expect(implicitLink(terminal, col: 20, row: 0) == url)
        #expect(implicitLink(terminal, col: 5, row: 1) == nil)
    }

    // Issue #850.
    @Test func testImplicitUrlDoesNotAbsorbWordOnNextLineAfterRealNewline() {
        let url = "http://localhost:8080/documentation/tecolot"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: url.count + 2, rows: 4))
        terminal.feed(text: "\(url)\r\nStarting\r\n")

        #expect(implicitLink(terminal, col: 10, row: 0) == url)
    }

    @Test func testImplicitUrlLookupDoesNotJoinUnrelatedRows() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 92, rows: 3))
        write("https://example.com", terminal: terminal, row: 0)
        write("nextline", terminal: terminal, row: 1)

        let urlRowLink = terminal.link(at: .buffer(Position(col: 10, row: 0)), mode: .explicitAndImplicit)
        #expect(urlRowLink == "https://example.com")

        let nextRowLink = terminal.link(at: .buffer(Position(col: 2, row: 1)), mode: .explicitAndImplicit)
        #expect(nextRowLink == nil)
    }

    @Test func testImplicitBareDomainDoesNotMatch() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 30, rows: 1))
        terminal.feed(text: "example.com")

        let link = terminal.link(at: .buffer(Position(col: 3, row: 0)), mode: .explicitAndImplicit)
        #expect(link == nil)
    }

    @Test func testWhitespaceReturnsNil() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 1))
        terminal.feed(text: "a b")

        let link = terminal.link(at: .buffer(Position(col: 1, row: 0)), mode: .explicitAndImplicit)
        #expect(link == nil)
    }

    @Test func testScreenCoordinates() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 32, rows: 2))
        terminal.feed(text: "https://www.example.com")

        let link = terminal.link(at: .screen(Position(col: 10, row: 0)), mode: .explicitAndImplicit)
        #expect(link == "https://www.example.com")
    }
}
