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
}
#endif
