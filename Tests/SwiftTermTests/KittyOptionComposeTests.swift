//
//  KittyOptionComposeTests.swift
//
//  Regression coverage for Option-as-compose / AltGr input under the kitty
//  keyboard protocol. On layouts where a printable character is produced via
//  Option (e.g. Czech Option+2 = "@", German AltGr+Q = "@"), the composed
//  character must reach the PTY even when the application negotiates
//  reportAllKeys/reportAlternates without reportText. Previously the kitty
//  encoder keyed off the base-layout codepoint and dropped the composed glyph.
//
#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

final class KittyOptionComposeTests {

    /// Captures bytes the view sends to the PTY.
    private final class CapturingDelegate: TerminalViewDelegate {
        var sent: [UInt8] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
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

    private func optionKeyEvent(characters: String,
                                charactersIgnoringModifiers: String,
                                keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .option,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode)!
    }

    /// Czech Option+2 produces "@" while the bare key produces "ě". With the
    /// kitty protocol active (disambiguate + reportAlternates + reportAllKeys,
    /// the Bubble Tea default that OpenCode uses) and Option not acting as Meta,
    /// the PTY must receive the composed "@", not the base-layout key.
    @Test func testOptionComposedCharacterSendsComposedText() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let delegate = CapturingDelegate()
        view.terminalDelegate = delegate
        view.optionAsMetaKey = false

        // Push kitty flags 11 = disambiguate(1) + reportAlternates(2) + reportAllKeys(8).
        view.getTerminal().feed(text: "\u{1b}[>11u")

        // kVK_ANSI_2 == 19. Bare key on the Czech layout yields "ě"; Option composes "@".
        let event = optionKeyEvent(characters: "@", charactersIgnoringModifiers: "ě", keyCode: 19)
        view.keyDown(with: event)

        // keyDown sets the pending key event and forwards to interpretKeyEvents.
        // In a headless test interpretKeyEvents is a no-op, so we drive the text
        // commit ourselves. If a given environment *does* commit synchronously,
        // keyDown already produced the output and we assert on that instead, so
        // the test fails only when the composed character is actually wrong.
        if delegate.sent.isEmpty {
            view.insertText("@", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        #expect(delegate.sent == Array("@".utf8))
    }
}
#endif
