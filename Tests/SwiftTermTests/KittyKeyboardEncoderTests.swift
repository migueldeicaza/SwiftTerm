//
//  KittyKeyboardEncoderTests.swift
//
#if os(macOS)
import XCTest
@testable import SwiftTerm

final class KittyKeyboardEncoderTests: XCTestCase {
    private func encode(_ event: KittyKeyEvent,
                        flags: KittyKeyboardFlags,
                        applicationCursor: Bool = false,
                        applicationKeypad: Bool = false,
                        backspaceSendsControlH: Bool = false) -> [UInt8]? {
        let encoder = KittyKeyboardEncoder(flags: flags,
                                           applicationCursor: applicationCursor,
                                           applicationKeypad: applicationKeypad,
                                           backspaceSendsControlH: backspaceSendsControlH)
        return encoder.encode(event)
    }

    private func assertEncode(_ event: KittyKeyEvent,
                              flags: KittyKeyboardFlags,
                              expected: String,
                              backspaceSendsControlH: Bool = false) {
        let actual = encode(event, flags: flags, backspaceSendsControlH: backspaceSendsControlH)
        XCTAssertEqual(actual, Array(expected.utf8))
    }

    private func assertNoEncode(_ event: KittyKeyEvent,
                                flags: KittyKeyboardFlags) {
        let actual = encode(event, flags: flags)
        XCTAssertNil(actual)
    }

    func testPlainTextWithDisambiguate() {
        let event = KittyKeyEvent(key: .unicode(97),
                                  modifiers: [],
                                  eventType: .press,
                                  text: "abcd",
                                  shiftedKey: nil,
                                  baseLayoutKey: nil)
        assertEncode(event, flags: [.disambiguate], expected: "abcd")
    }

    func testRepeatWithJustDisambiguate() {
        let event = KittyKeyEvent(key: .unicode(97),
                                  modifiers: [],
                                  eventType: .repeatPress,
                                  text: "a",
                                  shiftedKey: nil,
                                  baseLayoutKey: nil)
        assertEncode(event, flags: [.disambiguate], expected: "a")
    }

    func testReportEventsCtrlPressPreservesLegacyEncoding() {
        let event = KittyKeyEvent(key: .unicode(99),
                                  modifiers: [.ctrl],
                                  eventType: .press,
                                  text: "\u{3}",
                                  shiftedKey: nil,
                                  baseLayoutKey: nil)
        XCTAssertEqual(encode(event, flags: [.reportEvents]), [3])
    }

    func testReportEventsCtrlRepeatUsesCsiU() {
        let event = KittyKeyEvent(key: .unicode(99),
                                  modifiers: [.ctrl],
                                  eventType: .repeatPress,
                                  text: "\u{3}",
                                  shiftedKey: nil,
                                  baseLayoutKey: nil)
        assertEncode(event,
                     flags: [.reportEvents],
                     expected: "\u{1b}[99;5:2u")
    }

    func testReportEventsCtrlRepeatWithoutTextUsesCsiU() {
        let event = KittyKeyEvent(key: .unicode(99),
                                  modifiers: [.ctrl],
                                  eventType: .repeatPress,
                                  text: nil,
                                  shiftedKey: nil,
                                  baseLayoutKey: nil)
        assertEncode(event,
                     flags: [.reportEvents],
                     expected: "\u{1b}[99;5:2u")
    }

    func testPureTextWithReportAllAndReportTextStaysUtf8() {
        // The protocol has no key code for committed text. Ghostty and kitty
        // send it as UTF-8 in every mode.
        let event = KittyKeyEvent(key: .none,
                                  modifiers: [],
                                  eventType: .press,
                                  text: "é",
                                  shiftedKey: nil,
                                  baseLayoutKey: nil)
        assertEncode(event,
                     flags: [.reportAllKeys, .reportText],
                     expected: "é")
    }

