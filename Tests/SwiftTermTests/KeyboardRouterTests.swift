#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

/// `TerminalKeyboardRouter` serves `TerminalView` and views whose terminal
/// runs elsewhere. A remote view sends `TerminalKeyEvent.hostKey` to the
/// other side, which calls `Terminal.sendHostKey`.
@MainActor
struct KeyboardRouterTests {
    private final class Capture: TerminalDelegate {
        var sent: [UInt8] = []
        func send(source: Terminal, data: ArraySlice<UInt8>) { sent += data }
    }

    private final class ViewCapture: TerminalViewDelegate {
        var sent: [UInt8] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) { sent += data }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    /// The function keys that the Mac router produces.
    static let routedKeys: [KittyFunctionalKey] = [
        .escape, .enter, .tab, .backspace, .insert, .delete, .up, .down, .left, .right,
        .home, .end, .pageUp, .pageDown,
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12, .f13, .f14, .f15, .f16,
        .f17, .f18, .f19, .f20, .f21, .f22, .f23, .f24, .f25, .f26, .f27, .f28, .f29, .f30,
        .f31, .f32, .f33, .f34, .f35,
        .menu, .capsLock, .scrollLock, .printScreen, .pause,
        .keypad0, .keypad1, .keypad2, .keypad3, .keypad4, .keypad5, .keypad6, .keypad7, .keypad8,
        .keypad9, .keypadDecimal, .keypadDivide, .keypadMultiply, .keypadSubtract, .keypadAdd,
        .keypadEnter, .keypadEqual, .keypadSeparator,
        .keypadLeft, .keypadRight, .keypadUp, .keypadDown, .keypadPageUp, .keypadPageDown,
        .keypadHome, .keypadEnd, .keypadInsert, .keypadDelete, .keypadBegin,
        .leftShift, .rightShift, .leftControl, .rightControl, .leftAlt, .rightAlt,
        .leftSuper, .rightSuper,
    ]

    /// A key sent as host fields encodes to the bytes that the router's
    /// own encoder gives, in every keyboard mode.
    @Test func hostKeyFieldsEncodeLikeTheRouter() throws {
        let flagSets: [KittyKeyboardFlags] = [[], [.disambiguate], [.disambiguate, .reportEvents, .reportAlternates, .reportAllKeys, .reportText]]
        var compared = 0
        for flags in flagSets {
            for applicationCursor in [false, true] {
                let capture = Capture()
                let terminal = Terminal(delegate: capture)
                terminal.feed(text: "\u{1b}[?1\(applicationCursor ? "h" : "l")\u{1b}[>\(flags.rawValue)u")
                for key in Self.routedKeys {
                    for modifiers in [KittyKeyboardModifiers(), [.shift, .ctrl]] {
                        let event = KittyKeyEvent(key: .functional(key), modifiers: modifiers, eventType: .press,
                                                  text: nil, shiftedKey: nil, baseLayoutKey: nil)
                        let encoder = KittyKeyboardEncoder(flags: flags, applicationCursor: applicationCursor,
                                                           applicationKeypad: false, backspaceSendsControlH: false)
                        let expected = encoder.encode(event) ?? []
                        let fields = try #require(Terminal.hostKeyFields(for: key), "\(key) has no host fields")
                        capture.sent = []
                        let routed = TerminalKeyEvent(event: event, backspaceSendsControlH: false)
                        terminal.sendHostKey(key: fields.key, code: fields.code, modifiers: routed.modifiers,
                                             eventType: routed.eventType, text: nil)
                        #expect(capture.sent == expected, "\(key) \(modifiers) flags \(flags.rawValue)")
                        compared += 1
                    }
                }
            }
        }
        #expect(compared == 3 * 2 * Self.routedKeys.count * 2)
    }

    /// Records what the router sends.
    private final class RecordingHost: NSView, TerminalKeyboardHost {
        var keyboardModes = TerminalKeyboardModes()
        var optionAsMetaKey = true
        var backspaceSendsControlH = false
        var shouldSendCommandKeyToTerminal: ((NSEvent) -> Bool)?
        var swapsHorizontalArrowKeys: Bool { false }
        var keys: [(event: TerminalKeyEvent, bytes: [UInt8])] = []
        var bytes: [[UInt8]] = []

