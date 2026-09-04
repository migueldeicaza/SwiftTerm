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

    private func press(flags: Int,
                       modifiers: NSEvent.ModifierFlags = [.shift],
                       characters: String,
                       charactersIgnoringModifiers: String,
                       keyCode: UInt16) -> [UInt8] {
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

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )!
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

    @Test func kittyControlCPreservesTheLayoutAndBaseLayoutKeys() {
        #expect(press(flags: 1,
                      modifiers: [.control],
                      characters: "\u{03}",
                      charactersIgnoringModifiers: "ㅊ",
                      keyCode: 8) == Array("\u{1b}[12618;5u".utf8))

        #expect(press(flags: 5,
                      modifiers: [.control],
                      characters: "\u{03}",
                      charactersIgnoringModifiers: "ㅊ",
                      keyCode: 8) == Array("\u{1b}[12618::99;5u".utf8))
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
}
#endif