    func testPureMultiScalarTextWithReportAllAndReportTextStaysUtf8() {
        let event = KittyKeyEvent(key: .none,
                                  modifiers: [],
                                  eventType: .press,
                                  text: "한글",
                                  shiftedKey: nil,
                                  baseLayoutKey: nil)
        assertEncode(event,
                     flags: [.reportAllKeys, .reportText, .reportEvents],
                     expected: "한글")
    }

    func testPureTextWithReportAllWithoutReportTextStaysUtf8() {
        let event = KittyKeyEvent(key: .none,
                                  modifiers: [],
                                  eventType: .press,
                                  text: "é",
                                  shiftedKey: nil,
                                  baseLayoutKey: nil)
        assertEncode(event, flags: [.reportAllKeys], expected: "é")
    }

    func testSingleScalarTextWithTextPreventingModifierEncodesAsKey() {
        // A single character with Alt or Ctrl is a real key press, such as
        // the iOS Meta accessory. Keep the modifier.
        let ctrlEvent = KittyKeyEvent(key: .none,
                                      modifiers: [.ctrl],
                                      eventType: .press,
                                      text: "é",
                                      shiftedKey: nil,
                                      baseLayoutKey: nil)
        assertEncode(ctrlEvent,
                     flags: [.reportAllKeys, .reportText],
                     expected: "\u{1b}[233;5u")

        let altEvent = KittyKeyEvent(key: .none,
                                     modifiers: [.alt],
                                     eventType: .press,
                                     text: "x",
                                     shiftedKey: nil,
                                     baseLayoutKey: nil)
        assertEncode(altEvent, flags: [.disambiguate], expected: "\u{1b}[120;3u")
        assertEncode(altEvent, flags: [.reportEvents], expected: "\u{1b}x")
    }

    func testMultiScalarTextWithTextPreventingModifierStaysUtf8() {
        let event = KittyKeyEvent(key: .none,
                                  modifiers: [.alt],
                                  eventType: .press,
                                  text: "한글",
                                  shiftedKey: nil,
                                  baseLayoutKey: nil)
        assertEncode(event, flags: [.disambiguate], expected: "한글")
    }

    func testKeylessEventWithoutTextIsSuppressed() {
        let event = KittyKeyEvent(key: .none,
                                  modifiers: [],
                                  eventType: .press,
                                  text: nil,
                                  shiftedKey: nil,
                                  baseLayoutKey: nil)
        assertNoEncode(event,
                       flags: [.reportAllKeys, .reportText, .reportEvents])
    }

    func testEnterBackspaceTabWithDisambiguate() {
        assertEncode(KittyKeyEvent(key: .functional(.enter),
                                   modifiers: [],
                                   eventType: .press,
                                   text: nil,
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate],
                     expected: "\r")
        assertEncode(KittyKeyEvent(key: .functional(.backspace),
                                   modifiers: [],
                                   eventType: .press,
                                   text: nil,
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate],
                     expected: "\u{7f}")
        assertEncode(KittyKeyEvent(key: .functional(.tab),
                                   modifiers: [],
                                   eventType: .press,
                                   text: nil,
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate],
                     expected: "\t")
    }

    func testShiftTabWithDisambiguateUsesCsiU() {
        assertEncode(KittyKeyEvent(key: .functional(.tab),
                                   modifiers: [.shift],
                                   eventType: .press,
                                   text: nil,
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate],
                     expected: "\u{1b}[9;2u")
    }

    func testShiftBackspaceWithDisambiguateUsesCsiU() {
        assertEncode(KittyKeyEvent(key: .functional(.backspace),
                                   modifiers: [.shift],
                                   eventType: .press,
                                   text: nil,
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate],
                     expected: "\u{1b}[127;2u")
    }

    func testShiftEnterWithDisambiguateUsesCsiU() {
        assertEncode(KittyKeyEvent(key: .functional(.enter),
                                   modifiers: [.shift],
                                   eventType: .press,
                                   text: nil,
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate],
                     expected: "\u{1b}[13;2u")
    }

