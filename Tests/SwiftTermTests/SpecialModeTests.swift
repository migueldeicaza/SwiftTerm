import Testing
@testable import SwiftTerm
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite(.serialized)
final class SpecialModeTests {
    private let esc = "\u{1b}"

    @Test func decrqm117AlwaysReportsPermanentlyReset() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()

        terminal.feed(text: "\(esc)[?117$p")
        terminal.feed(text: "\(esc)[?117h\(esc)[?117$p")
        terminal.feed(text: "\(esc)[?117l\(esc)[?117$p")

        #expect(responses(from: delegate) == Array(repeating: "\(esc)[?117;4$y", count: 3))
    }

    @Test func mutableModeQueriesTrackSetAndReset() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.synchronizedOutputTimeoutSeconds = 60

        for mode in [2004, 2026, 2031] {
            delegate.clearSentData()
            terminal.feed(text: "\(esc)[?\(mode)$p")
            terminal.feed(text: "\(esc)[?\(mode)h\(esc)[?\(mode)$p")
            terminal.feed(text: "\(esc)[?\(mode)l\(esc)[?\(mode)$p")

            #expect(responses(from: delegate) == [
                "\(esc)[?\(mode);2$y",
                "\(esc)[?\(mode);1$y",
                "\(esc)[?\(mode);2$y",
            ])
        }
    }

    @Test func laterSaveOverwritesEarlierValue() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()

        terminal.feed(text: "\(esc)[?2004h\(esc)[?2004s")
        terminal.feed(text: "\(esc)[?2004l\(esc)[?2004s")
        terminal.feed(text: "\(esc)[?2004h\(esc)[?2004r")

        #expect(!terminal.bracketedPasteMode)
    }

    @Test func restoreDoesNotConsumeSavedValue() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()

        terminal.feed(text: "\(esc)[?2031h\(esc)[?2031s\(esc)[?2031l")
        terminal.feed(text: "\(esc)[?2031r")
        #expect(terminal.colorSchemeUpdatesEnabled)

        terminal.feed(text: "\(esc)[?2031l\(esc)[?2031r")
        #expect(terminal.colorSchemeUpdatesEnabled)
    }

    @Test func unsavedRestoreAppliesReset() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        terminal.synchronizedOutputTimeoutSeconds = 60

        terminal.feed(text: "\(esc)[?2004;2026;2031h")
        terminal.feed(text: "\(esc)[?2004;2026;2031r")

        #expect(!terminal.bracketedPasteMode)
        #expect(!terminal.synchronizedOutputActive)
        #expect(!terminal.colorSchemeUpdatesEnabled)
    }

    @Test func unsavedRestoreAppliesConfiguredBidiDefault() {
        let delegate = TerminalTestDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(
                cols: 80,
                rows: 24,
                initialBidiArrowKeySwap: true))

        terminal.feed(text: "\(esc)[?1243r")
        #expect(terminal.bidiArrowKeySwap)

        terminal.feed(text: "\(esc)[?1243l\(esc)[?1243s")
        terminal.feed(text: "\(esc)[?1243h\(esc)[?1243r")
        #expect(!terminal.bidiArrowKeySwap)
    }

    @Test func multiParameterSaveAndRestoreSkipUnknownModes() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()

        terminal.feed(text: "\(esc)[?2004;2031h")
        terminal.feed(text: "\(esc)[?2004;9999;2031s")
        terminal.feed(text: "\(esc)[?2004;2031l")
        terminal.feed(text: "\(esc)[?8888;2004;7777;2031r")

        #expect(terminal.bracketedPasteMode)
        #expect(terminal.colorSchemeUpdatesEnabled)
    }

    @Test func risResetsModesAndClearsSavedSlots() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        terminal.synchronizedOutputTimeoutSeconds = 60

        terminal.feed(text: "\(esc)[?2004;2026;2031h")
        terminal.feed(text: "\(esc)[?2004;2026;2031s")
        terminal.feed(text: "\(esc)c")

        #expect(!terminal.bracketedPasteMode)
        #expect(!terminal.synchronizedOutputActive)
        #expect(!terminal.colorSchemeUpdatesEnabled)

        terminal.feed(text: "\(esc)[?2004;2026;2031h")
        terminal.feed(text: "\(esc)[?2004;2026;2031r")

        #expect(!terminal.bracketedPasteMode)
        #expect(!terminal.synchronizedOutputActive)
        #expect(!terminal.colorSchemeUpdatesEnabled)
    }

    @Test func decstrPreservesModesAndTheirSavedSlots() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        terminal.synchronizedOutputTimeoutSeconds = 60

        terminal.feed(text: "\(esc)[?2004;2026;2031h")
        terminal.feed(text: "\(esc)[?2004;2026;2031s")
        terminal.feed(text: "\(esc)[!p")

        #expect(terminal.bracketedPasteMode)
        #expect(terminal.synchronizedOutputActive)
        #expect(terminal.colorSchemeUpdatesEnabled)

        terminal.feed(text: "\(esc)[?2004;2026;2031l")
        terminal.feed(text: "\(esc)[?2004;2026;2031r")

        #expect(terminal.bracketedPasteMode)
        #expect(terminal.synchronizedOutputActive)
        #expect(terminal.colorSchemeUpdatesEnabled)
        terminal.feed(text: "\(esc)[?2004;2026;2031l")
    }

    @Test func modeQueryDoesNotMutateState() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        terminal.synchronizedOutputTimeoutSeconds = 60
        terminal.feed(text: "\(esc)[?2004;2026;2031h")

        terminal.feed(text: "\(esc)[?2004$p\(esc)[?2026$p\(esc)[?2031$p")

        #expect(terminal.bracketedPasteMode)
        #expect(terminal.synchronizedOutputActive)
        #expect(terminal.colorSchemeUpdatesEnabled)
        terminal.feed(text: "\(esc)[?2004;2026;2031l")
    }

    private func responses(from delegate: TerminalTestDelegate) -> [String] {
        delegate.sentData.map { String(decoding: $0, as: UTF8.self) }
    }
}

