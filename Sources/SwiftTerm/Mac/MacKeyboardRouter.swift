//
//  MacKeyboardRouter.swift
//  SwiftTerm
//
//  Turns AppKit key events into input for a terminal program. `TerminalView`
//  uses it for its own terminal; a view whose terminal runs somewhere else
//  (another process or another machine) uses the same router, so that a key
//  reaches the program as the same bytes in both.
//

#if os(macOS)
import AppKit
import Carbon.HIToolbox

/// The terminal modes that decide how the router sends keys.
public struct TerminalKeyboardModes: Equatable, Sendable {
    /// The kitty keyboard protocol flags that the program enabled.
    public var kittyFlags: KittyKeyboardFlags
    /// DECCKM: cursor keys send application sequences.
    public var applicationCursor: Bool
    /// DECKPAM: the keypad sends application sequences.
    public var applicationKeypad: Bool

    public init (kittyFlags: KittyKeyboardFlags = [], applicationCursor: Bool = false,
                 applicationKeypad: Bool = false) {
        self.kittyFlags = kittyFlags
        self.applicationCursor = applicationCursor
        self.applicationKeypad = applicationKeypad
    }

    /// The modes in a `Terminal.hostInputModes` value.
    public init (hostInputModes: UInt32) {
        kittyFlags = KittyKeyboardFlags(rawValue: Int((hostInputModes >> 8) & 0x1f))
        applicationCursor = hostInputModes & 1 != 0
        applicationKeypad = hostInputModes & 2 != 0
    }
}

/// A key that the router sends to the terminal program.
///
/// A host that owns the terminal sends the bytes that come with the event. A
/// host whose terminal runs somewhere else sends the event too: when the
/// terminal's modes changed before the key arrived, the other side gives its
/// fields to `Terminal.sendHostKey`, or `text` to `Terminal.sendHostText`
/// when `isText` is true. The terminal then encodes the key with its modes
/// at that time.
public struct TerminalKeyEvent {
    let event: KittyKeyEvent
    /// The `backspaceSendsControlH` setting of the host.
    public let backspaceSendsControlH: Bool

    init (event: KittyKeyEvent, backspaceSendsControlH: Bool) {
        self.event = event
        self.backspaceSendsControlH = backspaceSendsControlH
    }

    /// The W3C `key` and `code` values that `Terminal.sendHostKey` reads as
    /// this key. Empty when `isText` is true.
    public var hostKey: (key: String, code: String) {
        switch event.key {
        case .functional(let key):
            return Terminal.hostKeyFields(for: key) ?? ("", "")
        case .unicode(let value):
            return (UnicodeScalar(value).map { String($0) } ?? "", "")
        case .none:
            return ("", "")
        }
    }

    /// True for committed text without a key.
    public var isText: Bool {
        if case .none = event.key { return true }
        return false
    }

    /// Kitty modifier bits: shift 1, alt 2, control 4, super 8, caps lock 64.
    public var modifiers: UInt32 { UInt32(event.modifiers.rawValue) }
    /// 1 press, 2 repeat, 3 release.
    public var eventType: UInt32 { UInt32(event.eventType.rawValue) }
    public var text: String? { event.text }
    /// The key with Shift, or 0.
    public var shiftedKey: UInt32 { event.shiftedKey?.value ?? 0 }
    /// The key at the same position on a US layout, or 0.
    public var baseLayoutKey: UInt32 { event.baseLayoutKey?.value ?? 0 }
    /// True when the input method composes text (a preedit) at this time.
    public var composing: Bool { event.composing }
}

/// A view that sends the keys of a `TerminalKeyboardRouter` to a terminal.
@MainActor
public protocol TerminalKeyboardHost: NSView {
    /// The modes of the terminal that receives the keys.
    var keyboardModes: TerminalKeyboardModes { get }
    /// Option is the Meta key (it sends ESC before the character).
    var optionAsMetaKey: Bool { get set }
    /// While `optionAsMetaKey` is false, Option is still Meta on the keys
    /// that the keyboard layout composes nothing for; see
    /// `TerminalView.optionAsMetaKeyForFunctionalKeys`.
    var optionAsMetaKeyForFunctionalKeys: Bool { get }
    var backspaceSendsControlH: Bool { get }
    /// Return true to give a Command key to a program that enabled the
    /// kitty keyboard protocol, instead of the menu.
    var shouldSendCommandKeyToTerminal: ((NSEvent) -> Bool)? { get }
    /// True when the program asked for swapped arrows (DECSET 1243) and the
    /// cursor's paragraph is drawn right to left: Left then sends Right.
    var swapsHorizontalArrowKeys: Bool { get }

    /// A key went down and the menu did not take it: the host can clear its
    /// selection, hide the pointer, and so on.
    func keyboardRouterKeyDown (_ event: NSEvent)
    /// Sends a key. `bytes` is the key encoded with `keyboardModes` (the
    /// value that the router read last).
    func keyboardRouter (send event: TerminalKeyEvent, bytes: [UInt8])
    /// Sends bytes that do not come from one key, as they are (for example
    /// the legacy sequences of editing commands).
    func keyboardRouter (send bytes: [UInt8])
    /// Sends typed text as it is.
    func keyboardRouter (sendText text: String)
    /// Page Up or Page Down without modifiers: scroll the view, or send the
    /// key on the alternate screen.
    func keyboardRouterScrollPage (up: Bool)
}

extension TerminalKeyboardHost {
    public var optionAsMetaKeyForFunctionalKeys: Bool { false }
}

/// Decides what each key event sends, for a `TerminalKeyboardHost`. Call it
/// from the host's `keyDown`, `keyUp`, `flagsChanged`, `doCommand(by:)`,
/// `performKeyEquivalent`, and the text input methods.
@MainActor
public final class TerminalKeyboardRouter {
    public weak var host: (any TerminalKeyboardHost)?

    public init (host: (any TerminalKeyboardHost)? = nil) {
        self.host = host
    }

    private struct PendingKittyKeyEvent {
        let event: NSEvent
        let eventType: KittyKeyboardEventType
    }

    private var pendingKittyKeyEvent: PendingKittyKeyEvent?
    /// True while the input method composes text (marked text).
    public private(set) var isComposing = false
    /// The key code of the last key that the input method interpreted
    /// during a preedit. Cleared by the next key down or by its key up.
    private var composingKeyCode: UInt16?
    private var keysWithReportedPress: Set<UInt16> = []
    private var keyDownCode: UInt16?