    func testReportAllReleaseEnter() {
        assertEncode(KittyKeyEvent(key: .functional(.enter),
                                   modifiers: [],
                                   eventType: .release,
                                   text: nil,
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.reportAllKeys, .reportEvents],
                     expected: "\u{1b}[13;1:3u")
    }

    func testEnterReleaseWithoutReportAllIsSuppressed() {
        assertNoEncode(KittyKeyEvent(key: .functional(.enter),
                                     modifiers: [],
                                     eventType: .release,
                                     text: nil,
                                     shiftedKey: nil,
                                     baseLayoutKey: nil),
                       flags: [.disambiguate, .reportEvents])
    }

    func testReportAllAssociatedTextWithoutModifiers() {
        assertEncode(KittyKeyEvent(key: .unicode(97),
                                   modifiers: [],
                                   eventType: .press,
                                   text: "A",
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.reportAllKeys, .reportText],
                     expected: "\u{1b}[97;;65u")
    }

    func testReportAllAssociatedTextWithShift() {
        assertEncode(KittyKeyEvent(key: .unicode(97),
                                   modifiers: [.shift],
                                   eventType: .press,
                                   text: "A",
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.reportAllKeys, .reportText],
                     expected: "\u{1b}[97;2;65u")
    }

    func testAssociatedTextDropsControlCodes() {
        assertEncode(KittyKeyEvent(key: .unicode(97),
                                   modifiers: [],
                                   eventType: .press,
                                   text: "A\n",
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.reportAllKeys, .reportText],
                     expected: "\u{1b}[97;;65u")
    }

    func testReportAlternatesShiftedAndBase() {
        let shifted = "A".unicodeScalars.first!
        let baseLayout = "c".unicodeScalars.first!
        assertEncode(KittyKeyEvent(key: .unicode(97),
                                   modifiers: [.shift],
                                   eventType: .press,
                                   text: nil,
                                   shiftedKey: shifted,
                                   baseLayoutKey: baseLayout),
                     flags: [.disambiguate, .reportAlternates],
                     expected: "\u{1b}[97:65:99;2u")
    }

    func testReportAlternatesDoesNotChangeTextProducingKeys() {
        let shiftedASCII = KittyKeyEvent(key: .unicode(97),
                                         modifiers: [.shift],
                                         eventType: .press,
                                         text: "A",
                                         shiftedKey: "A".unicodeScalars.first,
                                         baseLayoutKey: nil)
        let shiftedItalian = KittyKeyEvent(key: .unicode(232),
                                           modifiers: [.shift],
                                           eventType: .press,
                                           text: "é",
                                           shiftedKey: "é".unicodeScalars.first,
                                           baseLayoutKey: "[".unicodeScalars.first)

        for flags: KittyKeyboardFlags in [
            [.disambiguate, .reportAlternates],
            [.disambiguate, .reportEvents, .reportAlternates]
        ] {
            assertEncode(shiftedASCII, flags: flags, expected: "A")
            assertEncode(shiftedItalian, flags: flags, expected: "é")
        }
    }

    func testMatchingUnshiftedCodepointWithTextRemainsText() {
        assertEncode(KittyKeyEvent(key: .unicode(65),
                                   modifiers: [.shift],
                                   eventType: .press,
                                   text: "A",
                                   shiftedKey: nil,
                                   baseLayoutKey: "a".unicodeScalars.first),
                     flags: [.disambiguate, .reportAlternates],
                     expected: "A")
    }

    func testReportAlternatesBaseOnly() {
        let baseLayout = "c".unicodeScalars.first!
        assertEncode(KittyKeyEvent(key: .unicode(97),
                                   modifiers: [],
                                   eventType: .press,
                                   text: nil,
                                   shiftedKey: nil,
                                   baseLayoutKey: baseLayout),
                     flags: [.disambiguate, .reportAlternates],
                     expected: "\u{1b}[97::99u")
    }

