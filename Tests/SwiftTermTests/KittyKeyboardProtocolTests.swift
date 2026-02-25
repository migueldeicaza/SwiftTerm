import Testing
@testable import SwiftTerm

final class KittyKeyboardProtocolTests {
    private let esc = "\u{1b}"

    @Test func testPlainCsiURestoresCursor() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[3;3H")
        terminal.feed(text: "\(esc)7")
        terminal.feed(text: "\(esc)[8;8H")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 7, row: 7)

        terminal.feed(text: "\(esc)[u")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 2, row: 2)
    }

    @Test func testUnknownCsiUIntermediateDoesNotRestoreCursor() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[3;3H")
        terminal.feed(text: "\(esc)7")
        terminal.feed(text: "\(esc)[8;8H")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 7, row: 7)

        terminal.feed(text: "\(esc)[!u")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 7, row: 7)
    }

    @Test func testKittySetInvalidModeIgnored() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[=1;1u")
        #expect(terminal.keyboardEnhancementFlags == [.disambiguate])

        terminal.feed(text: "\(esc)[=2;9u")
        #expect(terminal.keyboardEnhancementFlags == [.disambiguate])
    }

    @Test func testKittyPopNoParamsDefaultsToOne() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[=1;1u")
        #expect(terminal.keyboardEnhancementFlags == [.disambiguate])

        terminal.feed(text: "\(esc)[>8u")
        #expect(terminal.keyboardEnhancementFlags == [.reportAllKeys])

        terminal.feed(text: "\(esc)[<u")
        #expect(terminal.keyboardEnhancementFlags == [.disambiguate])
    }

    @Test func testKittyPopZeroAlsoDefaultsToOne() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[=1;1u")
        terminal.feed(text: "\(esc)[>8u")
        #expect(terminal.keyboardEnhancementFlags == [.reportAllKeys])

        terminal.feed(text: "\(esc)[<0u")
        #expect(terminal.keyboardEnhancementFlags == [.disambiguate])
    }

    @Test func testKittyQueryReturnsCurrentFlags() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[=5;1u")
        #expect(terminal.keyboardEnhancementFlags == [.disambiguate, .reportAlternates])

        terminal.feed(text: "\(esc)[?u")
        let response = String(decoding: delegate.sentData.last ?? [], as: UTF8.self)
        #expect(response == "\(esc)[?5u")
    }

    @Test func testFullResetClearsAlternateScreenKittyKeyboardState() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[?1049h")
        terminal.feed(text: "\(esc)[=12;1u")
        #expect(terminal.keyboardEnhancementFlags == [.reportAlternates, .reportAllKeys])

        terminal.feed(text: "\(esc)[?1049l")
        terminal.resetToInitialState()

        terminal.feed(text: "\(esc)[?1049h")
        #expect(terminal.keyboardEnhancementFlags.isEmpty)
    }

    @Test func testNormalAndAlternateScreensKeepSeparateKeyboardModes() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[=1;1u")
        #expect(terminal.keyboardEnhancementFlags == [.disambiguate])

        terminal.feed(text: "\(esc)[?1049h")
        #expect(terminal.keyboardEnhancementFlags.isEmpty)

        terminal.feed(text: "\(esc)[=8;1u")
        #expect(terminal.keyboardEnhancementFlags == [.reportAllKeys])

        terminal.feed(text: "\(esc)[?1049l")
        #expect(terminal.keyboardEnhancementFlags == [.disambiguate])

        terminal.feed(text: "\(esc)[?1049h")
        #expect(terminal.keyboardEnhancementFlags == [.reportAllKeys])
    }

    @Test func testKittyPushPopRestoresPreviousState() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[=1;1u")
        #expect(terminal.keyboardEnhancementFlags == [.disambiguate])

        terminal.feed(text: "\(esc)[>8u")
        #expect(terminal.keyboardEnhancementFlags == [.reportAllKeys])

        terminal.feed(text: "\(esc)[>4u")
        #expect(terminal.keyboardEnhancementFlags == [.reportAlternates])

        terminal.feed(text: "\(esc)[<2u")
        #expect(terminal.keyboardEnhancementFlags == [.disambiguate])
    }

    @Test func testKittyPopTooManyClearsState() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[=1;1u")
        terminal.feed(text: "\(esc)[>8u")
        #expect(terminal.keyboardEnhancementFlags == [.reportAllKeys])

        terminal.feed(text: "\(esc)[<3u")
        #expect(terminal.keyboardEnhancementFlags.isEmpty)
    }

    @Test func testKittyPushBeyondStackLimitDropsOldestEntry() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[=1;1u")
        terminal.feed(text: "\(esc)[>4u")
        for _ in 0..<15 {
            terminal.feed(text: "\(esc)[>8u")
        }

        terminal.feed(text: "\(esc)[>8u")
        #expect(terminal.keyboardEnhancementFlags == [.reportAllKeys])

        terminal.feed(text: "\(esc)[<16u")
        #expect(terminal.keyboardEnhancementFlags == [.reportAlternates])
    }
}