        func keyboardRouterKeyDown(_ event: NSEvent) {}
        func keyboardRouter(send event: TerminalKeyEvent, bytes: [UInt8]) { keys.append((event, bytes)) }
        func keyboardRouter(send bytes: [UInt8]) { self.bytes.append(bytes) }
        func keyboardRouter(sendText text: String) { bytes.append(Array(text.utf8)) }
        func keyboardRouterScrollPage(up: Bool) {}
    }

    /// Without the kitty protocol, Control and Option-as-Meta keys send
    /// their legacy bytes with the key, so that a host whose terminal runs
    /// elsewhere can encode the key again if the modes changed.
    @Test func legacyTextKeysComeWithTheKey() throws {
        let host = RecordingHost(frame: .zero)
        let router = TerminalKeyboardRouter(host: host)
        func key(_ characters: String, _ ignoringModifiers: String, _ flags: NSEvent.ModifierFlags,
                 code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                          windowNumber: 0, context: nil, characters: characters,
                                          charactersIgnoringModifiers: ignoringModifiers, isARepeat: false,
                                          keyCode: code))
        }
        router.keyDown(try key("\u{17}", "w", .control, code: 13))
        router.keyDown(try key("\u{0}", " ", .control, code: 49))
        router.keyDown(try key("∑", "w", .option, code: 13))
        #expect(host.bytes.isEmpty)
        #expect(host.keys.map(\.bytes) == [[0x17], [0], [0x1b, 0x77]])
        #expect(host.keys.map(\.event.modifiers) == [4, 4, 2])
        #expect(host.keys.allSatisfy { !$0.event.isText && $0.event.eventType == 1 })
    }

    private func view(feed text: String) -> (TerminalView, ViewCapture) {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        let capture = ViewCapture()
        view.terminalDelegate = capture
        view.feed(text: text)
        return (view, capture)
    }

    private func arrow(left: Bool) throws -> NSEvent {
        let scalar = UnicodeScalar(UInt32(left ? NSLeftArrowFunctionKey : NSRightArrowFunctionKey))!
        let text = String(scalar)
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
                                             timestamp: 0, windowNumber: 0, context: nil, characters: text,
                                             charactersIgnoringModifiers: text, isARepeat: false,
                                             keyCode: left ? 123 : 124))
    }

    /// DECSET 1243 swaps the arrow keys that the user types in a right-to-left
    /// paragraph, not only `sendKeyLeft()`.
    @Test func typedArrowsSwapInRightToLeftParagraphs() throws {
        let (view, capture) = view(feed: "אב")
        view.keyDown(with: try arrow(left: true))
        #expect(capture.sent == EscapeSequences.moveLeftNormal)

        view.withTerminal { $0.bidiArrowKeySwap = true }
        capture.sent = []
        view.keyDown(with: try arrow(left: true))
        #expect(capture.sent == EscapeSequences.moveRightNormal)
        capture.sent = []
        view.keyDown(with: try arrow(left: false))
        #expect(capture.sent == EscapeSequences.moveLeftNormal)

        // Left-to-right text keeps the arrows.
        let (latin, latinCapture) = self.view(feed: "ab")
        latin.withTerminal { $0.bidiArrowKeySwap = true }
        latin.keyDown(with: try arrow(left: true))
        #expect(latinCapture.sent == EscapeSequences.moveLeftNormal)
    }

    /// Records the events that go to the input system.
    private final class RecordingView: TerminalView {
        var interpreted: [NSEvent] = []
        override func interpretKeyEvents(_ eventArray: [NSEvent]) {
            interpreted += eventArray
        }
    }

    /// While an input method composes text, a key goes to it first, also
    /// without the kitty protocol.
    @Test func keysGoToTheInputMethodWhileItComposes() throws {
        let view = RecordingView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        let capture = ViewCapture()
        view.terminalDelegate = capture
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.keyDown(with: try arrow(left: true))
        #expect(view.interpreted.count == 1)
        #expect(capture.sent.isEmpty)

        view.unmarkText()
        view.keyDown(with: try arrow(left: true))
        #expect(view.interpreted.count == 1)
        #expect(capture.sent == EscapeSequences.moveLeftNormal)
    }
}
#endif