    func testReportAlternatesOmittedForControlPrimaryKey() {
        assertEncode(KittyKeyEvent(key: .unicode(13),
                                   modifiers: [.shift],
                                   eventType: .press,
                                   text: nil,
                                   shiftedKey: "A".unicodeScalars.first,
                                   baseLayoutKey: "a".unicodeScalars.first),
                     flags: [.disambiguate, .reportAlternates],
                     expected: "\u{1b}[13;2u")
    }

    func testReportAlternatesOmitPrimaryKeyDuplicates() {
        assertEncode(KittyKeyEvent(key: .unicode(97),
                                   modifiers: [.shift],
                                   eventType: .press,
                                   text: nil,
                                   shiftedKey: "a".unicodeScalars.first,
                                   baseLayoutKey: "a".unicodeScalars.first),
                     flags: [.disambiguate, .reportAlternates],
                     expected: "\u{1b}[97;2u")
    }

    func testReportAlternatesOmitBaseEqualToSingleTextScalar() {
        assertEncode(KittyKeyEvent(key: .unicode(233),
                                   modifiers: [],
                                   eventType: .press,
                                   text: "a",
                                   shiftedKey: nil,
                                   baseLayoutKey: "a".unicodeScalars.first),
                     flags: [.reportAllKeys, .reportAlternates, .reportText],
                     expected: "\u{1b}[233;;97u")
    }

    func testReportAlternatesOmitBaseForMultiScalarText() {
        assertEncode(KittyKeyEvent(key: .unicode(233),
                                   modifiers: [],
                                   eventType: .press,
                                   text: "e\u{301}",
                                   shiftedKey: nil,
                                   baseLayoutKey: "e".unicodeScalars.first),
                     flags: [.reportAllKeys, .reportAlternates, .reportText],
                     expected: "\u{1b}[233;;101:769u")
    }

    func testEnterWithAllFlagsUsesCsiU() {
        assertEncode(KittyKeyEvent(key: .functional(.enter),
                                   modifiers: [],
                                   eventType: .press,
                                   text: nil,
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate, .reportEvents, .reportAlternates, .reportAllKeys, .reportText],
                     expected: "\u{1b}[13u")
    }

    func testCtrlWithAllFlags() {
        assertEncode(KittyKeyEvent(key: .functional(.leftControl),
                                   modifiers: [.ctrl],
                                   eventType: .press,
                                   text: nil,
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate, .reportEvents, .reportAlternates, .reportAllKeys, .reportText],
                     expected: "\u{1b}[57442;5u")
    }

    func testCtrlReleaseWithCtrlModSet() {
        assertEncode(KittyKeyEvent(key: .functional(.leftControl),
                                   modifiers: [.ctrl],
                                   eventType: .release,
                                   text: nil,
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate, .reportEvents, .reportAlternates, .reportAllKeys, .reportText],
                     expected: "\u{1b}[57442;5:3u")
    }

    func testLeftShiftWithReportAll() {
        assertEncode(KittyKeyEvent(key: .functional(.leftShift),
                                   modifiers: [],
                                   eventType: .press,
                                   text: nil,
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate, .reportAllKeys],
                     expected: "\u{1b}[57441u")
    }

    func testLeftShiftWithoutReportAllIsSuppressed() {
        assertNoEncode(KittyKeyEvent(key: .functional(.leftShift),
                                     modifiers: [],
                                     eventType: .press,
                                     text: nil,
                                     shiftedKey: nil,
                                     baseLayoutKey: nil),
                       flags: [.disambiguate, .reportAlternates])
    }

    func testLockKeysFollowTheModifierRule() {
        // Caps Lock and Num Lock are modifiers: report-all-keys only.
        for key: KittyFunctionalKey in [.capsLock, .numLock] {
            assertNoEncode(KittyKeyEvent(key: .functional(key),
                                         modifiers: [],
                                         eventType: .press,
                                         text: nil,
                                         shiftedKey: nil,
                                         baseLayoutKey: nil),
                           flags: [.disambiguate])
        }
        assertEncode(KittyKeyEvent(key: .functional(.capsLock),
                                   modifiers: [],
                                   eventType: .press,
                                   text: nil,
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate, .reportAllKeys],
                     expected: "\u{1b}[57358u")
        // Scroll Lock is a regular functional key.
        assertEncode(KittyKeyEvent(key: .functional(.scrollLock),
                                   modifiers: [],
                                   eventType: .press,
                                   text: nil,
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate],
                     expected: "\u{1b}[57359u")
    }

