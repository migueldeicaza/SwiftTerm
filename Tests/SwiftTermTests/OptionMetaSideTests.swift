//
//  OptionMetaSideTests.swift
//
//  Coverage for `optionAsMetaSide`: with Option as Meta on one Option key
//  only, that key sends the Meta prefix and the other key goes to the keyboard
//  layout, so a Norwegian layout keeps Meta on the left Option key and types
//  "|" with the right Option key and 7.
//
#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Testing
@testable import SwiftTerm

// Drives a TerminalView's input path, which must run on the main thread (F.4).
@MainActor
final class OptionMetaSideTests {

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

    /// The Option key that is down, as the device flags of an event show it.
    private enum Key {
        case left, right, both, unknown

        var flags: NSEvent.ModifierFlags {
            var raw = NSEvent.ModifierFlags.option.rawValue
            switch self {
            case .left: raw |= UInt(NX_DEVICELALTKEYMASK)
            case .right: raw |= UInt(NX_DEVICERALTKEYMASK)
            case .both: raw |= UInt(NX_DEVICELALTKEYMASK) | UInt(NX_DEVICERALTKEYMASK)
            case .unknown: break
            }
            return NSEvent.ModifierFlags(rawValue: raw)
        }
    }

    private func keyEvent(_ key: Key, characters: String, charactersIgnoringModifiers: String,
                          keyCode: Int) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: key.flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: UInt16(keyCode))!
    }

    /// Option+7 on a Norwegian layout: the layout composes "|".
    private func option7(_ key: Key) -> NSEvent {
        keyEvent(key, characters: "|", charactersIgnoringModifiers: "7", keyCode: kVK_ANSI_7)
    }

    private func makeView(side: OptionMetaSide, optionAsMeta: Bool = true,
                          kitty: Bool = false) -> (TerminalView, CapturingDelegate) {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let delegate = CapturingDelegate()
        view.terminalDelegate = delegate
        view.optionAsMetaKey = optionAsMeta
        view.optionAsMetaSide = side
        if kitty {
            // Disambiguate escape codes, the flag every kitty-protocol client pushes.
            view.feed(text: "\u{1b}[>1u")
        }
        return (view, delegate)
    }

    /// Sends the key, then the text that the layout composed for it. A key
    /// that is not Meta goes to `interpretKeyEvents`, which does nothing in a
    /// headless test, so the test commits the text. A key that is Meta sent
    /// its bytes in `keyDown`; the test then adds nothing.
    private func press(_ event: NSEvent, composed: String, on view: TerminalView,
                       _ delegate: CapturingDelegate) -> [UInt8] {
        view.keyDown(with: event)
        if delegate.sent.isEmpty {
            view.insertText(composed, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        return delegate.sent
    }

    private let meta7: [UInt8] = [0x1b, 0x37]
    private let pipe: [UInt8] = Array("|".utf8)

    @Test func testLeftSideMakesTheLeftKeyMeta() {
        let (view, delegate) = makeView(side: .left)
        #expect(press(option7(.left), composed: "|", on: view, delegate) == meta7)
    }

    @Test func testLeftSideGivesTheRightKeyToTheLayout() {
        let (view, delegate) = makeView(side: .left)
        #expect(press(option7(.right), composed: "|", on: view, delegate) == pipe)
    }

    @Test func testRightSideMakesTheRightKeyMeta() {
        let (view, delegate) = makeView(side: .right)
        #expect(press(option7(.right), composed: "|", on: view, delegate) == meta7)
    }

    @Test func testRightSideGivesTheLeftKeyToTheLayout() {
        let (view, delegate) = makeView(side: .right)
        #expect(press(option7(.left), composed: "|", on: view, delegate) == pipe)
    }

    /// The default: each Option key is Meta.
    @Test func testBothSidesMakeEachKeyMeta() {
        for key in [Key.left, .right, .both, .unknown] {
            let (view, delegate) = makeView(side: .both)
            #expect(press(option7(key), composed: "|", on: view, delegate) == meta7)
        }
    }

    /// An event without device flags does not show the side: Option is Meta.
    @Test func testEventWithoutDeviceFlagsIsMeta() {
        for side in [OptionMetaSide.left, .right] {
            let (view, delegate) = makeView(side: side)
            #expect(press(option7(.unknown), composed: "|", on: view, delegate) == meta7)
        }
    }

    /// With the two Option keys down, Meta has priority.
    @Test func testBothKeysDownIsMeta() {
        for side in [OptionMetaSide.left, .right] {
            let (view, delegate) = makeView(side: side)
            #expect(press(option7(.both), composed: "|", on: view, delegate) == meta7)
        }
    }

    /// The side has no effect while Option is not the Meta key.
    @Test func testSideHasNoEffectWhenOptionIsNotMeta() {
        for side in OptionMetaSide.allCases {
            for key in [Key.left, .right] {
                let (view, delegate) = makeView(side: side, optionAsMeta: false)
                #expect(press(option7(key), composed: "|", on: view, delegate) == pipe)
            }
        }
    }

    /// Kitty keyboard protocol: the Meta key reports Alt.
    @Test func testMetaKeyReportsAltWithKittyProtocol() {
        let (view, delegate) = makeView(side: .left, kitty: true)
        let event = keyEvent(.left, characters: "å", charactersIgnoringModifiers: "a", keyCode: kVK_ANSI_A)
        #expect(press(event, composed: "å", on: view, delegate) == Array("\u{1b}[97;3u".utf8))
    }

    /// Kitty keyboard protocol: the other key sends the text of the layout.
    @Test func testLayoutKeySendsComposedTextWithKittyProtocol() {
        let (view, delegate) = makeView(side: .left, kitty: true)
        let event = keyEvent(.right, characters: "å", charactersIgnoringModifiers: "a", keyCode: kVK_ANSI_A)
        #expect(press(event, composed: "å", on: view, delegate) == Array("å".utf8))
    }

    /// The key that is not Meta stays Meta on the keys the layout composes
    /// nothing for, when `optionAsMetaKeyForFunctionalKeys` is on.
    @Test func testLayoutKeyIsMetaOnBackspaceWithFunctionalKeys() {
        let (view, delegate) = makeView(side: .left)
        view.optionAsMetaKeyForFunctionalKeys = true
        let event = keyEvent(.right, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
                             keyCode: kVK_Delete)
        view.keyDown(with: event)
        #expect(delegate.sent == [0x1b, 0x7f])
    }
}
#endif
