#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Testing
@testable import SwiftTerm

/// Control with `/`, `?`, or a digit from 2 to 8 sends the C0 byte kitty and Ghostty send.
/// AppKit leaves these keys' characters unchanged under Control, so there is no control
/// character in the event to fall back on.
@MainActor
final class MacControlPunctuationAndDigitTests {
    private final class CapturingDelegate: TerminalViewDelegate {
        var sent: [UInt8] = []

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            sent.append(contentsOf: data)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    private struct Press {
        let keyCode: Int
        let shift: Bool
        /// What AppKit reports on a US layout: the key's own character, unchanged by Control.
        let characters: String
        let charactersIgnoringModifiers: String
        let legacyByte: UInt8
    }

    private let presses: [Press] = [
        Press(keyCode: kVK_ANSI_Slash, shift: false, characters: "/", charactersIgnoringModifiers: "/", legacyByte: 0x1f),
        Press(keyCode: kVK_ANSI_Slash, shift: true, characters: "/", charactersIgnoringModifiers: "?", legacyByte: 0x7f),
        Press(keyCode: kVK_ANSI_2, shift: false, characters: "2", charactersIgnoringModifiers: "2", legacyByte: 0x00),
        Press(keyCode: kVK_ANSI_3, shift: false, characters: "3", charactersIgnoringModifiers: "3", legacyByte: 0x1b),
        Press(keyCode: kVK_ANSI_4, shift: false, characters: "4", charactersIgnoringModifiers: "4", legacyByte: 0x1c),
        Press(keyCode: kVK_ANSI_5, shift: false, characters: "5", charactersIgnoringModifiers: "5", legacyByte: 0x1d),
        Press(keyCode: kVK_ANSI_6, shift: false, characters: "6", charactersIgnoringModifiers: "6", legacyByte: 0x1e),
        Press(keyCode: kVK_ANSI_7, shift: false, characters: "7", charactersIgnoringModifiers: "7", legacyByte: 0x1f),
        Press(keyCode: kVK_ANSI_8, shift: false, characters: "8", charactersIgnoringModifiers: "8", legacyByte: 0x7f),
    ]

    private func event(for press: Press) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: press.shift ? [.control, .shift] : .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: press.characters,
            charactersIgnoringModifiers: press.charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: UInt16(press.keyCode)
        )!
    }

    @Test func controlKeysSendTheirLegacyBytes() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let delegate = CapturingDelegate()
        view.terminalDelegate = delegate

        for press in presses {
            view.keyDown(with: event(for: press))
        }

        #expect(delegate.sent == presses.map(\.legacyByte))
    }

    @Test func controlSlashKeepsItsCodepointWithKittyKeyboardProtocol() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let delegate = CapturingDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\u{1b}[>1u")

        view.keyDown(with: event(for: presses[0]))

        #expect(delegate.sent == Array("\u{1b}[47;5u".utf8))
    }

    /// The iOS hardware and on-screen keyboards share this table.
    @Test func theTableMatchesKittysLegacyControlBytes() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let expected: [String: UInt8] = [
            "/": 0x1f, "?": 0x7f, "@": 0x00, "2": 0x00, "3": 0x1b, "4": 0x1c, "5": 0x1d, "6": 0x1e, "7": 0x1f, "8": 0x7f,
        ]
        for (character, byte) in expected {
            #expect(view.applyControlToEventCharacters(character) == [byte], "\(character)")
        }
        for character in ["0", "1", "9", "=", ".", ","] {
            #expect(view.applyControlToEventCharacters(character).isEmpty, "\(character)")
        }
    }
}
#endif
