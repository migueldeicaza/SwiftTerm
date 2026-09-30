import Testing
@testable import SwiftTerm

struct TerminalWebInputTests {
    @Test func modifierAndReleaseFilteringUsesCurrentKittyModes() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        for (key, code) in [("Shift", "ShiftLeft"), ("Control", "ControlLeft"),
                            ("Alt", "AltRight"), ("Meta", "MetaLeft"),
                            ("CapsLock", "CapsLock"), ("NumLock", "NumLock")] {
            #expect(terminal.sendHostKey(key: key, code: code, modifiers: 0, eventType: 1, text: nil) == 2)
        }
        #expect(terminal.sendHostKey(key: "ArrowUp", code: "ArrowUp", modifiers: 0, eventType: 3, text: nil) == 2)
        #expect(delegate.sentData.isEmpty)
        terminal.feed(text: "\u{1b}[>10u") // All keys and press/repeat/release events.
        #expect(terminal.sendHostKey(key: "Shift", code: "ShiftLeft", modifiers: 1, eventType: 1, text: nil) == 1)
        #expect(terminal.sendHostKey(key: "Shift", code: "ShiftLeft", modifiers: 0, eventType: 3, text: nil) == 1)
        #expect(delegate.sentData == [Array("\u{1b}[57441;2u".utf8), Array("\u{1b}[57441;1:3u".utf8)])
    }

    @Test(arguments: [0, 1, 2, 8, 10, 31])
    func bareModifierNamesMatchTheNativeEncoder(flags: Int) {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\u{1b}[>\(flags)u")
        let encoder = KittyKeyboardEncoder(flags: KittyKeyboardFlags(rawValue: flags),
            applicationCursor: false, applicationKeypad: false, backspaceSendsControlH: false)
        let names: [(String, KittyFunctionalKey)] = [
            ("Shift", .leftShift), ("Control", .leftControl), ("Alt", .leftAlt),
            ("Meta", .leftSuper), ("Super", .leftSuper), ("Hyper", .leftHyper),
            ("AltGraph", .rightAlt), ("CapsLock", .capsLock), ("NumLock", .numLock)
        ]
        for (name, key) in names {
            for eventType in [KittyKeyboardEventType.press, .repeatPress, .release] {
                let expected = encoder.encode(KittyKeyEvent(key: .functional(key), modifiers: [],
                    eventType: eventType, text: nil))
                let before = delegate.sentData.count
                let result = terminal.sendHostKey(key: name, code: "", modifiers: 0,
                    eventType: UInt32(eventType.rawValue), text: nil)
                #expect(result == (expected == nil ? 2 : 1))
                #expect(delegate.sentData.count == before + (expected == nil ? 0 : 1))
                if let expected { #expect(delegate.sentData.last == expected) }
            }
        }
        // Physical right-side identity overrides the bare-name fallback.
        let expected = encoder.encode(KittyKeyEvent(key: .functional(.rightShift), modifiers: [],
            eventType: .press, text: nil))
        let result = terminal.sendHostKey(key: "Shift", code: "ShiftRight", modifiers: 0,
            eventType: 1, text: nil)
        #expect(result == (expected == nil ? 2 : 1))
        if let expected { #expect(delegate.sentData.last == expected) }
    }

    @Test(arguments: [false, true])
    func hostTextPasteUsesTheNativeTextRequest(bracketed: Bool) {
        let (host, hostDelegate) = TerminalTestHarness.makeTerminal()
        let (native, nativeDelegate) = TerminalTestHarness.makeTerminal()
        for terminal in [host, native] {
            // Text insertion does not use a clipboard snapshot, even with paste events enabled.
            terminal.feed(text: "\u{1b}[?5522h" + (bracketed ? "\u{1b}[?2004h" : ""))
        }
        for text in ["plain", "a\nb", "a\u{1b}b", "", "é😀"] {
            for allowUnsafe in [false, true] {
                let result = native.paste(TerminalPasteRequest(text: text), allowUnsafe: allowUnsafe)
                #expect(host.sendHostTextPaste(text, allowUnsafe: allowUnsafe) == (result == .textSent))
                #expect(hostDelegate.sentData == nativeDelegate.sentData)
            }
        }
    }

    @Test func sharedKeyMapsKeepApplicationKeypadAndCursorEncoding() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        #expect(terminal.sendHostKey(key: "End", code: "Numpad1", modifiers: 0, eventType: 1, text: nil) == 1)
        terminal.feed(text: "\u{1b}[?1h\u{1b}=")
        #expect(terminal.sendHostKey(key: "End", code: "Numpad1", modifiers: 0, eventType: 1, text: nil) == 1)
        #expect(terminal.sendHostKey(key: "ArrowUp", code: "ArrowUp", modifiers: 0, eventType: 1, text: nil) == 1)
        #expect(terminal.sendHostKey(key: "a", code: "KeyA", modifiers: 0, eventType: 1, text: "a") == 0)
        #expect(delegate.sentData == [Array("\u{1b}[F".utf8), Array("\u{1b}Oq".utf8), Array("\u{1b}OA".utf8)])
    }

    @Test func userInputStateIsUpdatedBeforeTheDelegateCanReenter() {
        let delegate = ReentrantInputDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 3, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}abc")
        delegate.observe = true
        #expect(terminal.sendHostKey(key: "Enter", code: "Enter", modifiers: 0, eventType: 1, text: nil) == 1)
        #expect(delegate.submittedBeforeSend == [true])
        #expect(delegate.sent == [Array("\r".utf8)])
        #expect(terminal.buffer.semanticInput == .armed, "The delegate can feed the next prompt during send.")

        #expect(!terminal.sendHostTextPaste("a\nb"))
        #expect(delegate.sent.count == 1, "A rejected paste does not reach the delegate.")
        #expect(terminal.sendHostTextPaste("a\nb", allowUnsafe: true))
        #expect(delegate.submittedBeforeSend == [true, true])
        #expect(delegate.sent.last == Array("a\rb".utf8))

        #expect(terminal.sendHostText("\r"))
        #expect(delegate.submittedBeforeSend == [true, true, true])
        #expect(delegate.sent.last == Array("\r".utf8))
    }

    @Test func bracketedPasteRetainsArmedSemanticStateAndUsesHostControls() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 20, rows: 3)
        delegate.terminalControlBytesForPasteValue = [0x01]
        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}abc\u{1b}[?2004h")
        #expect(terminal.sendHostTextPaste("a\n\u{01}b"))
        #expect(terminal.buffer.semanticInput == .armed)
        #expect(delegate.sentData == [Array("\u{1b}[200~a\n b\u{1b}[201~".utf8)])
    }
}

private final class ReentrantInputDelegate: TerminalDelegate {
    var observe = false
    var submittedBeforeSend: [Bool] = []
    var sent: [[UInt8]] = []
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard observe else { return }
        submittedBeforeSend.append(source.buffer.semanticInput == .submitted)
        sent.append(Array(data))
        source.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}")
    }
}
