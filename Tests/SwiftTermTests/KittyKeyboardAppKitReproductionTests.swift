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

@Suite(.enabled(if: appKitTestsEnabled()), .serialized)
@MainActor
final class KittyKeyboardAppKitReproductionTests {
    private final class TrackingShortcutView: TerminalView {
        var copiedText: String?
        var handledShortcut: String?

        override func copy(_ sender: Any) {
            copiedText = getSelection()
        }

        @objc func handleTestShortcut(_ sender: NSMenuItem) {
            handledShortcut = sender.title
        }

        override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            if item.action == #selector(handleTestShortcut(_:)) { return true }
            return super.validateUserInterfaceItem(item)
        }
    }

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

    @Test func legacyControlPrefersAppKitTranslationOverTheBaseLayout() {
        // German ISO layout: Ctrl+ü sits on the PC-101 "[" position, but
        // AppKit translates it to GS, which is what Terminal.app sends.
        #expect(press(flags: 0,
                      modifiers: [.control],
                      characters: "\u{1d}",
                      charactersIgnoringModifiers: "ü",
                      keyCode: 33) == [0x1d])
    }

    @Test func legacyControlBackspaceFollowsBackspaceSendsControlH() {
        let (view, capture, _) = configuredView(flags: 0)
        view.backspaceSendsControlH = true
        view.keyDown(with: keyEvent(modifiers: [.control],
                                    characters: "\u{7f}",
                                    charactersIgnoringModifiers: "\u{7f}",
                                    keyCode: 51))
        #expect(capture.sent == [8])
    }

    @Test func plainTextKeyReportsItsReleaseWithoutReportAllKeys() {
        let (view, capture, _) = configuredView(flags: 3) // disambiguate + reportEvents
        view.keyDown(with: keyEvent(modifiers: [],
                                    characters: "a",
                                    charactersIgnoringModifiers: "a",
                                    keyCode: 0))
        #expect(capture.sent == Array("a".utf8))

        capture.sent.removeAll()
        view.keyUp(with: keyEvent(type: .keyUp,
                                  modifiers: [],
                                  characters: "a",
                                  charactersIgnoringModifiers: "a",
                                  keyCode: 0))
        #expect(capture.sent == Array("\u{1b}[97;1:3u".utf8))
    }

    @Test func optionAsMetaToggleDoesNotReportARelease() {
        let (view, capture, _) = configuredView(flags: 10) // reportEvents + reportAllKeys
        let modifiers: NSEvent.ModifierFlags = [.option, .command]
        view.keyDown(with: keyEvent(modifiers: modifiers,
                                    characters: "ø",
                                    charactersIgnoringModifiers: "o",
                                    keyCode: 31))
        view.keyUp(with: keyEvent(type: .keyUp,
                                  modifiers: modifiers,
                                  characters: "ø",
                                  charactersIgnoringModifiers: "o",
                                  keyCode: 31))
        #expect(capture.sent.isEmpty)
    }

    @Test func commandKeyWithoutMenuReportsPressAndRelease() {
        let (view, capture, _) = configuredView(flags: 10) // reportEvents + reportAllKeys
        view.keyDown(with: keyEvent(modifiers: [.command],
                                    characters: "k",
                                    charactersIgnoringModifiers: "k",
                                    keyCode: 40))
        view.keyUp(with: keyEvent(type: .keyUp,
                                  modifiers: [.command],
                                  characters: "k",
                                  charactersIgnoringModifiers: "k",
                                  keyCode: 40))
        #expect(capture.sent == Array("\u{1b}[107;9u\u{1b}[107;9:3u".utf8))
    }

    private func withCopyMenu(for view: TerminalView, body: () -> Void) {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu
        let menu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        let copyItem = NSMenuItem(title: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
        copyItem.target = view
        editMenu.addItem(copyItem)
        menu.addItem(editItem)
        menu.setSubmenu(editMenu, for: editItem)
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = previousMenu }
        body()
    }

    private func withShortcutMenu(for view: TrackingShortcutView,
                                  key: String,
                                  modifiers: NSEvent.ModifierFlags = [.command],
                                  body: () -> Void) {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu
        let menu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        let shortcutItem = NSMenuItem(title: key,
                                      action: #selector(TrackingShortcutView.handleTestShortcut(_:)),
                                      keyEquivalent: key)
        shortcutItem.keyEquivalentModifierMask = modifiers
        shortcutItem.target = view
        editMenu.addItem(shortcutItem)
        menu.addItem(editItem)
        menu.setSubmenu(editMenu, for: editItem)
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = previousMenu }
        body()
    }

    @Test func hostMenuHandlesOtherCommandShortcuts() {
        let shortcuts: [(String, String, NSEvent.ModifierFlags, UInt16)] = [
            ("a", "a", [.command], 0),
            ("v", "v", [.command], 9),
            ("f", "f", [.command], 3),
            ("g", "g", [.command], 5),
            ("G", "G", [.command, .shift], 5),
            ("e", "e", [.command], 14)
        ]
        for flags in [0, 10] { // legacy and reportEvents + reportAllKeys
            for (key, unmodified, modifiers, keyCode) in shortcuts {
                let view = TrackingShortcutView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
                let capture = CapturingDelegate()
                view.terminalDelegate = capture
                view.feed(text: "\u{1b}[>\(flags)u")
                withShortcutMenu(for: view, key: key, modifiers: modifiers) {
                    view.keyDown(with: keyEvent(modifiers: modifiers,
                                                characters: key,
                                                charactersIgnoringModifiers: unmodified,
                                                keyCode: keyCode))
                    #expect(view.handledShortcut == key)
                    view.keyUp(with: keyEvent(type: .keyUp,
                                              modifiers: [],
                                              characters: unmodified,
                                              charactersIgnoringModifiers: unmodified,
                                              keyCode: keyCode))
                    #expect(capture.sent.isEmpty)
                }
            }
        }
    }

    @Test func hostMenuCopiesSelectionBeforeKeyDownClearsIt() {
        for flags in [0, 10] { // legacy and reportEvents + reportAllKeys
            let view = TrackingShortcutView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
            let capture = CapturingDelegate()
            view.terminalDelegate = capture
            view.feed(text: "copy me")
            view.feed(text: "\u{1b}[>\(flags)u")
            view.selectAll()
            capture.sent.removeAll()

            withCopyMenu(for: view) {
                view.keyDown(with: keyEvent(modifiers: [.command],
                                            characters: "c",
                                            charactersIgnoringModifiers: "c",
                                            keyCode: 8))
                #expect(view.copiedText?.contains("copy me") == true)
                #expect(view.getSelection() != nil)
                view.keyUp(with: keyEvent(type: .keyUp,
                                          modifiers: [], // Command was released first.
                                          characters: "c",
                                          charactersIgnoringModifiers: "c",
                                          keyCode: 8))
                #expect(capture.sent.isEmpty)
            }
        }
    }

    @Test func hostCanGiveCommandShortcutToTheTerminal() {
        let view = TrackingShortcutView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let capture = CapturingDelegate()
        view.terminalDelegate = capture
        view.feed(text: "\u{1b}[>10u") // reportEvents + reportAllKeys
        view.shouldSendCommandKeyToTerminal = { $0.charactersIgnoringModifiers == "c" }
        let window = keyWindow(containing: [view])
        window.makeFirstResponder(view)

        withCopyMenu(for: view) {
            let down = keyEvent(modifiers: [.command],
                                characters: "c",
                                charactersIgnoringModifiers: "c",
                                keyCode: 8)
            #expect(view.performKeyEquivalent(with: down))
            #expect(view.copiedText == nil)
            #expect(capture.sent == Array("\u{1b}[99;9u".utf8))
            let pressCount = capture.sent.count
            view.keyUp(with: keyEvent(type: .keyUp,
                                      modifiers: [.command],
                                      characters: "c",
                                      charactersIgnoringModifiers: "c",
                                      keyCode: 8))
            #expect(capture.sent.count > pressCount)
        }
    }

    /// A test process cannot make a window key, so this window says it is.
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    private func keyWindow(containing views: [NSView]) -> NSWindow {
        _ = NSApplication.shared
        let window = KeyWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 200),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        for view in views {
            window.contentView?.addSubview(view)
        }
        return window
    }

    @Test func unfocusedTerminalDoesNotTakeCommandShortcut() {
        let focused = TrackingShortcutView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let unfocused = TrackingShortcutView(frame: CGRect(x: 400, y: 0, width: 400, height: 200))
        let focusedCapture = CapturingDelegate()
        let unfocusedCapture = CapturingDelegate()
        focused.terminalDelegate = focusedCapture
        unfocused.terminalDelegate = unfocusedCapture
        unfocused.feed(text: "select me")
        unfocused.feed(text: "\u{1b}[>10u") // reportEvents + reportAllKeys
        unfocused.selectAll()
        unfocused.shouldSendCommandKeyToTerminal = { _ in true }
        unfocusedCapture.sent.removeAll()

        let window = keyWindow(containing: [focused, unfocused])
        window.makeFirstResponder(focused)

        let down = keyEvent(modifiers: [.command],
                            characters: "c",
                            charactersIgnoringModifiers: "c",
                            keyCode: 8)
        #expect(!unfocused.performKeyEquivalent(with: down))
        #expect(unfocusedCapture.sent.isEmpty)
        #expect(unfocused.getSelection() != nil)

        unfocused.keyUp(with: keyEvent(type: .keyUp,
                                       modifiers: [.command],
                                       characters: "c",
                                       charactersIgnoringModifiers: "c",
                                       keyCode: 8))
        #expect(unfocusedCapture.sent.isEmpty)
    }

    @Test func disabledCopyMenuDoesNotCopyOrSendInput() {
        let view = TrackingShortcutView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let capture = CapturingDelegate()
        view.terminalDelegate = capture
        view.feed(text: "\u{1b}[>10u")

        withCopyMenu(for: view) {
            view.keyDown(with: keyEvent(modifiers: [.command],
                                        characters: "c",
                                        charactersIgnoringModifiers: "c",
                                        keyCode: 8))
            #expect(view.copiedText == nil)
            #expect(capture.sent.isEmpty)
        }
    }

    @Test func reportedPressKeepsItsReleaseAfterCommandIsPressed() {
        let (view, capture, _) = configuredView(flags: 10) // reportEvents + reportAllKeys
        view.keyDown(with: keyEvent(modifiers: [],
                                    characters: "a",
                                    charactersIgnoringModifiers: "a",
                                    keyCode: 0))
        if capture.sent.isEmpty {
            view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        let pressCount = capture.sent.count
        #expect(pressCount > 0)

        view.keyUp(with: keyEvent(type: .keyUp,
                                  modifiers: [.command],
                                  characters: "a",
                                  charactersIgnoringModifiers: "a",
                                  keyCode: 0))
        #expect(capture.sent.count > pressCount)
    }

    @Test func releaseWithoutAReportedPressIsNotSent() {
        let (view, capture, _) = configuredView(flags: 10) // reportEvents + reportAllKeys
        // AppKit handled the key equivalent before the view saw keyDown.
        view.keyUp(with: keyEvent(type: .keyUp,
                                  modifiers: [], // Command was released first.
                                  characters: "v",
                                  charactersIgnoringModifiers: "v",
                                  keyCode: 9))
        #expect(capture.sent.isEmpty)
    }

    @Test func commandKeyWithoutAHostShortcutReachesTheTerminal() {
        let view = TrackingShortcutView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let capture = CapturingDelegate()
        view.terminalDelegate = capture
        view.feed(text: "\u{1b}[>10u")

        withCopyMenu(for: view) {
            view.keyDown(with: keyEvent(modifiers: [.command],
                                        characters: "f",
                                        charactersIgnoringModifiers: "f",
                                        keyCode: 3))
            #expect(capture.sent == Array("\u{1b}[102;9u".utf8))
        }
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

    @Test func legacyCommitClearsComposingStateForKittyMode() {
        // A legacy-mode dead-key commit must not leave the view composing:
        // once an app enables the protocol, commands must still be sent.
        let (view, capture, _) = configuredView(flags: 0)
        view.setMarkedText("´",
                           selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        capture.sent.removeAll()

        view.feed(text: "\u{1b}[>9u") // disambiguate + reportAllKeys
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        #expect(capture.sent == Array("\u{1b}[13u".utf8))
    }

    @Test func emptyMarkedTextEndsComposition() {
        let (view, capture, _) = configuredView(flags: 9) // disambiguate + reportAllKeys
        view.setMarkedText("ㅎ",
                           selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("",
                           selectedRange: NSRange(location: 0, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))

        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))

        #expect(capture.sent == Array("\u{1b}[127u".utf8))
    }

    @Test func commandThatEndsCompositionReportsPressAndRelease() {
        // Korean input methods commit on Return and forward the key as a
        // command. The press is reported, so the release must be too.
        let (view, capture, _) = configuredView(flags: 10) // reportEvents + reportAllKeys
        view.setMarkedText("한",
                           selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.keyDown(with: keyEvent(modifiers: [],
                                    characters: "\r",
                                    charactersIgnoringModifiers: "\r",
                                    keyCode: 36))
        // Drive the commit and the forwarded command as the input method
        // does from within interpretKeyEvents.
        view.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        view.keyUp(with: keyEvent(type: .keyUp,
                                  modifiers: [],
                                  characters: "\r",
                                  charactersIgnoringModifiers: "\r",
                                  keyCode: 36))

        #expect(capture.sent == Array("한\u{1b}[13u\u{1b}[13;1:3u".utf8))
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
