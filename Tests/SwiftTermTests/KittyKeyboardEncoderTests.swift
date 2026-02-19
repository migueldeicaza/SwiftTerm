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
                        backspaceSendsControlH: Bool = false) -> [UInt8]? {
        let encoder = KittyKeyboardEncoder(flags: flags,
                                           applicationCursor: applicationCursor,
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

    func testShiftAOnUsKeyboardWithReportAlternates() {
        assertEncode(KittyKeyEvent(key: .unicode(97),
                                   modifiers: [.shift],
                                   eventType: .press,
                                   text: "A",
                                   shiftedKey: "A".unicodeScalars.first,
                                   baseLayoutKey: nil),
                     flags: [.disambiguate, .reportAlternates],
                     expected: "\u{1b}[97:65;2u")
    }

    func testMatchingUnshiftedCodepointUsesBaseAlternate() {
        assertEncode(KittyKeyEvent(key: .unicode(65),
                                   modifiers: [.shift],
                                   eventType: .press,
                                   text: "A",
                                   shiftedKey: nil,
                                   baseLayoutKey: "a".unicodeScalars.first),
                     flags: [.disambiguate, .reportAlternates],
                     expected: "\u{1b}[65::97;2u")
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
}
#endif