    private static let regularArrowKeyCodes: Set<UInt16> = [
        UInt16(kVK_LeftArrow),
        UInt16(kVK_RightArrow),
        UInt16(kVK_DownArrow),
        UInt16(kVK_UpArrow)
    ]

    private var optionAsMetaKey: Bool { host?.optionAsMetaKey ?? true }

    /// Whether Option acts as Meta for this key: on every key when
    /// `optionAsMetaKey` is on, and on the keys the layout composes nothing
    /// for when `optionAsMetaKeyForFunctionalKeys` is on. Escape, Enter, Tab
    /// and Backspace compose nothing, so they count as functional here, as
    /// they do in iTerm2. While the input method holds marked text, every key
    /// belongs to it.
    private func optionIsMeta(for event: NSEvent) -> Bool {
        if optionAsMetaKey {
            return true
        }
        guard host?.optionAsMetaKeyForFunctionalKeys == true, !isComposing else {
            return false
        }
        return textlessKey(for: event) != nil || kittyFunctionalKey(from: event) != nil
    }

    /// Escape, Enter, Tab and Backspace by their physical key. AppKit keeps
    /// Shift in `charactersIgnoringModifiers`, so Shift+Tab reads as U+0019
    /// there; the key code says Tab whatever the modifiers.
    private func textlessKey(for event: NSEvent) -> KittyFunctionalKey? {
        switch Int(event.keyCode) {
        case kVK_Escape: return .escape
        case kVK_Return: return .enter
        case kVK_Tab: return .tab
        case kVK_Delete: return .backspace
        default: return nil
        }
    }

    /// Sends Option plus Escape, Enter, Tab or Backspace through the encoder,
    /// which applies the Meta prefix (or the kitty Alt modifier), Shift on Tab
    /// and the `backspaceSendsControlH` byte the same way it does for the key
    /// without Option.
    private func sendMetaTextlessKey(_ event: NSEvent, eventType: KittyKeyboardEventType) -> Bool {
        guard let key = textlessKey(for: event) else { return false }
        return sendKittyFunctionalKey(key,
                                      modifiers: kittyModifiers(from: event, includeOption: true),
                                      eventType: eventType)
    }

    // MARK: Text input state

    /// Call when the marked text changes; an empty marked text ends the preedit.
    public func markedTextChanged (composing: Bool) {
        pendingKittyKeyEvent = nil
        isComposing = composing
    }

    /// Call when the host pastes text: the paste is not a key.
    public func textWillBePasted () {
        pendingKittyKeyEvent = nil
        isComposing = false
    }

    /// Call when the view loses focus: releases can be lost then.
    public func focusLost () {
        keysWithReportedPress.removeAll()
    }

    // MARK: Events

    /// Returns true when it sent the key equivalent to the program. Call the
    /// superclass otherwise.
    public func performKeyEquivalent (_ event: NSEvent) -> Bool {
        // AppKit offers key equivalents to every view in the window, so only
        // the focused terminal can take the key for its program.
        guard let host, event.type == .keyDown,
              let window = host.window, window.isKeyWindow, window.firstResponder === host,
              event.modifierFlags.contains(.command),
              !host.keyboardModes.kittyFlags.isEmpty,
              host.shouldSendCommandKeyToTerminal?(event) == true else {
            return false
        }
        keyDown(event)
        return true
    }

    public func keyDown (_ event: NSEvent) {
        guard let host else { return }
        composingKeyCode = nil
        if !event.isARepeat {
            keysWithReportedPress.remove(event.keyCode)
        }
        let modes = host.keyboardModes
        let keyboardEnhancementFlags = modes.kittyFlags
        let terminalOwnsCommandKey = !keyboardEnhancementFlags.isEmpty
            && event.modifierFlags.contains(.command)
            && host.shouldSendCommandKeyToTerminal?(event) == true
        // The host menu owns its shortcuts. If AppKit reaches keyDown before
        // running a menu action, give the menu a chance before clearing the
        // selection or encoding the key for the terminal application.
        if event.modifierFlags.contains(.command),
           !terminalOwnsCommandKey,
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return
        }
        let previousKeyDownCode = keyDownCode
        keyDownCode = event.keyCode
        defer { keyDownCode = previousKeyDownCode }
        host.keyboardRouterKeyDown(event)
        let eventFlags = event.modifierFlags

        let applicationCursor = modes.applicationCursor

        let isOptionAsMetaShortcut = eventFlags.contains([.option, .command])
            && event.charactersIgnoringModifiers == "o"
        if !keyboardEnhancementFlags.isEmpty,
           eventFlags.contains(.command),
           (!isOptionAsMetaShortcut || terminalOwnsCommandKey),
           let kittyEvent = kittyKeyEvent(from: event,
                                          eventType: event.isARepeat ? .repeatPress : .press),
           sendKittyEvent(kittyEvent) {
            return
        }

        if keyboardEnhancementFlags.isEmpty,
           eventFlags.contains(.command),
           !(eventFlags.contains(.option) && event.charactersIgnoringModifiers == "o") {
            // The menu has had its turn. Command-arrow sends no terminal input.
            if Self.regularArrowKeyCodes.contains(event.keyCode) {
                return
            }
            host.interpretKeyEvents([event])
            return
        }

        // A key event during preedit belongs to the input method, in every
        // mode. AppKit can commit text or issue a command while it interprets
        // this event. Do not send the physical key as a second event.
        if isComposing && !eventFlags.contains(.command) {
            pendingKittyKeyEvent = nil
            composingKeyCode = event.keyCode
            host.interpretKeyEvents([event])
            return
        }

        // Apply the macOS Option-arrow bindings before the legacy encoder.
        // These bindings do not depend on the Option-as-Meta text setting.
        // An application that enables the Kitty protocol gets the full key.
        if keyboardEnhancementFlags.isEmpty,
           eventFlags.intersection([.shift, .control, .option, .command]) == .option {
            switch event.keyCode {
            case UInt16(kVK_LeftArrow):
                host.keyboardRouter(send: EscapeSequences.emacsBack)
                return
            case UInt16(kVK_RightArrow):
                host.keyboardRouter(send: EscapeSequences.emacsForward)
                return
            case UInt16(kVK_UpArrow):
                sendCursorKey(.up)
                return
            case UInt16(kVK_DownArrow):
                sendCursorKey(.down)
                return
            default:
                break
            }
        }

