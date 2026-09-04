#if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
import Testing
@testable import SwiftTerm

struct IOSKittyInputPolicyTests {
    @Test func onlyReportAllAllowsModifiersDuringComposition() {
        #expect(IOSKittyInputPolicy.shouldReportModifierDuringComposition(
            key: .leftShift,
            flags: [.disambiguate, .reportAllKeys]))
        #expect(!IOSKittyInputPolicy.shouldReportModifierDuringComposition(
            key: .leftShift,
            flags: [.disambiguate]))
        #expect(!IOSKittyInputPolicy.shouldReportModifierDuringComposition(
            key: .pageUp,
            flags: [.disambiguate, .reportAllKeys]))
    }

    @Test func onlyPlainPageKeysScrollLocally() {
        #expect(IOSKittyInputPolicy.shouldScrollPageLocally(
            key: .pageUp, modifiers: [], applicationCursor: false))
        #expect(IOSKittyInputPolicy.shouldScrollPageLocally(
            key: .pageDown, modifiers: [], applicationCursor: false))

        for modifier: KittyKeyboardModifiers in [.shift, .alt, .ctrl, .super] {
            #expect(!IOSKittyInputPolicy.shouldScrollPageLocally(
                key: .pageUp, modifiers: modifier, applicationCursor: false))
        }

        #expect(!IOSKittyInputPolicy.shouldScrollPageLocally(
            key: .pageUp, modifiers: [], applicationCursor: true))
        #expect(!IOSKittyInputPolicy.shouldScrollPageLocally(
            key: .home, modifiers: [], applicationCursor: false))
    }

    @Test func repeatEventKeepsAlternateKeysAndText() {
        let source = KittyKeyEvent(
            key: .unicode(0x0444),
            modifiers: [.ctrl],
            eventType: .press,
            text: "ф",
            shiftedKey: UnicodeScalar(0x0424),
            baseLayoutKey: UnicodeScalar(0x66),
            composing: false)

        let repeatEvent = IOSKittyInputPolicy.repeatEvent(
            from: source, eventType: .repeatPress, composing: true)

        guard case let .unicode(codepoint) = repeatEvent.key else {
            Issue.record("Expected a Unicode key")
            return
        }
        #expect(codepoint == 0x0444)
        #expect(repeatEvent.modifiers == [.ctrl])
        #expect(repeatEvent.eventType == .repeatPress)
        #expect(repeatEvent.text == "ф")
        #expect(repeatEvent.shiftedKey == UnicodeScalar(0x0424))
        #expect(repeatEvent.baseLayoutKey == UnicodeScalar(0x66))
        #expect(repeatEvent.composing)
    }

    @Test func reportedPressesFinishOnlyTheMatchingKey() {
        var presses = IOSKittyReportedPresses<Int>()
        presses.record(4)
        presses.record(7)

        let finishedUnknown = presses.finish(9)
        let finishedFirst = presses.finish(4)
        let finishedFirstAgain = presses.finish(4)
        let finishedSecond = presses.finish(7)
        #expect(!finishedUnknown)
        #expect(finishedFirst)
        #expect(!finishedFirstAgain)
        #expect(finishedSecond)

        presses.record(11)
        presses.removeAll()
        let finishedAfterReset = presses.finish(11)
        #expect(!finishedAfterReset)
    }
}
#endif