    func testComposingWithNoModifierIsSuppressed() {
        assertNoEncode(KittyKeyEvent(key: .unicode(97),
                                     modifiers: [.shift],
                                     eventType: .press,
                                     text: nil,
                                     shiftedKey: nil,
                                     baseLayoutKey: nil,
                                     composing: true),
                       flags: [.disambiguate])
    }

    func testComposingWithModifierAndReportAllIsReported() {
        assertEncode(KittyKeyEvent(key: .functional(.leftShift),
                                   modifiers: [.shift],
                                   eventType: .press,
                                   text: nil,
                                   shiftedKey: nil,
                                   baseLayoutKey: nil,
                                   composing: true),
                     flags: [.disambiguate, .reportAllKeys],
                     expected: "\u{1b}[57441;2u")
    }

    func testEnterWithUtf8DeadKeyStateEmitsCommittedText() {
        assertEncode(KittyKeyEvent(key: .functional(.enter),
                                   modifiers: [],
                                   eventType: .press,
                                   text: "A",
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate, .reportAlternates, .reportAllKeys],
                     expected: "A")
    }

    func testBackspaceWithUtf8DeadKeyStateIsSuppressed() {
        assertNoEncode(KittyKeyEvent(key: .functional(.backspace),
                                     modifiers: [],
                                     eventType: .press,
                                     text: "A",
                                     shiftedKey: nil,
                                     baseLayoutKey: nil),
                       flags: [.disambiguate, .reportEvents, .reportAlternates, .reportAllKeys, .reportText])
    }

    func testDeleteWithControlUtf8StillUsesDeleteSequence() {
        assertEncode(KittyKeyEvent(key: .functional(.delete),
                                   modifiers: [],
                                   eventType: .press,
                                   text: "\u{7f}",
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate, .reportAlternates, .reportAllKeys],
                     expected: "\u{1b}[3~")
    }

    func testUpArrowWithControlUtf8StillUsesArrowSequence() {
        assertEncode(KittyKeyEvent(key: .functional(.up),
                                   modifiers: [],
                                   eventType: .press,
                                   text: "\u{1e}",
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate],
                     expected: "\u{1b}[A")
    }

    func testKeypadNumberIncludesAssociatedTextInReportAll() {
        assertEncode(KittyKeyEvent(key: .functional(.keypad1),
                                   modifiers: [],
                                   eventType: .press,
                                   text: "1",
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate, .reportEvents, .reportAlternates, .reportAllKeys, .reportText],
                     expected: "\u{1b}[57400;;49u")
    }

    func testAssociatedTextSuppressedByCtrlModifier() {
        assertEncode(KittyKeyEvent(key: .unicode(106),
                                   modifiers: [.ctrl],
                                   eventType: .press,
                                   text: "j",
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate, .reportAllKeys, .reportAlternates, .reportText],
                     expected: "\u{1b}[106;5u")
    }

    func testAssociatedTextOmittedOnRelease() {
        assertEncode(KittyKeyEvent(key: .unicode(106),
                                   modifiers: [.shift],
                                   eventType: .release,
                                   text: "J",
                                   shiftedKey: "J".unicodeScalars.first,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate, .reportAllKeys, .reportAlternates, .reportText, .reportEvents],
                     expected: "\u{1b}[106:74;2:3u")
    }

    func testReportAlternatesWithCapsLock() {
        assertEncode(KittyKeyEvent(key: .unicode(106),
                                   modifiers: [.capsLock],
                                   eventType: .press,
                                   text: "J",
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate, .reportAllKeys, .reportAlternates, .reportText],
                     expected: "\u{1b}[106;65;74u")
    }