        if keyboardEnhancementFlags.isEmpty,
           !eventFlags.contains(.command),
           (!eventFlags.contains(.option) || optionIsMeta(for: event)),
           let functionKey = functionalKey(from: event) {
            let modifiers = kittyModifiers(from: event, includeOption: optionIsMeta(for: event))
            let isUnmodifiedPageKey = (functionKey == .pageUp || functionKey == .pageDown)
                && modifiers.intersection([.shift, .alt, .ctrl]).isEmpty
                && !applicationCursor
            if isUnmodifiedPageKey {
                host.keyboardRouterScrollPage(up: functionKey == .pageUp)
                return
            }
            let keyEvent = KittyKeyEvent(key: .functional(functionKey),
                                         modifiers: modifiers,
                                         eventType: event.isARepeat ? .repeatPress : .press,
                                         text: kittyTextForFunctionalKey(functionKey, event: event),
                                         shiftedKey: nil,
                                         baseLayoutKey: nil,
                                         composing: isComposing)
            if sendKittyEvent(keyEvent) {
                return
            }
        }

        if !keyboardEnhancementFlags.isEmpty {
            pendingKittyKeyEvent = nil
            if eventFlags.contains([.option, .command]), event.charactersIgnoringModifiers == "o" {
                host.optionAsMetaKey.toggle()
                // No press was reported for this key, so its release must
                // not be reported either.
                return
            }

            let wantsEvents = keyboardEnhancementFlags.contains(.reportEvents)
            let wantsAllKeys = keyboardEnhancementFlags.contains(.reportAllKeys)
            let repeatEventType: KittyKeyboardEventType = (event.isARepeat && wantsEvents) ? .repeatPress : .press
            let textEventType: KittyKeyboardEventType = (event.isARepeat && wantsEvents && wantsAllKeys) ? .repeatPress : .press

            if let functionKey = functionalKey(from: event) {
                let kittyEvent = KittyKeyEvent(key: .functional(functionKey),
                                               modifiers: kittyModifiers(from: event, includeOption: optionIsMeta(for: event)),
                                               eventType: repeatEventType,
                                               text: kittyTextForFunctionalKey(functionKey, event: event),
                                               shiftedKey: nil,
                                               baseLayoutKey: nil,
                                               composing: isComposing)
                if sendKittyEvent(kittyEvent) {
                    return
                }
            }

            if optionIsMeta(for: event) && eventFlags.contains(.option),
               sendMetaTextlessKey(event, eventType: repeatEventType) {
                return
            }

            if eventFlags.contains(.control) || (optionIsMeta(for: event) && eventFlags.contains(.option)) {
                if let kittyEvent = kittyTextEvent(from: event, eventType: repeatEventType),
                   sendKittyEvent(kittyEvent) {
                    return
                }
            }

            pendingKittyKeyEvent = PendingKittyKeyEvent(event: event, eventType: textEventType)
            host.interpretKeyEvents([event])
            return
        }

        // Handle Option-letter to send the ESC sequence plus the letter as expected by terminals
        if eventFlags.contains ([.option, .command]) {
            if event.charactersIgnoringModifiers == "o" {
                host.optionAsMetaKey.toggle()
            }
        } else if optionIsMeta(for: event) && eventFlags.contains (.option) {
            if sendMetaTextlessKey(event, eventType: event.isARepeat ? .repeatPress : .press) {
                return
            }
            if let rawCharacter = event.charactersIgnoringModifiers {
                if let fs = rawCharacter.unicodeScalars.first {
                    switch Int (fs.value) {
                    case NSLeftArrowFunctionKey:
                        host.keyboardRouter(send: EscapeSequences.emacsBack)
                        return
                    case NSRightArrowFunctionKey:
                        host.keyboardRouter(send: EscapeSequences.emacsForward)
                        return
                    default: break
                    }
                }
                sendLegacyKey(event, bytes: EscapeSequences.cmdEsc + Array(rawCharacter.utf8))
            }
            return
        } else if eventFlags.contains (.control) {
            // Sends the control sequence
            // AppKit can report Control-Space with no character, or with NUL,
            // instead of the unmodified space. Use the physical Space key so
            // that the terminal always sends the NUL byte expected for C-SPC.
            if event.keyCode == UInt16(kVK_Space) {
                sendLegacyKey(event, bytes: [0])
                return
            }
            if let ch = event.charactersIgnoringModifiers {
                if let fs = ch.unicodeScalars.first {
                    switch Int (fs.value) {
                    case NSLeftArrowFunctionKey:
                        host.keyboardRouter(send: EscapeSequences.controlLeft)
                        return
                    case NSRightArrowFunctionKey:
                        host.keyboardRouter(send: EscapeSequences.controlRight)
                        return
                    default:
                        break
                    }
                }
                var controlBytes = TerminalView.controlBytes(forEventCharacters: ch)

                // AppKit supplies the final C0 value for many layouts and
                // input methods. On Latin ISO layouts its table is letter
                // based rather than positional, so honor it before the
                // PC-101 position guess below.
                if controlBytes.isEmpty,
                   let characters = event.characters,
                   let scalar = singleControlScalar(in: characters) {
                    if scalar.value == 0x7f {
                        // Control-Backspace follows the same setting as Backspace.
                        controlBytes = [host.backspaceSendsControlH ? 8 : 0x7f]
                    } else {
                        controlBytes = [UInt8(scalar.value)]
                    }
                }

                // Non-Latin layouts can map an ASCII key to a Unicode
                // character with no Control translation. In that case, use
                // the key's standard PC-101 position for the legacy Control
                // mapping. Keep the layout character for ASCII layouts such
                // as Dvorak.
                if controlBytes.isEmpty,
                   ch.unicodeScalars.count == 1,
                   let scalar = ch.unicodeScalars.first,
                   scalar.value > 0x7f,
                   let baseLayoutKey = kittyBaseLayoutKey(from: event) {
                    controlBytes = TerminalView.controlBytes(forEventCharacters: String(baseLayoutKey))
                }

                if !controlBytes.isEmpty {
                    sendLegacyKey(event, bytes: controlBytes)
                }
                return
            }
        } else if eventFlags.contains (.function) {
            if let str = event.charactersIgnoringModifiers {
                if let fs = str.unicodeScalars.first {
                    let c = Int (fs.value)
                    switch c {
                    case NSF1FunctionKey:
                        host.keyboardRouter(send: EscapeSequences.cmdF [0])
                    case NSF2FunctionKey:
                        host.keyboardRouter(send: EscapeSequences.cmdF [1])
                    case NSF3FunctionKey:
                        host.keyboardRouter(send: EscapeSequences.cmdF [2])
                    case NSF4FunctionKey:
                        host.keyboardRouter(send: EscapeSequences.cmdF [3])
                    case NSF5FunctionKey:
                        host.keyboardRouter(send: EscapeSequences.cmdF [4])
                    case NSF6FunctionKey:
                        host.keyboardRouter(send: EscapeSequences.cmdF [5])
                    case NSF7FunctionKey:
                        host.keyboardRouter(send: EscapeSequences.cmdF [6])
                    case NSF8FunctionKey:
                        host.keyboardRouter(send: EscapeSequences.cmdF [7])
                    case NSF9FunctionKey:
                        host.keyboardRouter(send: EscapeSequences.cmdF [8])
                    case NSF10FunctionKey:
                        host.keyboardRouter(send: EscapeSequences.cmdF [9])
                    case NSF11FunctionKey:
                        host.keyboardRouter(send: EscapeSequences.cmdF [10])
                    case NSF12FunctionKey:
                        host.keyboardRouter(send: EscapeSequences.cmdF [11])
                    case NSDeleteFunctionKey:
                        host.keyboardRouter(send: EscapeSequences.cmdDelKey)
                        //                    case NSUpArrowFunctionKey:
                        //                        host.keyboardRouter(send: EscapeSequences.MoveUpNormal)
                        //                    case NSDownArrowFunctionKey:
                        //                        host.keyboardRouter(send: EscapeSequences.MoveDownNormal)
                        //                    case NSLeftArrowFunctionKey:
                        //                        host.keyboardRouter(send: EscapeSequences.MoveLeftNormal)
                        //                    case NSRightArrowFunctionKey:
                    //                        host.keyboardRouter(send: EscapeSequences.MoveRightNormal)
                    case NSPageUpFunctionKey:
                        host.keyboardRouterScrollPage(up: true)
                    case NSPageDownFunctionKey:
                        host.keyboardRouterScrollPage(up: false)
                    default:
                        host.interpretKeyEvents([event])
                    }
                }
            }
            return
        }
        
