/// Input adapters for hosts that use the terminal without an Apple view.
public extension Terminal {
    /// Complete an accepted OSC 52 read on the same executor as feed.
    func completeClipboardRead(selection: String, content: [UInt8]) {
        sendResponse(cc.OSC, "52;\(selection);\(terminalBase64Encode(TerminalData(content)))", cc.ST)
    }

    /// Bit 0: application cursor; bit 1: application keypad; bit 2: bracketed
    /// paste; bit 3: Kitty paste. Bits 8...12 contain Kitty keyboard flags.
    var hostInputModes: UInt32 {
        (applicationCursor ? 1 : 0) | (applicationKeypad ? 2 : 0)
            | (bracketedPasteMode ? 4 : 0) | (kittyPasteEventsEnabled ? 8 : 0)
            | (UInt32(keyboardEnhancementFlags.rawValue) << 8)
    }

    /// Queue a safe text paste. Returns false when the payload needs approval.
    @discardableResult
    func sendHostTextPaste(_ text: String, allowUnsafe: Bool = false) -> Bool {
        guard case .encoded(let bytes) = TerminalPaste.encode(text, bracketed: bracketedPasteMode,
            terminalControlBytes: tdel?.terminalControlBytesForPaste(source: self)
                ?? TerminalPasteControls.approximateTerminalControlBytes, allowUnsafe: allowUnsafe) else { return false }
        registerUserInput(bytes[...])
        tdel?.send(source: self, data: bytes[...])
        return true
    }

    /// Encode a browser key through the same encoder as the native views.
    /// Return 0 for browser text input, 1 when bytes were queued, and 2 when
    /// the event was handled without bytes (for example a key release).
    @discardableResult
    func sendHostKey(key name: String, code: String, modifiers: UInt32, eventType: UInt32,
                     text: String?, shiftedKey: UInt32 = 0, baseLayoutKey: UInt32 = 0) -> Int {
        guard let type = KittyKeyboardEventType(rawValue: Int(eventType)) else { return 2 }
        let named: [String: KittyFunctionalKey] = [
            "Escape": .escape, "Enter": .enter, "Tab": .tab, "Backspace": .backspace,
            "Insert": .insert, "Delete": .delete, "ArrowUp": .up, "ArrowDown": .down,
            "ArrowLeft": .left, "ArrowRight": .right, "Home": .home, "End": .end,
            "PageUp": .pageUp, "PageDown": .pageDown, "CapsLock": .capsLock,
            "NumLock": .numLock, "ScrollLock": .scrollLock, "PrintScreen": .printScreen,
            "Pause": .pause, "ContextMenu": .menu,
            "F1": .f1, "F2": .f2, "F3": .f3, "F4": .f4, "F5": .f5, "F6": .f6,
            "F7": .f7, "F8": .f8, "F9": .f9, "F10": .f10, "F11": .f11, "F12": .f12,
            "F13": .f13, "F14": .f14, "F15": .f15, "F16": .f16, "F17": .f17,
            "F18": .f18, "F19": .f19, "F20": .f20, "F21": .f21, "F22": .f22,
            "F23": .f23, "F24": .f24, "F25": .f25, "F26": .f26,
            "F27": .f27, "F28": .f28, "F29": .f29, "F30": .f30,
            "F31": .f31, "F32": .f32, "F33": .f33, "F34": .f34, "F35": .f35,
            "MediaPlay": .mediaPlay, "MediaPause": .mediaPause,
            "MediaPlayPause": .mediaPlayPause, "MediaStop": .mediaStop,
            "MediaFastForward": .mediaFastForward, "MediaRewind": .mediaRewind,
            "MediaTrackNext": .mediaTrackNext, "MediaTrackPrevious": .mediaTrackPrevious,
            "AudioVolumeDown": .volumeDown, "AudioVolumeUp": .volumeUp, "AudioVolumeMute": .volumeMute,
        ]
        let physical: [String: KittyFunctionalKey] = [
            "Numpad0": .keypad0, "Numpad1": .keypad1, "Numpad2": .keypad2,
            "Numpad3": .keypad3, "Numpad4": .keypad4, "Numpad5": .keypad5,
            "Numpad6": .keypad6, "Numpad7": .keypad7, "Numpad8": .keypad8,
            "Numpad9": .keypad9, "NumpadDecimal": .keypadDecimal,
            "NumpadDivide": .keypadDivide, "NumpadMultiply": .keypadMultiply,
            "NumpadSubtract": .keypadSubtract, "NumpadAdd": .keypadAdd,
            "NumpadEnter": .keypadEnter, "NumpadEqual": .keypadEqual,
            "NumpadComma": .keypadSeparator,
            "ShiftLeft": .leftShift, "ShiftRight": .rightShift,
            "ControlLeft": .leftControl, "ControlRight": .rightControl,
            "AltLeft": .leftAlt, "AltRight": .rightAlt,
            "MetaLeft": .leftSuper, "MetaRight": .rightSuper,
        ]
        let keypadNavigation: [String: KittyFunctionalKey] = [
            "ArrowLeft": .keypadLeft, "ArrowRight": .keypadRight,
            "ArrowUp": .keypadUp, "ArrowDown": .keypadDown,
            "PageUp": .keypadPageUp, "PageDown": .keypadPageDown,
            "Home": .keypadHome, "End": .keypadEnd,
            "Insert": .keypadInsert, "Delete": .keypadDelete, "Clear": .keypadBegin,
        ]
        let function = (code.hasPrefix("Numpad") ? keypadNavigation[name] : nil) ?? physical[code] ?? named[name]
        let key: KittyKey
        if let function { key = .functional(function) }
        else if name.unicodeScalars.count == 1, let scalar = name.unicodeScalars.first {
            // Plain text stays with the browser so IME and dead keys remain intact.
            if keyboardEnhancementFlags.isEmpty && modifiers & 0x0e == 0 { return type == .release ? 2 : 0 }
            key = .unicode(scalar.value)
        } else { return type == .release ? 2 : 0 }
        let event = KittyKeyEvent(key: key, modifiers: KittyKeyboardModifiers(rawValue: Int(modifiers)),
            eventType: type, text: text, shiftedKey: shiftedKey == 0 ? nil : UnicodeScalar(shiftedKey),
            baseLayoutKey: baseLayoutKey == 0 ? nil : UnicodeScalar(baseLayoutKey))
        let encoder = KittyKeyboardEncoder(flags: keyboardEnhancementFlags, applicationCursor: applicationCursor,
            applicationKeypad: applicationKeypad, backspaceSendsControlH: false)
        guard let bytes = encoder.encode(event) else { return 2 }
        registerUserInput(bytes[...])
        tdel?.send(source: self, data: bytes[...])
        return 1
    }
}
