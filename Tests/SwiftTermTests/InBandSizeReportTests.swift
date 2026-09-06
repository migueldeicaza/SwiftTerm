import Testing
@testable import SwiftTerm

@Suite(.serialized)
final class InBandSizeReportTests {
    private let esc = "\u{1b}"

    @Test func decrqmTracksSubscriptionState() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        terminal.feed(text: "\(esc)[?2048$p")
        terminal.feed(text: "\(esc)[?2048h")
        terminal.feed(text: "\(esc)[?2048$p")
        terminal.feed(text: "\(esc)[?2048l")
        terminal.feed(text: "\(esc)[?2048$p")

        #expect(responses(from: delegate) == [
            "\(esc)[?2048;2$y",
            "\(esc)[?2048;1$y",
            "\(esc)[?2048;2$y",
        ])
    }

    @Test func decsetWithKnownGeometrySendsExactReport() {
        let (terminal, delegate) = terminalWithKnownGeometry()

        terminal.feed(text: "\(esc)[?2048h")

        #expect(response(from: delegate) == "\(esc)[48;24;80;432;720t")
    }

    @Test func repeatedDecsetRepeatsReport() {
        let (terminal, delegate) = terminalWithKnownGeometry()

        terminal.feed(text: "\(esc)[?2048h\(esc)[?2048h")

        #expect(responses(from: delegate) == [
            "\(esc)[48;24;80;432;720t",
            "\(esc)[48;24;80;432;720t",
        ])
    }

    @Test func decsetWithoutGeometryIsSilent() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        terminal.feed(text: "\(esc)[?2048h")

        #expect(terminal.inBandSizeReportsEnabled)
        #expect(delegate.sentData.isEmpty)
    }

    @Test func firstGeometryUpdateReports() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?2048h")

        terminal.updatePixelGeometry(cellWidth: 9, cellHeight: 18)

        #expect(response(from: delegate) == "\(esc)[48;24;80;432;720t")
    }

    @Test func gridResizeReportsOnceAfterCommit() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.updatePixelGeometry(cellWidth: 9, cellHeight: 18)
        terminal.feed(text: "\(esc)[?2048h")
        delegate.clearSentData()

        terminal.resize(cols: 100, rows: 30)

        #expect(responses(from: delegate) == ["\(esc)[48;30;100;540;900t"])
    }

    @Test func sameGridCommittedResizeReports() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.updatePixelGeometry(cellWidth: 9, cellHeight: 18)
        terminal.feed(text: "\(esc)[?2048h")
        delegate.clearSentData()

        terminal.resize(cols: 80, rows: 24)

        #expect(responses(from: delegate) == ["\(esc)[48;24;80;432;720t"])
    }

    @Test func cellSizeOnlyChangeReports() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.updatePixelGeometry(cellWidth: 9, cellHeight: 18)
        terminal.feed(text: "\(esc)[?2048h")
        delegate.clearSentData()

        terminal.updatePixelGeometry(cellWidth: 10, cellHeight: 20)
        terminal.updatePixelGeometry(cellWidth: 10, cellHeight: 20)

        #expect(responses(from: delegate) == ["\(esc)[48;24;80;480;800t"])
    }

    @Test func unchangedGeometryPreservesSynchronizedOutputAndSendsNoReport() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.updatePixelGeometry(cellWidth: 9, cellHeight: 18)
        terminal.feed(text: "\(esc)[?2048h\(esc)[?2026h")
        delegate.clearSentData()

        terminal.updatePixelGeometry(cellWidth: 9, cellHeight: 18)
        terminal.updatePixelGeometry(cellWidth: 9, cellHeight: 18)

        #expect(terminal.synchronizedOutputActive)
        #expect(delegate.sentData.isEmpty)
        terminal.feed(text: "\(esc)[?2026l")
    }

    @Test func xtwinopsPrefersCommittedPixelGeometry() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        delegate.cellSizeInPixelsValue = (width: 10, height: 20)
        terminal.updatePixelGeometry(cellWidth: 9, cellHeight: 18)

        terminal.feed(text: "\(esc)[14t\(esc)[16t")

        #expect(responses(from: delegate) == [
            "\(esc)[4;432;720t",
            "\(esc)[6;18;9t",
        ])
    }

    @Test func decrstAndRisSuppressLaterReports() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.updatePixelGeometry(cellWidth: 9, cellHeight: 18)
        terminal.feed(text: "\(esc)[?2048h")
        delegate.clearSentData()

        terminal.feed(text: "\(esc)[?2048l")
        terminal.resize(cols: 90, rows: 25)
        #expect(delegate.sentData.isEmpty)

        terminal.feed(text: "\(esc)[?2048h")
        delegate.clearSentData()
        terminal.feed(text: "\(esc)c")
        let geometryAfterReset = terminal.pixelGeometry
        terminal.updatePixelGeometry(cellWidth: 10, cellHeight: 20)

        #expect(!terminal.inBandSizeReportsEnabled)
        #expect(geometryAfterReset == TerminalPixelGeometry(
            rows: 25, columns: 90, cellWidth: 9, cellHeight: 18))
        #expect(delegate.sentData.isEmpty)
    }

    @Test func xtrestoreToSetReportsImmediately() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.updatePixelGeometry(cellWidth: 9, cellHeight: 18)
        terminal.feed(text: "\(esc)[?2048h\(esc)[?2048s\(esc)[?2048l")
        delegate.clearSentData()

        terminal.feed(text: "\(esc)[?2048r")

        #expect(terminal.inBandSizeReportsEnabled)
        #expect(response(from: delegate) == "\(esc)[48;24;80;432;720t")
    }

    @Test func hugeCellDimensionsSaturateWithoutTrapping() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?2048h")

        terminal.updatePixelGeometry(cellWidth: Int.max, cellHeight: Int.max)

        #expect(response(from: delegate) ==
            "\(esc)[48;24;80;\(Int.max);\(Int.max)t")
    }

    private func terminalWithKnownGeometry() -> (Terminal, TerminalTestDelegate) {
        let result = TerminalTestHarness.makeTerminal()
        result.delegate.cellSizeInPixelsValue = (width: 9, height: 18)
        return result
    }

    private func response(from delegate: TerminalTestDelegate) -> String {
        String(decoding: delegate.sentData.last ?? [], as: UTF8.self)
    }

    private func responses(from delegate: TerminalTestDelegate) -> [String] {
        delegate.sentData.map { String(decoding: $0, as: UTF8.self) }
    }
}