    func testReportAlternatesColonShiftSemicolon() {
        assertEncode(KittyKeyEvent(key: .unicode(59),
                                   modifiers: [.shift],
                                   eventType: .press,
                                   text: ":",
                                   shiftedKey: ":".unicodeScalars.first,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate, .reportAllKeys, .reportAlternates, .reportText],
                     expected: "\u{1b}[59:58;2;58u")
    }

    func testReportAlternatesRuLayout() {
        assertEncode(KittyKeyEvent(key: .unicode(1095),
                                   modifiers: [],
                                   eventType: .press,
                                   text: "ч",
                                   shiftedKey: nil,
                                   baseLayoutKey: ";".unicodeScalars.first),
                     flags: [.disambiguate, .reportAllKeys, .reportAlternates, .reportText],
                     expected: "\u{1b}[1095::59;;1095u")
    }

    func testReportAlternatesRuLayoutShifted() {
        assertEncode(KittyKeyEvent(key: .unicode(1095),
                                   modifiers: [.shift],
                                   eventType: .press,
                                   text: "Ч",
                                   shiftedKey: "Ч".unicodeScalars.first,
                                   baseLayoutKey: ";".unicodeScalars.first),
                     flags: [.disambiguate, .reportAllKeys, .reportAlternates, .reportText],
                     expected: "\u{1b}[1095:1063:59;2;1063u")
    }

    func testReportAlternatesRuLayoutCapsLock() {
        assertEncode(KittyKeyEvent(key: .unicode(1095),
                                   modifiers: [.capsLock],
                                   eventType: .press,
                                   text: "Ч",
                                   shiftedKey: nil,
                                   baseLayoutKey: ";".unicodeScalars.first),
                     flags: [.disambiguate, .reportAllKeys, .reportAlternates, .reportText],
                     expected: "\u{1b}[1095::59;65;1063u")
    }

    func testReportAlternatesHuLayoutRelease() {
        assertEncode(KittyKeyEvent(key: .unicode(337),
                                   modifiers: [.ctrl],
                                   eventType: .release,
                                   text: nil,
                                   shiftedKey: nil,
                                   baseLayoutKey: "[".unicodeScalars.first),
                     flags: [.disambiguate, .reportAllKeys, .reportAlternates, .reportText, .reportEvents],
                     expected: "\u{1b}[337::91;5:3u")
    }

    func testF3UsesCsi13Tilde() {
        assertEncode(KittyKeyEvent(key: .functional(.f3),
                                   modifiers: [],
                                   eventType: .press,
                                   text: nil,
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate],
                     expected: "\u{1b}[13~")
    }

    func testKeypadBeginUsesKittyCodepoint() {
        assertEncode(KittyKeyEvent(key: .functional(.keypadBegin),
                                   modifiers: [],
                                   eventType: .press,
                                   text: nil,
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate],
                     expected: "\u{1b}[57427u")
    }

    func testCapsLockModifierIncludedForFunctionalKey() {
        assertEncode(KittyKeyEvent(key: .functional(.up),
                                   modifiers: [.capsLock],
                                   eventType: .press,
                                   text: nil,
                                   shiftedKey: nil,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate],
                     expected: "\u{1b}[1;65A")
    }

