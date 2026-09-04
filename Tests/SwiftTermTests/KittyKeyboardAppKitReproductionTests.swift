//
//  KittyKeyboardAppKitReproductionTests.swift
//
//  AppKit integration coverage for issue #624. Enable this suite with:
//  RUN_APPKIT_TESTS=1 swift test --filter KittyKeyboardAppKitReproductionTests
//

#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import SwiftTerm

private func appKitTestsEnabled() -> Bool {
    ProcessInfo.processInfo.environment["RUN_APPKIT_TESTS"] == "1"
}

@Suite(.enabled(if: appKitTestsEnabled()))
@MainActor
final class KittyKeyboardAppKitReproductionTests {
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

    private func configuredView(flags: Int) -> (TerminalView, CapturingDelegate, NSWindow) {
        _ = NSApplication.shared

        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let capture = CapturingDelegate()
        view.terminalDelegate = capture
        view.feed(text: "\u{1b}[>\(flags)u")

        let window = NSWindow(contentRect: view.frame,
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        capture.sent.removeAll()
        return (view, capture, window)
    }

    private func keyEvent(type: NSEvent.EventType = .keyDown,
                          modifiers: NSEvent.ModifierFlags,
                          characters: String,
                          charactersIgnoringModifiers: String,
                          keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func press(flags: Int,
                       modifiers: NSEvent.ModifierFlags = [.shift],
                       characters: String,
                       charactersIgnoringModifiers: String,
                       keyCode: UInt16) -> [UInt8] {
        let (view, capture, _) = configuredView(flags: flags)
        let event = keyEvent(modifiers: modifiers,
                             characters: characters,
                             charactersIgnoringModifiers: charactersIgnoringModifiers,
                             keyCode: keyCode)
        view.keyDown(with: event)
        return capture.sent
    }

    @Test func legacyControlCUsesBaseLayoutForNonLatinInputSources() {
        let nonLatinCharacters = ["ㅊ", "с", "ذ", "ψ"]

        for character in nonLatinCharacters {
            #expect(press(flags: 0,
                          modifiers: [.control],
                          characters: "",
                          charactersIgnoringModifiers: character,
                          keyCode: 8) == [3])
        }
    }

    @Test func legacyControlUsesTheAsciiLayoutBeforeTheBaseLayout() {
        #expect(press(flags: 0,
                      modifiers: [.control],
                      characters: "\n",
                      charactersIgnoringModifiers: "j",
                      keyCode: 8) == [10])
    }

    @Test func legacyControlUsesTheC0CharacterAsTheFinalFallback() {
        #expect(press(flags: 0,
                      modifiers: [.control],
                      characters: "\u{03}",
                      charactersIgnoringModifiers: "ㅊ",
                      keyCode: 10) == [3])
    }

    @Test func kittyControlCUsesTheLayoutWithoutControlTranslation() {
        let translatedEvent = keyEvent(modifiers: [.control],
                                       characters: "\u{03}",
                                       charactersIgnoringModifiers: "\u{03}",
                                       keyCode: 8)
        let translatedScalar = translatedEvent.characters(byApplyingModifiers: [])!
            .lowercased().unicodeScalars.first!
        let baseLayoutAlternate = translatedScalar.value == 99 ? "" : "::99"

        #expect(press(flags: 1,
                      modifiers: [.control],
                      characters: "\u{03}",
                      charactersIgnoringModifiers: "\u{03}",
                      keyCode: 8) == Array("\u{1b}[\(translatedScalar.value);5u".utf8))

        #expect(press(flags: 5,
                      modifiers: [.control],
                      characters: "\u{03}",
                      charactersIgnoringModifiers: "\u{03}",
                      keyCode: 8) == Array("\u{1b}[\(translatedScalar.value)\(baseLayoutAlternate);5u".utf8))
    }

    @Test func reportAlternatesDoesNotConvertTextProducingKeysToCSIU() {
        for flags in [5, 7] { // disambiguate + reportAlternates, with optional reportEvents
            #expect(press(flags: flags,
                          characters: "E",
                          charactersIgnoringModifiers: "e",
                          keyCode: 14) == Array("E".utf8))
            #expect(press(flags: flags,
                          characters: "é",
                          charactersIgnoringModifiers: "è",
                          keyCode: 33) == Array("é".utf8))
        }
    }

    @Test func sidedModifierReleaseUsesDeviceFlags() {
        let (view, capture, _) = configuredView(flags: 10) // reportEvents + reportAllKeys
        let rightShiftMask = NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICERSHIFTKEYMASK))
        let leftShiftMask = NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICELSHIFTKEYMASK))

        // Release Left Shift while Right Shift stays down.
        view.flagsChanged(with: keyEvent(type: .flagsChanged,
                                         modifiers: [.shift, rightShiftMask],
                                         characters: "",
                                         charactersIgnoringModifiers: "",
                                         keyCode: 56))
        #expect(capture.sent == Array("\u{1b}[57441;2:3u".utf8))

        capture.sent.removeAll()

        // Release Right Shift while Left Shift stays down.
        view.flagsChanged(with: keyEvent(type: .flagsChanged,
                                         modifiers: [.shift, leftShiftMask],
                                         characters: "",
                                         charactersIgnoringModifiers: "",
                                         keyCode: 60))
        #expect(capture.sent == Array("\u{1b}[57447;2:3u".utf8))
    }

    @Test func composingCommandsAndControlTextDoNotLeak() {
        let (view, capture, _) = configuredView(flags: 10) // reportEvents + reportAllKeys
        view.setMarkedText("한",
                           selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))

        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        for character in ["\u{08}", "\u{7f}"] {
            view.setMarkedText("한",
                               selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            view.insertText(character,
                            replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        #expect(capture.sent.isEmpty)
    }

    @Test func legacyComposingCommandKeepsLegacyBehavior() {
        let (view, capture, _) = configuredView(flags: 0)
        view.setMarkedText("한",
                           selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))

        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))

        #expect(capture.sent == [0x7f])
    }

    @Test func committedImeTextIsSentOnceWithoutAKeyRelease() {
        let (view, capture, _) = configuredView(flags: 10) // reportEvents + reportAllKeys
        view.setMarkedText("ㅎ",
                           selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        let down = keyEvent(modifiers: [],
                            characters: "",
                            charactersIgnoringModifiers: "ㅎ",
                            keyCode: 4)
        view.keyDown(with: down)
        view.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))

        let up = keyEvent(type: .keyUp,
                          modifiers: [],
                          characters: "ㅎ",
                          charactersIgnoringModifiers: "ㅎ",
                          keyCode: 4)
        view.keyUp(with: up)

        #expect(capture.sent == Array("한".utf8))
    }
}
#endif
