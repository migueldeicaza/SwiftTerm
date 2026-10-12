//
//  BidiArrowKeyTests.swift
//
//  The portable paragraph direction resolver and the BiDi arrow-key swap
//  (DEC private mode 1243) in the core key encoding step.
//
import Testing

@testable import SwiftTerm

final class BidiArrowKeyTests {
    final class Image: TerminalImage {
        let pixelWidth = 1
        let pixelHeight = 1
        var col: Int
        let columnWidth: Int
        init(_ col: Int, _ width: Int) {
            self.col = col
            columnWidth = width
        }
    }

    let delegate = TerminalTestDelegate()

    func makeTerminal(_ text: String = "", cols: Int = 20,
                      state: BidiPresentationState = .default,
                      cap: Int = 500) -> Terminal {
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(
            cols: cols, rows: 5, initialBidiState: state,
            maximumBidiParagraphRows: cap))
        terminal.feed(text: text)
        return terminal
    }

    func direction(_ terminal: Terminal, row: Int = 0,
                   hostPolicy: BidiHostPolicy = .respectTerminal) -> BidiDirection {
        TerminalBidi.baseDirection(row: row, buffer: terminal.buffer, cols: terminal.cols,
                                   maximumRows: terminal.options.maximumBidiParagraphRows,
                                   hostPolicy: hostPolicy)
    }

    static func state(_ mode: BidiPresentationMode) -> BidiPresentationState {
        switch mode {
        case .implicitLeftToRight:
            return BidiPresentationState(autodetectDirection: false, fallbackDirection: .leftToRight)
        case .implicitRightToLeft:
            return BidiPresentationState(autodetectDirection: false, fallbackDirection: .rightToLeft)
        case .implicitAutoLeftToRight:
            return BidiPresentationState(autodetectDirection: true, fallbackDirection: .leftToRight)
        case .implicitAutoRightToLeft:
            return BidiPresentationState(autodetectDirection: true, fallbackDirection: .rightToLeft)
        case .explicitLeftToRight:
            return BidiPresentationState(supportMode: .explicit, fallbackDirection: .leftToRight)
        case .explicitRightToLeft:
            return BidiPresentationState(supportMode: .explicit, fallbackDirection: .rightToLeft)
        }
    }

    static let allModes: [BidiPresentationMode] = [
        .implicitLeftToRight, .implicitRightToLeft, .implicitAutoLeftToRight,
        .implicitAutoRightToLeft, .explicitLeftToRight, .explicitRightToLeft,
    ]

    // MARK: - Direction resolver

    @Test(arguments: allModes)
    func resolverFollowsThePresentationMode(mode: BidiPresentationMode) {
        let state = Self.state(mode)
        #expect(state.presentationMode == mode)
        let auto = mode == .implicitAutoLeftToRight || mode == .implicitAutoRightToLeft
        // A paragraph without strong characters uses the stored direction.
        #expect(direction(makeTerminal("12 34", state: state)) == state.fallbackDirection)
        // Only autodetection reads the letters.
        #expect(direction(makeTerminal("שלום abc", state: state))
                == (auto ? .rightToLeft : state.fallbackDirection))
        #expect(direction(makeTerminal("abc שלום", state: state))
                == (auto ? .leftToRight : state.fallbackDirection))
    }

    @Test func autodetectionUsesTheFirstStrongCharacter() {
        for fallback in [BidiDirection.leftToRight, .rightToLeft] {
            let state = BidiPresentationState(autodetectDirection: true, fallbackDirection: fallback)
            #expect(direction(makeTerminal("123 (שלום) abc", state: state)) == .rightToLeft)
            #expect(direction(makeTerminal("123 [abc] שלום", state: state)) == .leftToRight)
            #expect(direction(makeTerminal("مرحبا", state: state)) == .rightToLeft)
            #expect(direction(makeTerminal("", state: state)) == fallback)
        }
    }

    @Test func letterRuleCountsLettersAndMarks() {
        #expect(TerminalBidi.strongDirection("\u{200F}") == .rightToLeft)
        #expect(TerminalBidi.strongDirection("\u{200E}") == .leftToRight)
        #expect(TerminalBidi.strongDirection("\u{202B}") == nil)
        #expect(TerminalBidi.strongDirection("1") == nil)
        #expect(TerminalBidi.strongDirection("Z") == .leftToRight)
        #expect(TerminalBidi.strongDirection("ש") == .rightToLeft)
        #expect(TerminalBidi.strongDirection("\u{1F600}") == nil)
        // A cell uses its first strong scalar.
        #expect(TerminalBidi.strongDirection(of: Character("\u{0301}")) == nil)
        #expect(TerminalBidi.strongDirection(of: Character("שָׁ")) == .rightToLeft)
        #expect(TerminalBidi.strongDirection(of: Character("\u{1F1EE}\u{1F1F1}")) == nil)
    }

    // These classes are from Unicode 17 DerivedBidiClass.txt.
    @Test(arguments: [(UInt32(0x10900), BidiDirection.rightToLeft), // Phoenician: R
                      (0x1E900, .rightToLeft),                     // Adlam: R
                      (0x1EE00, .rightToLeft),                     // Arabic mathematical alef: AL
                      (0x10400, .leftToRight),                     // Deseret: L
                      (0x1D400, .leftToRight)])                    // Mathematical bold A: L
    func supplementaryLettersSetTheDirection(scalar: UInt32, expected: BidiDirection) {
        let text = "1 " + String(UnicodeScalar(scalar)!)
        for fallback in [BidiDirection.leftToRight, .rightToLeft] {
            let state = BidiPresentationState(autodetectDirection: true, fallbackDirection: fallback)
            #expect(direction(makeTerminal(text, state: state)) == expected)
        }
    }

    // Icons and flags have the Bidi_Class L, but only letters set the
    // paragraph direction.
    @Test(arguments: ["\u{F02A2}", "\u{E0B0}", "\u{1F1EE}\u{1F1F1}", "\u{F0001}", "\u{1F600}",
                      "\u{1D7D9}", "\u{10D30}"])
    func symbolsAndDigitsDoNotSetTheDirection(prefix: String) {
        let ltr = BidiPresentationState(autodetectDirection: true, fallbackDirection: .leftToRight)
        let rtl = BidiPresentationState(autodetectDirection: true, fallbackDirection: .rightToLeft)
        #expect(direction(makeTerminal(prefix + " שלום", state: ltr)) == .rightToLeft)
        #expect(direction(makeTerminal(prefix + " abc", state: rtl)) == .leftToRight)
        #expect(direction(makeTerminal(prefix, state: ltr)) == .leftToRight)
        #expect(direction(makeTerminal(prefix, state: rtl)) == .rightToLeft)
    }

    @Test func imageCellsAreNeutral() {
        let state = BidiPresentationState(autodetectDirection: true, fallbackDirection: .leftToRight)
        let hidden = makeTerminal("שabc", state: state)
        #expect(direction(hidden) == .rightToLeft)
        // An image that covers the Hebrew letter hides it.
        hidden.buffer.lines[0].images = [Image(0, 1)]
        #expect(direction(hidden) == .leftToRight)

        let covered = makeTerminal("aשלום", state: state)
        covered.buffer.lines[0].images = [Image(0, 1)]
        #expect(direction(covered) == .rightToLeft)

        // An image alone does not set the direction.
        let rtl = BidiPresentationState(autodetectDirection: true, fallbackDirection: .rightToLeft)
        let alone = makeTerminal("", state: rtl)
        alone.buffer.lines[0].images = [Image(2, 3)]
        #expect(direction(alone) == .rightToLeft)
    }

    @Test func aStrongCharacterOnALaterRowSetsTheWholeParagraph() {
        let state = BidiPresentationState(autodetectDirection: true, fallbackDirection: .leftToRight)
        let terminal = makeTerminal("1234 שלום", cols: 5, state: state)
        #expect(terminal.buffer.lines[1].isWrapped)
        #expect(direction(terminal, row: 0) == .rightToLeft)
        #expect(direction(terminal, row: 1) == .rightToLeft)
        // A hard line break starts a new paragraph.
        terminal.feed(text: "\r\n12")
        #expect(direction(terminal, row: 2) == .leftToRight)
    }

    @Test func paragraphsAboveTheRowLimitUseExplicitDisplay() {
        let auto = BidiPresentationState(autodetectDirection: true, fallbackDirection: .rightToLeft)
        let forced = BidiPresentationState(autodetectDirection: false, fallbackDirection: .rightToLeft)
        for text in ["אב1234567", "abc1234"] {
            let autoTerminal = makeTerminal(text, cols: 3, state: auto, cap: 2)
            let forcedTerminal = makeTerminal(text, cols: 3, state: forced, cap: 2)
            #expect(autoTerminal.buffer.lines[2].isWrapped)
            for row in 0...2 {
                // Autodetection keeps logical order above the limit.
                #expect(direction(autoTerminal, row: row) == .leftToRight)
                #expect(direction(forcedTerminal, row: row) == .rightToLeft)
            }
        }
        // At the limit, the paragraph is complete.
        let atLimit = makeTerminal("123אב", cols: 3, state: auto, cap: 2)
        #expect(direction(atLimit, row: 0) == .rightToLeft)
        #expect(direction(atLimit, row: 1) == .rightToLeft)
    }

    @Test(arguments: allModes)
    func legacyLeftToRightHostPolicyIsAlwaysLeftToRight(mode: BidiPresentationMode) {
        let terminal = makeTerminal("שלום", state: Self.state(mode))
        #expect(direction(terminal, hostPolicy: .legacyLeftToRight) == .leftToRight)
        terminal.bidiHostPolicy = .legacyLeftToRight
        #expect(terminal.cursorParagraphBaseDirection() == .leftToRight)
    }

    @Test func cursorParagraphFollowsTheCursorRow() {
        let terminal = makeTerminal("שלום\r\nabc")
        #expect(terminal.cursorParagraphBaseDirection() == .leftToRight)
        terminal.feed(text: "\u{1b}[1;1H")
        #expect(terminal.cursorParagraphBaseDirection() == .rightToLeft)
        #expect(direction(terminal, row: 99) == .leftToRight)
        #expect(direction(terminal, row: -1) == .leftToRight)
    }

    // MARK: - Key encoding

    static func event(_ key: KittyFunctionalKey, _ type: KittyKeyboardEventType = .press,
                      modifiers: KittyKeyboardModifiers = []) -> KittyKeyEvent {
        KittyKeyEvent(key: .functional(key), modifiers: modifiers, eventType: type,
                      text: nil, shiftedKey: nil, baseLayoutKey: nil)
    }

    func encoder(_ terminal: Terminal) -> KittyKeyboardEncoder {
        KittyKeyboardEncoder(flags: terminal.keyboardEnhancementFlags,
                             applicationCursor: terminal.applicationCursor,
                             applicationKeypad: terminal.applicationKeypad,
                             backspaceSendsControlH: false)
    }

    /// Legacy encoding, then each kitty flag alone, then common combinations.
    static let flagSets = [0, 1, 2, 4, 8, 16, 3, 10, 11, 31]

    @Test(arguments: flagSets)
    func pressRepeatAndReleaseSwapOnRightToLeftParagraphs(flags: Int) {
        let pairs: [(KittyFunctionalKey, KittyFunctionalKey)] = [
            (.left, .right), (.right, .left), (.keypadLeft, .keypadRight), (.keypadRight, .keypadLeft),
        ]
        for rtl in [true, false] {
            let terminal = makeTerminal(rtl ? "שלום" : "abc")
            terminal.feed(text: "\u{1b}[>\(flags)u")
            let reference = encoder(terminal)
            for modifiers in [KittyKeyboardModifiers(), [.shift], [.ctrl], [.alt]] {
                for (key, mirrored) in pairs {
                    for type in [KittyKeyboardEventType.press, .repeatPress, .release] {
                        let expected = reference.encode(Self.event(rtl ? mirrored : key, type,
                                                                   modifiers: modifiers))
                        #expect(terminal.encodeKeyEvent(Self.event(key, type, modifiers: modifiers))
                                == expected)
                    }
                }
            }
        }
    }

    @Test func legacyArrowsSendTheMirroredSequence() {
        let terminal = makeTerminal("שלום")
        #expect(terminal.encodeKeyEvent(Self.event(.left)) == EscapeSequences.moveRightNormal)
        #expect(terminal.encodeKeyEvent(Self.event(.right)) == EscapeSequences.moveLeftNormal)
        terminal.feed(text: "\u{1b}[?1h")
        #expect(terminal.encodeKeyEvent(Self.event(.left)) == EscapeSequences.moveRightApp)
        #expect(terminal.encodeKeyEvent(Self.event(.left, modifiers: [.ctrl]))
                == EscapeSequences.controlRight)
        #expect(terminal.sendsLeftArrowSequence(forLeftKey: true) == false)
        #expect(terminal.sendsLeftArrowSequence(forLeftKey: false) == true)
    }

    @Test func otherKeysAndDisabledSwapDoNotChange() {
        let terminal = makeTerminal("שלום")
        let reference = encoder(terminal)
        for key in [KittyFunctionalKey.up, .down, .home, .end, .keypadUp, .keypadHome, .enter] {
            #expect(terminal.encodeKeyEvent(Self.event(key)) == reference.encode(Self.event(key)))
        }
        terminal.bidiArrowKeySwap = false
        #expect(terminal.encodeKeyEvent(Self.event(.left)) == EscapeSequences.moveLeftNormal)
        terminal.feed(text: "\u{1b}[?1243h")
        #expect(terminal.encodeKeyEvent(Self.event(.left)) == EscapeSequences.moveRightNormal)
        terminal.feed(text: "\u{1b}[?1243l")
        #expect(terminal.encodeKeyEvent(Self.event(.left)) == EscapeSequences.moveLeftNormal)
    }

    @Test func explicitRightToLeftSwapsAndLegacyHostPolicyDoesNot() {
        let terminal = makeTerminal("abc", state: Self.state(.explicitRightToLeft))
        #expect(terminal.encodeKeyEvent(Self.event(.left)) == EscapeSequences.moveRightNormal)
        terminal.bidiHostPolicy = .legacyLeftToRight
        #expect(terminal.encodeKeyEvent(Self.event(.left)) == EscapeSequences.moveLeftNormal)
    }

    @Test(arguments: [3, 11, 31])
    func repeatAndReleaseUseTheKeyThatThePressSent(flags: Int) throws {
        let terminal = makeTerminal("שלום\r\nabc")
        terminal.feed(text: "\u{1b}[>\(flags)u\u{1b}[1;1H")
        let reference = encoder(terminal)
        func sent(_ key: KittyFunctionalKey, _ type: KittyKeyboardEventType) -> [UInt8]? {
            terminal.encodeKeyEvent(Self.event(key, type))
        }
        #expect(sent(.left, .press) == reference.encode(Self.event(.right)))
        // The cursor moves into a left-to-right paragraph while the key is down.
        terminal.feed(text: "\u{1b}[2;1H")
        #expect(terminal.cursorParagraphBaseDirection() == .leftToRight)
        #expect(sent(.left, .repeatPress) == reference.encode(Self.event(.right, .repeatPress)))
        // Another key chooses at its own press.
        #expect(sent(.right, .press) == reference.encode(Self.event(.right)))
        #expect(sent(.left, .release) == reference.encode(Self.event(.right, .release)))
        #expect(sent(.right, .release) == reference.encode(Self.event(.right, .release)))
        // The next press chooses again.
        #expect(sent(.left, .press) == reference.encode(Self.event(.left)))
        #expect(sent(.left, .release) == reference.encode(Self.event(.left, .release)))
        #expect(terminal.bidiArrowKeyPressSwaps.isEmpty)
    }

    @Test func repeatAndReleaseKeepThePressChoiceWhenTheModeChanges() {
        let terminal = makeTerminal("שלום")
        terminal.feed(text: "\u{1b}[>3u")
        let reference = encoder(terminal)
        #expect(terminal.encodeKeyEvent(Self.event(.left)) == reference.encode(Self.event(.right)))
        terminal.feed(text: "\u{1b}[?1243l")
        #expect(terminal.encodeKeyEvent(Self.event(.left, .repeatPress))
                == reference.encode(Self.event(.right, .repeatPress)))
        #expect(terminal.encodeKeyEvent(Self.event(.left, .release))
                == reference.encode(Self.event(.right, .release)))
    }

    @Test func legacySequencesShareThePressChoice() {
        let terminal = makeTerminal("שלום\r\nabc")
        terminal.feed(text: "\u{1b}[1;1H")
        #expect(terminal.encodeKeyEvent(Self.event(.left)) == EscapeSequences.moveRightNormal)
        terminal.feed(text: "\u{1b}[2;1H")
        #expect(terminal.sendsLeftArrowSequence(forLeftKey: true, eventType: .repeatPress) == false)
        #expect(terminal.sendsLeftArrowSequence(forLeftKey: true, eventType: .press) == true)
        terminal.feed(text: "\u{1b}[1;1H")
        #expect(terminal.sendsLeftArrowSequence(forLeftKey: false, eventType: .press) == true)
        terminal.feed(text: "\u{1b}[2;1H")
        #expect(terminal.encodeKeyEvent(Self.event(.right, .repeatPress)) == EscapeSequences.moveLeftNormal)
    }

    @Test func resetsAndBufferSwitchesClearThePressChoices() {
        for clear in ["\u{1b}c", "\u{1b}[!p", "\u{1b}[?1049h"] {
            let terminal = makeTerminal("שלום")
            #expect(terminal.encodeKeyEvent(Self.event(.left)) == EscapeSequences.moveRightNormal)
            #expect(!terminal.bidiArrowKeyPressSwaps.isEmpty)
            terminal.feed(text: clear + "\u{1b}[H\u{1b}[2J")
            #expect(terminal.bidiArrowKeyPressSwaps.isEmpty)
            // Without a press choice, the repeat follows the paragraph at the cursor.
            #expect(terminal.encodeKeyEvent(Self.event(.left, .repeatPress)) == EscapeSequences.moveLeftNormal)
        }
    }

    // MARK: - Web host

    @Test func webHostSwapsTheArrowKeys() {
        let terminal = makeTerminal("שלום")
        delegate.clearSentData()
        #expect(terminal.sendHostKey(key: "ArrowLeft", code: "ArrowLeft", modifiers: 0,
                                     eventType: 1, text: nil) == 1)
        #expect(terminal.sendHostKey(key: "ArrowRight", code: "ArrowRight", modifiers: 0,
                                     eventType: 1, text: nil) == 1)
        #expect(terminal.sendHostKey(key: "ArrowLeft", code: "ArrowLeft", modifiers: 4,
                                     eventType: 1, text: nil) == 1)
        #expect(delegate.sentData == [Array("\u{1b}[C".utf8), Array("\u{1b}[D".utf8),
                                      Array("\u{1b}[1;5C".utf8)])
        // Home and End do not swap.
        delegate.clearSentData()
        #expect(terminal.sendHostKey(key: "Home", code: "Home", modifiers: 0, eventType: 1, text: nil) == 1)
        #expect(delegate.sentData == [Array("\u{1b}[H".utf8)])
    }

    @Test func webHostKeypadArrowsSwap() {
        let terminal = makeTerminal("שלום")
        terminal.feed(text: "\u{1b}[>1u")
        delegate.clearSentData()
        let reference = encoder(terminal)
        #expect(terminal.sendHostKey(key: "ArrowLeft", code: "Numpad4", modifiers: 0,
                                     eventType: 1, text: nil) == 1)
        #expect(delegate.sentData == [reference.encode(Self.event(.keypadRight))])
    }

    @Test func webHostReleaseUsesTheKeyOfThePress() {
        let terminal = makeTerminal("שלום\r\nabc")
        terminal.feed(text: "\u{1b}[>3u\u{1b}[1;1H")
        delegate.clearSentData()
        #expect(terminal.sendHostKey(key: "ArrowLeft", code: "ArrowLeft", modifiers: 0,
                                     eventType: 1, text: nil) == 1)
        terminal.feed(text: "\u{1b}[2;1H")
        #expect(terminal.sendHostKey(key: "ArrowLeft", code: "ArrowLeft", modifiers: 0,
                                     eventType: 2, text: nil) == 1)
        #expect(terminal.sendHostKey(key: "ArrowLeft", code: "ArrowLeft", modifiers: 0,
                                     eventType: 3, text: nil) == 1)
        #expect(delegate.sentData == [Array("\u{1b}[C".utf8), Array("\u{1b}[1;1:2C".utf8),
                                      Array("\u{1b}[1;1:3C".utf8)])
    }

    @Test func webHostWithLegacyPolicyDoesNotSwap() {
        let terminal = makeTerminal("שלום")
        terminal.bidiHostPolicy = .legacyLeftToRight
        delegate.clearSentData()
        #expect(terminal.sendHostKey(key: "ArrowLeft", code: "ArrowLeft", modifiers: 0,
                                     eventType: 1, text: nil) == 1)
        #expect(delegate.sentData == [Array("\u{1b}[D".utf8)])
    }

    // MARK: - DECRQM 1243

    func reportArrowSwapMode(_ terminal: Terminal) -> String {
        delegate.clearSentData()
        terminal.feed(text: "\u{1b}[?1243$p")
        return String(decoding: delegate.sentData.joined(), as: UTF8.self)
    }

    @Test func decrqmReportsTheStateOfTheTerminalWithoutAHostCallback() {
        let terminal = makeTerminal()
        #expect(reportArrowSwapMode(terminal) == "\u{1b}[?1243;1$y")
        terminal.feed(text: "\u{1b}[?1243l")
        #expect(reportArrowSwapMode(terminal) == "\u{1b}[?1243;2$y")
        terminal.bidiArrowKeySwap = true
        #expect(reportArrowSwapMode(terminal) == "\u{1b}[?1243;1$y")
    }

    @Test func decrqmReportsPermanentlyResetForALegacyHost() {
        let terminal = makeTerminal()
        terminal.bidiHostPolicy = .legacyLeftToRight
        for sequence in ["", "\u{1b}[?1243h", "\u{1b}[?1243l"] {
            terminal.feed(text: sequence)
            #expect(reportArrowSwapMode(terminal) == "\u{1b}[?1243;4$y")
        }
        terminal.bidiHostPolicy = .respectTerminal
        #expect(reportArrowSwapMode(terminal) == "\u{1b}[?1243;2$y")
        // A reset does not change the host policy.
        terminal.bidiHostPolicy = .legacyLeftToRight
        terminal.resetToInitialState()
        #expect(terminal.bidiHostPolicy == .legacyLeftToRight)
    }
}