    func testLegacyFunctionCapabilitiesKf1ThroughKf63() {
        let baseKeys: [KittyFunctionalKey] = [
            .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12
        ]
        let groups: [(range: ClosedRange<Int>, modifiers: KittyKeyboardModifiers)] = [
            (1...12, []), (13...24, [.shift]), (25...36, [.ctrl]),
            (37...48, [.shift, .ctrl]), (49...60, [.alt]),
            (61...63, [.shift, .alt])
        ]

        func expected(base: Int, modifier: Int) -> String {
            if base <= 4 {
                let final = ["P", "Q", "R", "S"][base - 1]
                return modifier == 1 ? "\u{1b}O\(final)" : "\u{1b}[1;\(modifier)\(final)"
            }
            let number = [15, 17, 18, 19, 20, 21, 23, 24][base - 5]
            return modifier == 1 ? "\u{1b}[\(number)~" : "\u{1b}[\(number);\(modifier)~"
        }

        for group in groups {
            for capability in group.range {
                let base = ((capability - 1) % 12) + 1
                let event = KittyKeyEvent(key: .functional(baseKeys[base - 1]),
                                          modifiers: group.modifiers,
                                          eventType: .press,
                                          text: nil,
                                          shiftedKey: nil,
                                          baseLayoutKey: nil)
                let modifier = group.modifiers.rawValue + 1
                XCTAssertEqual(encode(event, flags: []),
                               Array(expected(base: base, modifier: modifier).utf8),
                               "kf\(capability)")
            }
        }
    }

    func testLegacyPhysicalF13ThroughF24UseMatchingCapabilities() {
        let keys: [KittyFunctionalKey] = [
            .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20, .f21, .f22, .f23, .f24
        ]
        let expected = [
            "\u{1b}[1;2P", "\u{1b}[1;2Q", "\u{1b}[1;2R", "\u{1b}[1;2S",
            "\u{1b}[15;2~", "\u{1b}[17;2~", "\u{1b}[18;2~", "\u{1b}[19;2~",
            "\u{1b}[20;2~", "\u{1b}[21;2~", "\u{1b}[23;2~", "\u{1b}[24;2~"
        ]
        for (key, sequence) in zip(keys, expected) {
            let event = KittyKeyEvent(key: .functional(key), modifiers: [], eventType: .press,
                                      text: nil, shiftedKey: nil, baseLayoutKey: nil)
            XCTAssertEqual(encode(event, flags: []), Array(sequence.utf8))
        }
    }

    func testLegacyNavigationModifierTableAndApplicationCursor() {
        let cases: [(KittyKeyboardModifiers, String)] = [
            ([], "\u{1b}[A"), ([.shift], "\u{1b}[1;2A"),
            ([.alt], "\u{1b}[1;3A"), ([.shift, .alt], "\u{1b}[1;4A"),
            ([.ctrl], "\u{1b}[1;5A"), ([.shift, .ctrl], "\u{1b}[1;6A"),
            ([.alt, .ctrl], "\u{1b}[1;7A")
        ]
        for (modifiers, expected) in cases {
            let event = KittyKeyEvent(key: .functional(.up), modifiers: modifiers,
                                      eventType: .press, text: nil,
                                      shiftedKey: nil, baseLayoutKey: nil)
            XCTAssertEqual(encode(event, flags: []), Array(expected.utf8))
        }
        let appEvent = KittyKeyEvent(key: .functional(.home), modifiers: [],
                                     eventType: .press, text: nil,
                                     shiftedKey: nil, baseLayoutKey: nil)
        XCTAssertEqual(encode(appEvent, flags: [], applicationCursor: true),
                       Array("\u{1b}OH".utf8))
    }

    func testEveryLegacyModifiedNavigationAndEditingCapability() {
        let keys: [(name: String, key: KittyFunctionalKey, prefix: String, final: String)] = [
            ("kUP", .up, "1", "A"), ("kDN", .down, "1", "B"),
            ("kRIT", .right, "1", "C"), ("kLFT", .left, "1", "D"),
            ("kHOM", .home, "1", "H"), ("kEND", .end, "1", "F"),
            ("kIC", .insert, "2", "~"), ("kDC", .delete, "3", "~"),
            ("kPRV", .pageUp, "5", "~"), ("kNXT", .pageDown, "6", "~")
        ]
        let modifiers: [(number: Int, value: KittyKeyboardModifiers)] = [
            (2, [.shift]), (3, [.alt]), (4, [.shift, .alt]),
            (5, [.ctrl]), (6, [.shift, .ctrl]), (7, [.alt, .ctrl])
        ]

        for keyCase in keys {
            for modifierCase in modifiers {
                let event = KittyKeyEvent(key: .functional(keyCase.key),
                                          modifiers: modifierCase.value,
                                          eventType: .press,
                                          text: nil,
                                          shiftedKey: nil,
                                          baseLayoutKey: nil)
                let expected = "\u{1b}[\(keyCase.prefix);\(modifierCase.number)\(keyCase.final)"
                XCTAssertEqual(encode(event, flags: []), Array(expected.utf8),
                               "\(keyCase.name)\(modifierCase.number == 2 ? "" : String(modifierCase.number))")
            }
        }
    }