struct TerminalPasteTests {
    private let prefix = EscapeSequences.bracketedPasteStart
    private let suffix = EscapeSequences.bracketedPasteEnd

    @Test func replacesMandatoryControlBytesInBothModes() {
        let controls: [UInt8] = [
            0x00, 0x03, 0x04, 0x05, 0x08, 0x0f, 0x11, 0x12,
            0x13, 0x15, 0x16, 0x17, 0x1a, 0x1b, 0x1c, 0x7f,
        ]
        let spaces = Array(repeating: UInt8(0x20), count: controls.count)

        #expect(encoded(controls, bracketed: false) == spaces)
        #expect(encoded(controls, bracketed: true) == prefix + spaces + suffix)
    }

    @Test func bracketedPastePreservesLineFeedsAndAddsOneFrame() {
        let payload = Array("first\nsecond".utf8)

        #expect(encoded(payload, bracketed: true) == prefix + payload + suffix)
    }

    @Test func unbracketedPasteConvertsLineFeedsToCarriageReturns() {
        let payload = Array("first\nsecond".utf8)
        let expected = Array("first\rsecond".utf8)

        #expect(encoded(payload, bracketed: false, allowUnsafe: true) == expected)
    }

    @Test func unbracketedCrLfBecomesCrCr() {
        #expect(
            encoded(Array("a\r\nb".utf8), bracketed: false, allowUnsafe: true)
                == Array("a\r\rb".utf8)
        )
    }

    @Test func rejectsUnsafePayloadBeforeEncoding() {
        let injection = Array("before\u{1b}[201~after".utf8)

        #expect(TerminalPaste.encode(injection, bracketed: true) == .unsafePayload)
        #expect(TerminalPaste.encode(injection, bracketed: false) == .unsafePayload)
        #expect(TerminalPaste.encode(Array("a\nb".utf8), bracketed: false) == .unsafePayload)
    }

    @Test func explicitAllowFlagOverridesSafetyCheckButKeepsTransformations() {
        let payload = Array("a\n\u{1b}[201~b".utf8)

        #expect(
            encoded(payload, bracketed: false, allowUnsafe: true)
                == Array("a\r [201~b".utf8)
        )
    }

    @Test func terminalUsesDelegateControlBytesForPaste() {
        let delegate = TerminalTestDelegate()
        delegate.terminalControlBytesForPasteValue = [0x01]
        let terminal = Terminal(delegate: delegate)

        let result = terminal.paste(TerminalPasteRequest(
            source: .text,
            text: "\u{01}\u{03}"))

        #expect(result == .text)
        #expect(delegate.sentData == [[0x20, 0x03]])
    }

    private func encoded(
        _ bytes: [UInt8],
        bracketed: Bool,
        allowUnsafe: Bool = false
    ) -> [UInt8] {
        guard case .encoded(let result) = TerminalPaste.encode(
            bytes,
            bracketed: bracketed,
            allowUnsafe: allowUnsafe
        ) else {
            Issue.record("The paste was rejected")
            return []
        }
        return result
    }
}

#if !os(iOS) && !os(tvOS) && !os(Windows)
struct PseudoTerminalPasteControlTests {
    @Test func readsChangedTerminalControlBytes() {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            Issue.record("Could not create a pseudo-terminal")
            return
        }
        defer {
            close(master)
            close(slave)
        }

        var attributes = termios()
        guard tcgetattr(slave, &attributes) == 0 else {
            Issue.record("Could not read the pseudo-terminal settings")
            return
        }

        withUnsafeMutableBytes(of: &attributes.c_cc) { controls in
            controls[Int(VINTR)] = 0x01
            controls[Int(VEOF)] = 0x02
        }
        guard tcsetattr(slave, TCSANOW, &attributes) == 0 else {
            Issue.record("Could not change the pseudo-terminal settings")
            return
        }

        let first = PseudoTerminalHelpers.terminalControlBytesForPaste(
            masterPtyDescriptor: master)
        #expect(first?.contains(0x01) == true)
        #expect(first?.contains(0x02) == true)

        withUnsafeMutableBytes(of: &attributes.c_cc) { controls in
            controls[Int(VINTR)] = 0x06
        }
        guard tcsetattr(slave, TCSANOW, &attributes) == 0 else {
            Issue.record("Could not change the pseudo-terminal settings again")
            return
        }

        let second = PseudoTerminalHelpers.terminalControlBytesForPaste(
            masterPtyDescriptor: master)
        #expect(second?.contains(0x01) == false)
        #expect(second?.contains(0x02) == true)
        #expect(second?.contains(0x06) == true)
    }
}
#endif
