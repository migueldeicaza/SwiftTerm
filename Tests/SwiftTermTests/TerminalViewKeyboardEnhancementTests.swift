#if os(macOS)
import Foundation
import Testing
@testable import SwiftTerm

@Suite("TerminalView keyboard enhancement flags")
struct TerminalViewKeyboardEnhancementTests {
    /// The view parses a feed on its I/O thread, so read the copied value until it settles.
    @MainActor
    private func flags(_ view: TerminalView,
                       equal expected: KittyKeyboardFlags,
                       within seconds: TimeInterval = 2) -> KittyKeyboardFlags {
        let deadline = Date(timeIntervalSinceNow: seconds)
        var seen = view.keyboardEnhancementFlags
        while seen != expected, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            seen = view.keyboardEnhancementFlags
        }
        return seen
    }

    @MainActor
    @Test func viewReportsFlagsTheApplicationPushedAndPopped() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 640, height: 320)))
        #expect(view.keyboardEnhancementFlags.isEmpty)

        // CSI > 1 u — push, the form an application uses when it takes over key encoding.
        view.feed(text: "\u{1b}[>1u")
        #expect(flags(view, equal: .disambiguate) == .disambiguate)

        // CSI < 1 u — pop, restoring what the host saw before.
        view.feed(text: "\u{1b}[<1u")
        #expect(flags(view, equal: []).isEmpty)
    }

    @MainActor
    @Test func viewReportsFlagsTheApplicationSet() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 640, height: 320)))
        let expected: KittyKeyboardFlags = [.disambiguate, .reportEvents]

        // CSI = 3 ; 1 u — set flags outright.
        view.feed(text: "\u{1b}[=3;1u")
        #expect(flags(view, equal: expected) == expected)
    }
}
#endif