    func testLegacyBaseEditingAndBacktabCapabilities() {
        let cases: [(KittyFunctionalKey, KittyKeyboardModifiers, String)] = [
            (.insert, [], "\u{1b}[2~"), (.delete, [], "\u{1b}[3~"),
            (.pageUp, [], "\u{1b}[5~"), (.pageDown, [], "\u{1b}[6~"),
            (.tab, [.shift], "\u{1b}[Z")
        ]
        for (key, modifiers, expected) in cases {
            let event = KittyKeyEvent(key: .functional(key), modifiers: modifiers,
                                      eventType: .press, text: nil,
                                      shiftedKey: nil, baseLayoutKey: nil)
            XCTAssertEqual(encode(event, flags: []), Array(expected.utf8))
        }
    }

    func testLegacyApplicationKeypadMapping() {
        let cases: [(KittyFunctionalKey, String, String)] = [
            (.keypad0, "0", "p"), (.keypad1, "1", "q"), (.keypad2, "2", "r"),
            (.keypad3, "3", "s"), (.keypad4, "4", "t"), (.keypad5, "5", "u"),
            (.keypad6, "6", "v"), (.keypad7, "7", "w"), (.keypad8, "8", "x"),
            (.keypad9, "9", "y"), (.keypadDecimal, ".", "n"),
            (.keypadDivide, "/", "o"), (.keypadMultiply, "*", "j"),
            (.keypadSubtract, "-", "m"), (.keypadAdd, "+", "k"),
            (.keypadEqual, "=", "X")
        ]
        for (key, text, final) in cases {
            let event = KittyKeyEvent(key: .functional(key), modifiers: [],
                                      eventType: .press, text: text,
                                      shiftedKey: nil, baseLayoutKey: nil)
            XCTAssertEqual(encode(event, flags: [], applicationKeypad: false),
                           Array(text.utf8))
            XCTAssertEqual(encode(event, flags: [], applicationKeypad: true),
                           Array("\u{1b}O\(final)".utf8))
        }
        let enter = KittyKeyEvent(key: .functional(.keypadEnter), modifiers: [],
                                  eventType: .press, text: nil,
                                  shiftedKey: nil, baseLayoutKey: nil)
        XCTAssertEqual(encode(enter, flags: [], applicationKeypad: false), [13])
        XCTAssertEqual(encode(enter, flags: [], applicationKeypad: true),
                       Array("\u{1b}OM".utf8))
    }

    func testLegacyRepeatReleaseAndLockFiltering() {
        let repeatEvent = KittyKeyEvent(key: .functional(.delete),
                                        modifiers: [.capsLock, .numLock, .ctrl],
                                        eventType: .repeatPress, text: nil,
                                        shiftedKey: nil, baseLayoutKey: nil)
        XCTAssertEqual(encode(repeatEvent, flags: []), Array("\u{1b}[3;5~".utf8))
        var releaseEvent = repeatEvent
        releaseEvent.eventType = .release
        XCTAssertNil(encode(releaseEvent, flags: []))
        var superEvent = repeatEvent
        superEvent.eventType = .press
        superEvent.modifiers = [.super]
        XCTAssertNil(encode(superEvent, flags: []))
        superEvent.modifiers = [.hyper]
        XCTAssertNil(encode(superEvent, flags: []))
        superEvent.modifiers = [.meta]
        XCTAssertNil(encode(superEvent, flags: []))
    }
}
#endif