        host.interpretKeyEvents([event])
    }

    /// Reports the release of a key whose press the program got. Call the
    /// superclass after it.
    public func keyUp (_ event: NSEvent) {
        if composingKeyCode == event.keyCode {
            composingKeyCode = nil
        }
        let hadReportedPress = keysWithReportedPress.remove(event.keyCode) != nil
        guard hadReportedPress, let host else { return }
        let flags = host.keyboardModes.kittyFlags
        // Every key whose press reached the application gets a release,
        // including plain text keys.
        if flags.contains(.reportEvents),
           let kittyEvent = kittyKeyEvent(from: event, eventType: .release, text: nil) {
            if !flags.contains(.reportAllKeys),
               case .unicode(let codepoint) = kittyEvent.key,
               codepoint == 9 || codepoint == 13 || codepoint == 127 {
                // Enter/Tab/Backspace only report release events in report-all-keys mode.
            } else {
                _ = sendKittyEvent(kittyEvent)
            }
        }
    }

    /// Reports modifier keys to programs that asked for all keys. Call the
    /// superclass after it.
    public func flagsChanged (_ event: NSEvent) {
        guard let host else { return }
        let keyboardEnhancementFlags = host.keyboardModes.kittyFlags
        if keyboardEnhancementFlags.contains(.reportAllKeys),
           !isComposing,
           let modifierKey = kittyModifierKey(from: event.keyCode),
           let isDown = kittyModifierIsPressed(modifierKey, in: event) {
            let eventType: KittyKeyboardEventType = isDown ? .press : .release
            if eventType == .release && !keyboardEnhancementFlags.contains(.reportEvents) {
                return
            }
            let modifiers = kittyModifiers(from: event, includeOption: true)
            let kittyEvent = KittyKeyEvent(key: .functional(modifierKey),
                                           modifiers: modifiers,
                                           eventType: eventType,
                                           text: nil,
                                           shiftedKey: nil,
                                           baseLayoutKey: nil,
                                           composing: isComposing)
            _ = sendKittyEvent(kittyEvent)
        }
    }

    public func doCommand (_ selector: Selector) {
        guard let host else { return }
        let keyboardEnhancementFlags = host.keyboardModes.kittyFlags
        if !keyboardEnhancementFlags.isEmpty && isComposing {
            pendingKittyKeyEvent = nil
            return
        }
        if !isComposing {
            let mods: KittyKeyboardModifiers
            if let pending = pendingKittyKeyEvent {
                mods = kittyModifiers(from: pending.event, includeOption: optionIsMeta(for: pending.event))
            } else {
                mods = []
            }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if sendKittyFunctionalKey(.enter, modifiers: mods) { return }
            case #selector(NSResponder.cancelOperation(_:)):
                if sendKittyFunctionalKey(.escape, modifiers: mods) { return }
            case #selector(NSResponder.deleteBackward(_:)):
                if sendKittyFunctionalKey(.backspace, modifiers: mods) { return }
            case #selector(NSResponder.moveUp(_:)):
                if sendKittyFunctionalKey(.up, modifiers: mods) { return }
            case #selector(NSResponder.moveDown(_:)):
                if sendKittyFunctionalKey(.down, modifiers: mods) { return }
            case #selector(NSResponder.moveLeft(_:)):
                if sendKittyFunctionalKey(.left, modifiers: mods) { return }
            case #selector(NSResponder.moveRight(_:)):
                if sendKittyFunctionalKey(.right, modifiers: mods) { return }
            case #selector(NSResponder.insertTab(_:)):
                if sendKittyFunctionalKey(.tab, modifiers: mods) { return }
            case #selector(NSResponder.insertBacktab(_:)):
                if sendKittyFunctionalKey(.tab, modifiers: mods.union([.shift])) { return }
            case #selector(NSResponder.moveToBeginningOfLine(_:)):
                if sendKittyFunctionalKey(.home, modifiers: mods) { return }
            case #selector(NSResponder.scrollToBeginningOfDocument(_:)):
                if sendKittyFunctionalKey(.home, modifiers: mods) { return }
            case #selector(NSResponder.moveToEndOfLine(_:)):
                if sendKittyFunctionalKey(.end, modifiers: mods) { return }
            case #selector(NSResponder.scrollToEndOfDocument(_:)):
                if sendKittyFunctionalKey(.end, modifiers: mods) { return }
            case #selector(NSResponder.scrollPageUp(_:)):
                fallthrough
            case #selector(NSResponder.pageUp(_:)):
                if host.keyboardModes.applicationCursor {
                    if sendKittyFunctionalKey(.pageUp, modifiers: mods) { return }
                } else {
                    host.keyboardRouterScrollPage(up: true)
                    return
                }
            case #selector(NSResponder.scrollPageDown(_:)):
                fallthrough
            case #selector(NSResponder.pageDown(_:)):
                if host.keyboardModes.applicationCursor {
                    if sendKittyFunctionalKey(.pageDown, modifiers: mods) { return }
                } else {
                    host.keyboardRouterScrollPage(up: false)
                    return
                }
            default:
                break
            }
        }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            host.keyboardRouter(send: EscapeSequences.cmdRet)
        case #selector(NSResponder.cancelOperation(_:)):
            host.keyboardRouter(send: EscapeSequences.cmdEsc)
        case #selector(NSResponder.deleteBackward(_:)):
            host.keyboardRouter(send: [host.backspaceSendsControlH ? 8 : 0x7f])
        case #selector(NSResponder.moveUp(_:)):
            sendCursorKey(.up)
        case #selector(NSResponder.moveDown(_:)):
            sendCursorKey(.down)
        case #selector(NSResponder.moveLeft(_:)):
            sendCursorKey(.left)
        case #selector(NSResponder.moveRight(_:)):
            sendCursorKey(.right)
        case #selector(NSResponder.insertTab(_:)):
            host.keyboardRouter(send: EscapeSequences.cmdTab)
        case #selector(NSResponder.insertBacktab(_:)):
            host.keyboardRouter(send: EscapeSequences.cmdBackTab)
        case #selector(NSResponder.moveToBeginningOfLine(_:)):
            host.keyboardRouter(send: host.keyboardModes.applicationCursor ? EscapeSequences.moveHomeApp : EscapeSequences.moveHomeNormal)
        case #selector(NSResponder.scrollToBeginningOfDocument(_:)):
            host.keyboardRouter(send: host.keyboardModes.applicationCursor ? EscapeSequences.moveHomeApp : EscapeSequences.moveHomeNormal)
        case #selector(NSResponder.moveToEndOfLine(_:)):
            host.keyboardRouter(send: host.keyboardModes.applicationCursor ? EscapeSequences.moveEndApp : EscapeSequences.moveEndNormal)
        case #selector(NSResponder.scrollToEndOfDocument(_:)):
            host.keyboardRouter(send: host.keyboardModes.applicationCursor ? EscapeSequences.moveEndApp : EscapeSequences.moveEndNormal)
        case #selector(NSResponder.scrollPageUp(_:)):
            fallthrough
        case #selector(NSResponder.pageUp(_:)):
            if host.keyboardModes.applicationCursor {
                host.keyboardRouter(send: EscapeSequences.cmdPageUp)
            } else {
                host.keyboardRouterScrollPage(up: true)
            }
        case #selector(NSResponder.scrollPageDown(_:)):
            fallthrough
        case #selector(NSResponder.pageDown(_:)):
            if host.keyboardModes.applicationCursor {
                host.keyboardRouter(send: EscapeSequences.cmdPageDown)
            } else {
                host.keyboardRouterScrollPage(up: false)
            }
        case #selector(NSResponder.pageDownAndModifySelection(_:)):
            if host.keyboardModes.applicationCursor {
                // TODO: view should scroll one page up.
            } else {
                host.keyboardRouter(send: EscapeSequences.cmdPageDown)
            }
        case #selector(NSResponder.moveToLeftEndOfLine(_:)):
            // Apple sends the Emacs back-word commands
            host.keyboardRouter(send: EscapeSequences.emacsBack)
        case #selector(NSResponder.moveToRightEndOfLine(_:)):
            host.keyboardRouter(send: EscapeSequences.emacsForward)
        default:
            // Nothing is sent for this key. Under the kitty protocol its
            // release must not be reported without a press.
            pendingKittyKeyEvent = nil
            print ("Unhandle selector \(selector)")
        }
    }

    /// Sends text that the input system committed (not a paste).
    public func insertText (_ text: String) {
        guard let host else { return }
        // A commit ends the preedit in every mode. AppKit does not call
        // unmarkText after a commit, so clear the state here.
        let wasComposing = isComposing
        isComposing = false
        let keyboardEnhancementFlags = host.keyboardModes.kittyFlags
        guard !keyboardEnhancementFlags.isEmpty else {
            host.keyboardRouter(sendText: text)
            return
        }
        let pendingEvent = pendingKittyKeyEvent
        pendingKittyKeyEvent = nil

        // Backspace or Delete that ends a preedit is an IME edit
        // command. It is not committed text for the terminal. Other
        // control input, such as Ctrl+C, is a real key press.
        if wasComposing && isPreeditEditCharacter(text) {
            return
        }

        // Option acting as a compose/AltGr layer (e.g. on the Czech
        // layout Option+2 produces "@" while the bare key is "ě"). When
        // optionAsMetaKey is off, Option is not Meta, so the keypress
        // simply produced a normal character. Encoding it as a kitty
        // CSI-u event keys off charactersIgnoringModifiers (the
        // base-layout glyph, "ě") and only carries the composed "@" as
        // associated text, so apps that negotiate reportAlternates or
        // reportAllKeys without reportText (e.g. OpenCode) receive the
        // base key and the composed glyph is lost. Send the composed
        // text directly instead, matching how kitty/Ghostty handle
        // AltGr layers.
        if let pendingEvent,
           !optionIsMeta(for: pendingEvent.event),
           pendingEvent.event.modifierFlags.contains(.option),
           !pendingEvent.event.modifierFlags.contains(.control),
           !pendingEvent.event.modifierFlags.contains(.command),
           isPlainPrintableText(text) {
            host.keyboardRouter(sendText: text)
            return
        }

        let kittyEvent: KittyKeyEvent
        if text.unicodeScalars.count == 1,
           let pendingEvent,
           let event = kittyTextEvent(from: pendingEvent.event, eventType: pendingEvent.eventType, text: text) {
            kittyEvent = event
        } else {
            kittyEvent = kittyTextEventFromText(text)
        }
        let wasSent = sendKittyEvent(kittyEvent)
        if wasSent,
           keyboardEnhancementFlags.contains(.reportEvents),
           let pendingEvent {
            if case .none = kittyEvent.key {
                // Committed text has no physical key to release.
            } else {
                keysWithReportedPress.insert(pendingEvent.event.keyCode)
            }
        }
    }

    // MARK: Sending

    /// Sends the legacy bytes of a text key (Control or Option as Meta),
    /// with the key. A host whose terminal runs somewhere else can then
    /// encode the key again when the program enabled the kitty protocol
    /// before the key arrived.
    private func sendLegacyKey (_ event: NSEvent, bytes: [UInt8]) {
        guard let host else { return }
        guard let kittyEvent = kittyTextEvent(from: event, eventType: event.isARepeat ? .repeatPress : .press) else {
            host.keyboardRouter(send: bytes)
            return
        }
        host.keyboardRouter(send: TerminalKeyEvent(event: kittyEvent, backspaceSendsControlH: host.backspaceSendsControlH),
                            bytes: bytes)
    }

    @discardableResult
    private func sendKittyEvent (_ event: KittyKeyEvent) -> Bool {
        guard let host else { return false }
        let modes = host.keyboardModes
        let encoder = KittyKeyboardEncoder(flags: modes.kittyFlags,
                                           applicationCursor: modes.applicationCursor,
                                           applicationKeypad: modes.applicationKeypad,
                                           backspaceSendsControlH: host.backspaceSendsControlH)
        guard let bytes = encoder.encode(event) else { return false }
        host.keyboardRouter(send: TerminalKeyEvent(event: event, backspaceSendsControlH: host.backspaceSendsControlH),
                            bytes: bytes)
        if encoder.flags.contains(.reportEvents),
           event.eventType != .release,
           let keyCode = keyDownCode {
            switch event.key {
            case .none:
                break
            default:
                keysWithReportedPress.insert(keyCode)
            }
        }
        return true
    }

    @discardableResult
    private func sendKittyFunctionalKey (_ key: KittyFunctionalKey, modifiers: KittyKeyboardModifiers = [],
                                         eventType: KittyKeyboardEventType = .press) -> Bool {
        guard let host else { return false }
        let event = KittyKeyEvent(key: .functional(horizontal(key)),
                                  modifiers: modifiers,
                                  eventType: eventType,
                                  text: nil,
                                  shiftedKey: nil,
                                  baseLayoutKey: nil,
                                  composing: isComposing)
        guard sendKittyEvent(event) else { return false }
        let reportsEvents = host.keyboardModes.kittyFlags.contains(.reportEvents)
        if eventType != .release, reportsEvents, let pending = pendingKittyKeyEvent {
            keysWithReportedPress.insert(pending.event.keyCode)
        }
        // The input method forwarded the key that ended the preedit as a
        // command. Its press is now reported, so its release must be too.
        if let composingKeyCode, reportsEvents {
            keysWithReportedPress.insert(composingKeyCode)
        }
        return true
    }

    private enum CursorKey {
        case up, down, left, right
    }

    /// Sends a cursor key with the active cursor-key mode.
    private func sendCursorKey (_ key: CursorKey) {
        guard let host else { return }
        let application = host.keyboardModes.applicationCursor
        let swap = host.swapsHorizontalArrowKeys
        switch key {
        case .up:
            host.keyboardRouter(send: application ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
        case .down:
            host.keyboardRouter(send: application ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
        case .left, .right:
            let left = (key == .left) != swap
            host.keyboardRouter(send: left
                ? (application ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal)
                : (application ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal))
        }
    }

    /// Left and Right trade places when the host swaps them (DECSET 1243).
    private func horizontal (_ key: KittyFunctionalKey) -> KittyFunctionalKey {
        guard key == .left || key == .right, host?.swapsHorizontalArrowKeys == true else { return key }
        return key == .left ? .right : .left
    }

    /// The functional key of an event, with Left and Right swapped when the
    /// host asks for it.
    private func functionalKey (from event: NSEvent) -> KittyFunctionalKey? {
        kittyFunctionalKey(from: event).map(horizontal)
    }

    // MARK: Event translation

    private func kittyModifiers(from event: NSEvent, includeOption: Bool) -> KittyKeyboardModifiers {
        var modifiers: KittyKeyboardModifiers = []
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.ctrl) }
        if includeOption, event.modifierFlags.contains(.option) { modifiers.insert(.alt) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.super) }
        if event.modifierFlags.contains(.capsLock) { modifiers.insert(.capsLock) }
        return modifiers
    }

    private func kittyFunctionalKey(from event: NSEvent) -> KittyFunctionalKey? {
        switch Int(event.keyCode) {
        case kVK_ANSI_Keypad0:
            return .keypad0
        case kVK_ANSI_Keypad1:
            return .keypad1
        case kVK_ANSI_Keypad2:
            return .keypad2
        case kVK_ANSI_Keypad3:
            return .keypad3
        case kVK_ANSI_Keypad4:
            return .keypad4
        case kVK_ANSI_Keypad5:
            return .keypad5
        case kVK_ANSI_Keypad6:
            return .keypad6
        case kVK_ANSI_Keypad7:
            return .keypad7
        case kVK_ANSI_Keypad8:
            return .keypad8
        case kVK_ANSI_Keypad9:
            return .keypad9
        case kVK_ANSI_KeypadDecimal:
            return .keypadDecimal
        case kVK_ANSI_KeypadDivide:
            return .keypadDivide
        case kVK_ANSI_KeypadMultiply:
            return .keypadMultiply
        case kVK_ANSI_KeypadMinus:
            return .keypadSubtract
        case kVK_ANSI_KeypadPlus:
            return .keypadAdd
        case kVK_ANSI_KeypadEnter:
            return .keypadEnter
        case kVK_ANSI_KeypadEquals:
            return .keypadEqual
        case kVK_ANSI_KeypadClear:
            return .keypadBegin
        default:
            break
        }
        guard let chars = event.charactersIgnoringModifiers,
              let scalar = chars.unicodeScalars.first else {
            return nil
        }
        if event.modifierFlags.contains(.numericPad),
           !Self.regularArrowKeyCodes.contains(event.keyCode) {
            switch Int(scalar.value) {
            case NSUpArrowFunctionKey:
                return .keypadUp
            case NSDownArrowFunctionKey:
                return .keypadDown
            case NSLeftArrowFunctionKey:
                return .keypadLeft
            case NSRightArrowFunctionKey:
                return .keypadRight
            case NSHomeFunctionKey:
                return .keypadHome
            case NSEndFunctionKey:
                return .keypadEnd
            case NSPageUpFunctionKey:
                return .keypadPageUp
            case NSPageDownFunctionKey:
                return .keypadPageDown
            case NSInsertFunctionKey:
                return .keypadInsert
            case NSDeleteFunctionKey:
                return .keypadDelete
            default:
                break
            }
        }
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey:
            return .up
        case NSDownArrowFunctionKey:
            return .down
        case NSLeftArrowFunctionKey:
            return .left
        case NSRightArrowFunctionKey:
            return .right
        case NSHomeFunctionKey:
            return .home
        case NSEndFunctionKey:
            return .end
        case NSPageUpFunctionKey:
            return .pageUp
        case NSPageDownFunctionKey:
            return .pageDown
        case NSInsertFunctionKey:
            return .insert
        case NSDeleteFunctionKey:
            return .delete
        case NSPrintScreenFunctionKey:
            return .printScreen
        case NSScrollLockFunctionKey:
            return .scrollLock
        case NSPauseFunctionKey:
            return .pause
        case NSMenuFunctionKey:
            return .menu
        case NSF1FunctionKey:
            return .f1
        case NSF2FunctionKey:
            return .f2
        case NSF3FunctionKey:
            return .f3
        case NSF4FunctionKey:
            return .f4
        case NSF5FunctionKey:
            return .f5
        case NSF6FunctionKey:
            return .f6
        case NSF7FunctionKey:
            return .f7
        case NSF8FunctionKey:
            return .f8
        case NSF9FunctionKey:
            return .f9
        case NSF10FunctionKey:
            return .f10
        case NSF11FunctionKey:
            return .f11
        case NSF12FunctionKey:
            return .f12
        case NSF13FunctionKey:
            return .f13
        case NSF14FunctionKey:
            return .f14
        case NSF15FunctionKey:
            return .f15
        case NSF16FunctionKey:
            return .f16
        case NSF17FunctionKey:
            return .f17
        case NSF18FunctionKey:
            return .f18
        case NSF19FunctionKey:
            return .f19
        case NSF20FunctionKey:
            return .f20
        case NSF21FunctionKey:
            return .f21
        case NSF22FunctionKey:
            return .f22
        case NSF23FunctionKey:
            return .f23
        case NSF24FunctionKey:
            return .f24
        case NSF25FunctionKey:
            return .f25
        case NSF26FunctionKey:
            return .f26
        case NSF27FunctionKey:
            return .f27
        case NSF28FunctionKey:
            return .f28
        case NSF29FunctionKey:
            return .f29
        case NSF30FunctionKey:
            return .f30
        case NSF31FunctionKey:
            return .f31
        case NSF32FunctionKey:
            return .f32
        case NSF33FunctionKey:
            return .f33
        case NSF34FunctionKey:
            return .f34
        case NSF35FunctionKey:
            return .f35
        default:
            return nil
        }
    }

    private func kittyTextForFunctionalKey(_ key: KittyFunctionalKey, event: NSEvent) -> String? {
        switch key {
        case .keypad0, .keypad1, .keypad2, .keypad3, .keypad4,
             .keypad5, .keypad6, .keypad7, .keypad8, .keypad9,
             .keypadDecimal, .keypadDivide, .keypadMultiply, .keypadSubtract,
             .keypadAdd, .keypadEqual, .keypadSeparator:
            let text = event.characters ?? event.charactersIgnoringModifiers
            return text?.isEmpty == false ? text : nil
        default:
            return nil
        }
    }

    private func kittyModifierKey(from keyCode: UInt16) -> KittyFunctionalKey? {
        switch keyCode {
        case 54:
            return .rightSuper
        case 55:
            return .leftSuper
        case 56:
            return .leftShift
        case 57:
            return .capsLock
        case 58:
            return .leftAlt
        case 59:
            return .leftControl
        case 60:
            return .rightShift
        case 61:
            return .rightAlt
        case 62:
            return .rightControl
        default:
            return nil
        }
    }

    private func modifierFlag(for key: KittyFunctionalKey) -> NSEvent.ModifierFlags? {
        switch key {
        case .leftShift, .rightShift:
            return .shift
        case .leftControl, .rightControl:
            return .control
        case .leftAlt, .rightAlt:
            return .option
        case .leftSuper, .rightSuper:
            return .command
        case .capsLock:
            return .capsLock
        default:
            return nil
        }
    }

    /// Returns the state of the specific modifier key that produced the event.
    /// The standard AppKit flags combine the left and right keys. The device
    /// flags keep the side information when both keys are down.
    private func kittyModifierIsPressed(_ key: KittyFunctionalKey, in event: NSEvent) -> Bool? {
        let keyMask: UInt
        let familyMask: UInt
        switch key {
        case .leftShift:
            keyMask = UInt(NX_DEVICELSHIFTKEYMASK)
            familyMask = keyMask | UInt(NX_DEVICERSHIFTKEYMASK)
        case .rightShift:
            keyMask = UInt(NX_DEVICERSHIFTKEYMASK)
            familyMask = UInt(NX_DEVICELSHIFTKEYMASK) | keyMask
        case .leftControl:
            keyMask = UInt(NX_DEVICELCTLKEYMASK)
            familyMask = keyMask | UInt(NX_DEVICERCTLKEYMASK)
        case .rightControl:
            keyMask = UInt(NX_DEVICERCTLKEYMASK)
            familyMask = UInt(NX_DEVICELCTLKEYMASK) | keyMask
        case .leftAlt:
            keyMask = UInt(NX_DEVICELALTKEYMASK)
            familyMask = keyMask | UInt(NX_DEVICERALTKEYMASK)
        case .rightAlt:
            keyMask = UInt(NX_DEVICERALTKEYMASK)
            familyMask = UInt(NX_DEVICELALTKEYMASK) | keyMask
        case .leftSuper:
            keyMask = UInt(NX_DEVICELCMDKEYMASK)
            familyMask = keyMask | UInt(NX_DEVICERCMDKEYMASK)
        case .rightSuper:
            keyMask = UInt(NX_DEVICERCMDKEYMASK)
            familyMask = UInt(NX_DEVICELCMDKEYMASK) | keyMask
        case .capsLock:
            return event.modifierFlags.contains(.capsLock)
        default:
            return nil
        }

        let rawFlags = event.modifierFlags.rawValue
        if rawFlags & familyMask != 0 {
            return rawFlags & keyMask != 0
        }
        guard let flag = modifierFlag(for: key) else { return nil }
        return event.modifierFlags.contains(flag)
    }

    private static let kittyBaseLayoutKeyMap: [UInt16: UnicodeScalar] = {
        func scalar(_ char: Character) -> UnicodeScalar {
            char.unicodeScalars.first!
        }
        return [
            0: scalar("a"),
            1: scalar("s"),
            2: scalar("d"),
            3: scalar("f"),
            4: scalar("h"),
            5: scalar("g"),
            6: scalar("z"),
            7: scalar("x"),
            8: scalar("c"),
            9: scalar("v"),
            11: scalar("b"),
            12: scalar("q"),
            13: scalar("w"),
            14: scalar("e"),
            15: scalar("r"),
            16: scalar("y"),
            17: scalar("t"),
            18: scalar("1"),
            19: scalar("2"),
            20: scalar("3"),
            21: scalar("4"),
            22: scalar("6"),
            23: scalar("5"),
            24: scalar("="),
            25: scalar("9"),
            26: scalar("7"),
            27: scalar("-"),
            28: scalar("8"),
            29: scalar("0"),
            30: scalar("]"),
            31: scalar("o"),
            32: scalar("u"),
            33: scalar("["),
            34: scalar("i"),
            35: scalar("p"),
            37: scalar("l"),
            38: scalar("j"),
            39: scalar("'"),
            40: scalar("k"),
            41: scalar(";"),
            42: scalar("\\"),
            43: scalar(","),
            44: scalar("/"),
            45: scalar("n"),
            46: scalar("m"),
            47: scalar("."),
            49: scalar(" "),
            50: scalar("`")
        ]
    }()

    private func kittyBaseLayoutKey(from event: NSEvent) -> UnicodeScalar? {
        Self.kittyBaseLayoutKeyMap[event.keyCode]
    }

    private func kittyTextEvent(from event: NSEvent, eventType: KittyKeyboardEventType, text: String? = nil) -> KittyKeyEvent? {
        let isControlSpace = event.modifierFlags.contains(.control)
            && event.keyCode == UInt16(kVK_Space)
        // With Control held, charactersIgnoringModifiers retains Control's
        // text translation on macOS (Ctrl+C gives U+0003). Translate the key
        // code against the layout only in that case: the translation uses
        // the key code, which synthesized events do not set correctly.
        let hasControl = event.modifierFlags.contains(.control)
        let reportedScalar: UnicodeScalar?
        if hasControl {
            reportedScalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first
                ?? event.charactersIgnoringModifiers?.unicodeScalars.first
        } else {
            reportedScalar = event.charactersIgnoringModifiers?.unicodeScalars.first
        }
        guard let scalar = isControlSpace ? UnicodeScalar(0x20) : reportedScalar else {
            return nil
        }
        let baseScalar = String(scalar).lowercased().unicodeScalars.first ?? scalar
        let shiftedScalar: UnicodeScalar?
        if event.modifierFlags.contains(.shift) && !isControlSpace {
            if hasControl {
                shiftedScalar = event.characters(byApplyingModifiers: [.shift])?.unicodeScalars.first
                    ?? event.characters?.unicodeScalars.first
            } else {
                shiftedScalar = event.characters?.unicodeScalars.first
            }
        } else {
            shiftedScalar = nil
        }
        let baseLayout = kittyBaseLayoutKey(from: event)
        let baseLayoutKey = baseLayout == baseScalar ? nil : baseLayout
        let modifiers = kittyModifiers(from: event, includeOption: optionIsMeta(for: event))
        return KittyKeyEvent(key: .unicode(baseScalar.value),
                             modifiers: modifiers,
                             eventType: eventType,
                             text: text,
                             shiftedKey: shiftedScalar,
                             baseLayoutKey: baseLayoutKey,
                             composing: isComposing)
    }

    private func kittyKeyEvent(from event: NSEvent, eventType: KittyKeyboardEventType, text: String? = nil) -> KittyKeyEvent? {
        if let functionKey = kittyFunctionalKey(from: event) {
            let modifiers = kittyModifiers(from: event, includeOption: optionIsMeta(for: event))
            return KittyKeyEvent(key: .functional(functionKey),
                                 modifiers: modifiers,
                                 eventType: eventType,
                                 text: text,
                                 shiftedKey: nil,
                                 baseLayoutKey: nil,
                                 composing: isComposing)
        }
        return kittyTextEvent(from: event, eventType: eventType, text: text)
    }

    private func kittyTextEventFromText(_ text: String) -> KittyKeyEvent {
        return KittyKeyEvent(key: .none,
                             modifiers: [],
                             eventType: .press,
                             text: text,
                             shiftedKey: nil,
                             baseLayoutKey: nil,
                             composing: isComposing)
    }

    /// Whether `text` is a non-empty run of printable scalars (no C0/C1 control
    /// characters). Used to decide when Option-composed input can be sent as
    /// literal UTF-8 rather than encoded as a kitty key event.
    private func isPlainPrintableText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || (scalar.value >= 0x7f && scalar.value <= 0x9f) {
                return false
            }
        }
        return true
    }

    /// Returns the single scalar of `text` when it is a C0 control or DEL.
    private func singleControlScalar(in text: String) -> UnicodeScalar? {
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first,
              scalars.index(after: scalars.startIndex) == scalars.endIndex,
              scalar.value < 0x20 || scalar.value == 0x7f else {
            return nil
        }
        return scalar
    }

    private func isPreeditEditCharacter(_ text: String) -> Bool {
        guard let scalar = singleControlScalar(in: text) else { return false }
        return scalar.value == 0x08 || scalar.value == 0x7f
    }
}
#endif
