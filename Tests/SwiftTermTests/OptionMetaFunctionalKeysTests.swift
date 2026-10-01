//
//  OptionMetaFunctionalKeysTests.swift
//
//  Coverage for `optionAsMetaKeyForFunctionalKeys`: with Option handed to the
//  layout (`optionAsMetaKey == false`), the keys the layout composes nothing
//  for keep their Meta meaning, so Option+Left reports Alt+Left while Option+Q
//  still types the layout's "@". Off, nothing changes for hosts that only set
//  `optionAsMetaKey`.
//
#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Testing
@testable import SwiftTerm

// Drives a TerminalView's input path, which must run on the main thread (F.4).
@MainActor
final class OptionMetaFunctionalKeysTests {

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

    private func keyEvent(type: NSEvent.EventType = .keyDown,
                          modifierFlags: NSEvent.ModifierFlags,
                          characters: String,
                          charactersIgnoringModifiers: String,
                          keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode)!
    }

    /// Option+Left as AppKit delivers it: an arrow carries the function and
    /// numeric-pad flags and its private-use scalar in both character fields.
    private func optionLeft() -> NSEvent {
        keyEvent(modifierFlags: [.option, .function, .numericPad],
                 characters: "\u{F702}",
                 charactersIgnoringModifiers: "\u{F702}",
                 keyCode: UInt16(kVK_LeftArrow))
    }

    private func makeView(kitty: Bool) -> (TerminalView, CapturingDelegate) {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let delegate = CapturingDelegate()
        view.terminalDelegate = delegate
        view.optionAsMetaKey = false
        view.optionAsMetaKeyForFunctionalKeys = true
        if kitty {
            // Disambiguate escape codes, the flag every kitty-protocol client pushes.
            view.feed(text: "\u{1b}[>1u")
        }
        return (view, delegate)
    }

    /// Legacy keyboard: Option+Left is Alt+Left, the xterm `CSI 1;3D` that
    /// iTerm2 sends for the same key with its Option key set to "Normal".
    @Test func testOptionLeftReportsAltLeftWithoutKittyProtocol() {
        let (view, delegate) = makeView(kitty: false)
        view.keyDown(with: optionLeft())
        #expect(delegate.sent == Array("\u{1b}[1;3D".utf8))
    }

    /// Kitty keyboard protocol: the same key reports Alt+Left.
    @Test func testOptionLeftReportsAltLeftWithKittyProtocol() {
        let (view, delegate) = makeView(kitty: true)
        view.keyDown(with: optionLeft())
        #expect(delegate.sent == Array("\u{1b}[1;3D".utf8))
    }

    /// Option+Backspace is Meta too: `ESC DEL`, the delete-word the shells read.
    @Test func testOptionBackspaceReportsMetaBackspaceWithoutKittyProtocol() {
        let (view, delegate) = makeView(kitty: false)
        view.keyDown(with: keyEvent(modifierFlags: [.option],
                                    characters: "\u{7f}",
                                    charactersIgnoringModifiers: "\u{7f}",
                                    keyCode: UInt16(kVK_Delete)))
        #expect(delegate.sent == [0x1b, 0x7f])
    }

    /// Turkish Option+Q composes "@" while the bare key is "q". The letter is
    /// the layout's, so the PTY receives the composed "@" and no ESC.
    @Test func testOptionLetterStillComposesTheLayoutCharacter() {
        let (view, delegate) = makeView(kitty: false)
        let event = keyEvent(modifierFlags: .option,
                             characters: "@",
                             charactersIgnoringModifiers: "q",
                             keyCode: UInt16(kVK_ANSI_Q))
        view.keyDown(with: event)
        // keyDown hands the key to interpretKeyEvents, a no-op in a headless
        // test, so the text commit is driven by hand when it did not happen.
        if delegate.sent.isEmpty {
            view.insertText("@", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        #expect(delegate.sent == Array("@".utf8))
    }

    /// A host that only turned `optionAsMetaKey` off sees no change: Option+Left
    /// still goes to the OS and nothing reaches the PTY from keyDown.
    @Test func testFlagOffLeavesOptionLeftToTheOS() {
        let (view, delegate) = makeView(kitty: false)
        view.optionAsMetaKeyForFunctionalKeys = false
        view.keyDown(with: optionLeft())
        #expect(delegate.sent.isEmpty)
    }
}
#endif
