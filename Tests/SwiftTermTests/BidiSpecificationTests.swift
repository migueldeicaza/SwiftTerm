#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
struct BidiSpecificationTests {
    final class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private let delegate = Delegate()
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private func makeTerminal(_ text: String, cols: Int = 12,
                              state: BidiPresentationState = .default,
                              cap: Int = 512) -> Terminal {
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(
            cols: cols, rows: 5, initialBidiState: state,
            maximumBidiParagraphRows: cap))
        terminal.feed(text: text)
        return terminal
    }

    private func layout(_ terminal: Terminal, row: Int = 0) -> BidiRowLayout? {
        TerminalBidi.layout(row: row, buffer: terminal.buffer, cols: terminal.cols,
                            terminal: terminal, font: font, hostPolicy: .respectTerminal)
    }

    private func direction(_ terminal: Terminal, row: Int = 0) -> BidiDirection {
        TerminalBidi.resolvedBaseDirection(
            row: row, buffer: terminal.buffer, cols: terminal.cols,
            terminal: terminal, font: font, hostPolicy: .respectTerminal)
    }

    @Test func overCapRtlUsesExplicitCellOrderAndMatchingReport() throws {
        let terminal = makeTerminal("1234567", cols: 3,
            state: BidiPresentationState(autodetectDirection: false,
                                         fallbackDirection: .rightToLeft), cap: 2)
        #expect(terminal.buffer.lines[2].isWrapped)
        for row in 0...2 {
            let map = try #require(layout(terminal, row: row))
            #expect(direction(terminal, row: row) == .rightToLeft)
            #expect(map.baseDirection == direction(terminal, row: row))
            #expect(map.logicalToVisualCol == [2, 1, 0])
            #expect(map.visualToLogicalCol == [2, 1, 0])
            #expect(map.logicalDirections == [.rightToLeft, .rightToLeft, .rightToLeft])
            for logical in 0..<3 {
                #expect(map.visualToLogicalCol[map.logicalToVisualCol[logical]] == logical)
            }
        }
    }

    @Test func overCapAutodetectKeepsLogicalOrder() {
        let state = BidiPresentationState(autodetectDirection: true,
                                          fallbackDirection: .rightToLeft)
        for text in ["f(a){b}", "אב1234567"] {
            let terminal = makeTerminal(text, cols: 3, state: state, cap: 2)
            #expect(terminal.buffer.lines[2].isWrapped)
            for row in 0...2 {
                #expect(direction(terminal, row: row) == .leftToRight)
                #expect(layout(terminal, row: row) == nil)
            }
        }
    }

    // Icons and flags have the Bidi_Class L, but only letters set the
    // paragraph direction, in all Unicode planes.
    @Test(arguments: ["\u{F02A2}", "\u{E0B0}", "\u{1F1EE}\u{1F1F1}", "\u{F0001}", "\u{1F600}"])
    func symbolsDoNotSetTheParagraphDirection(prefix: String) {
        let state = BidiPresentationState(autodetectDirection: true,
                                          fallbackDirection: .leftToRight)
        #expect(direction(makeTerminal(prefix + " שלום", cols: 20, state: state)) == .rightToLeft)
        #expect(direction(makeTerminal(prefix + " abc", cols: 20, state: state)) == .leftToRight)
        let rtlFallback = BidiPresentationState(autodetectDirection: true,
                                                fallbackDirection: .rightToLeft)
        #expect(direction(makeTerminal(prefix, cols: 20, state: rtlFallback)) == .rightToLeft)
    }

    @Test(arguments: [BidiSupportMode.implicit, .explicit])
    func bracketMirroringPreservesCombiningMarks(mode: BidiSupportMode) throws {
        let terminal = makeTerminal("(\u{0301}אב)", state: BidiPresentationState(
            supportMode: mode, autodetectDirection: false, fallbackDirection: .rightToLeft))
        let map = try #require(layout(terminal))
        let open = try #require(map.visualCells.first { $0.logicalCol == 0 })
        let close = try #require(map.visualCells.first { $0.logicalCol == 3 })
        #expect(open.display == Character(")\u{0301}"))
        #expect(close.display == "(")
        #expect(terminal.buffer.lines[0].packedView(at: 0).getCharacter() == Character("(\u{0301}"))
    }

    @Test func supplementaryEuropeanDigitsKeepNumericOrder() throws {
        let terminal = makeTerminal("א𝟙𝟚")
        let map = try #require(layout(terminal))
        #expect(map.baseDirection == .rightToLeft)
        #expect(map.logicalToVisualCol[1] < map.logicalToVisualCol[2])
        #expect(map.logicalDirections[0] == .rightToLeft)
        #expect(map.logicalDirections[1] == .leftToRight)
        #expect(map.logicalDirections[2] == .leftToRight)
    }

    // These classes are from Unicode 17 DerivedBidiClass.txt.
    @Test(arguments: [UInt32(0x10900), 0x1EE00, 0x10400, 0x1F600, 0x10D30, 0x1D7D9])
    func supplementaryClassesAndAutomaticBaseDirection(scalar: UInt32) {
        let character = Character(String(UnicodeScalar(scalar)!))
        let probe: UInt16
        let strong: BidiDirection?
        switch scalar {
        case 0x10900: probe = 0x05D0; strong = .rightToLeft // Phoenician: R
        case 0x1EE00: probe = 0x0621; strong = .rightToLeft // Arabic mathematical alef: AL
        case 0x10400: probe = 0x0041; strong = .leftToRight // Deseret long I: L
        case 0x1F600: probe = 0x00B7; strong = nil // Grinning face: ON
        case 0x10D30: probe = 0x0660; strong = nil // Rohingya zero: AN
        default: probe = 0x0030; strong = nil // Double-struck one: EN
        }
        #expect(TerminalBidi.probeScalar(for: character) == probe)
        #expect(TerminalBidi.isRTLTrigger(scalar) == (strong == .rightToLeft))
        for fallback in [BidiDirection.leftToRight, .rightToLeft] {
            let state = BidiPresentationState(autodetectDirection: true,
                                              fallbackDirection: fallback)
            #expect(direction(makeTerminal(String(character), state: state)) == (strong ?? fallback))
            #expect(direction(makeTerminal(String(character) + "א", state: state)) == (strong ?? .rightToLeft))
        }
    }

    @Test(arguments: [BidiPresentationMode.implicitLeftToRight, .implicitRightToLeft,
                      .implicitAutoLeftToRight, .implicitAutoRightToLeft,
                      .explicitLeftToRight, .explicitRightToLeft])
    func sixModesKeepTheirNeutralRowOrder(mode: BidiPresentationMode) throws {
        let explicitMode = mode == .explicitLeftToRight || mode == .explicitRightToLeft
        let rtl = mode == .implicitRightToLeft || mode == .implicitAutoRightToLeft
            || mode == .explicitRightToLeft
        let auto = mode == .implicitAutoLeftToRight || mode == .implicitAutoRightToLeft
        let state = BidiPresentationState(supportMode: explicitMode ? .explicit : .implicit,
                                         autodetectDirection: auto,
                                         fallbackDirection: rtl ? .rightToLeft : .leftToRight)
        #expect(state.presentationMode == mode)
        let terminal = makeTerminal("12 34", cols: 8, state: state)
        #expect(direction(terminal) == state.fallbackDirection)
        let map = layout(terminal)
        if rtl {
            let map = try #require(map)
            let visible = map.visualCells.map { cell in
                let source = terminal.buffer.lines[0].packedView(at: cell.logicalCol)
                return String(cell.display ?? (source.code == 0 ? " " : source.getCharacter()))
            }.joined()
            #expect(visible == (explicitMode ? "   43 21" : "   34 12"))
        } else {
            #expect(map == nil)
        }
    }

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

    // The arrow-key resolver must give the direction that the renderer draws.
    @Test(arguments: [BidiPresentationMode.implicitLeftToRight, .implicitRightToLeft,
                      .implicitAutoLeftToRight, .implicitAutoRightToLeft,
                      .explicitLeftToRight, .explicitRightToLeft])
    func portableResolverMatchesTheRenderer(mode: BidiPresentationMode) {
        let explicitMode = mode == .explicitLeftToRight || mode == .explicitRightToLeft
        let rtl = mode == .implicitRightToLeft || mode == .implicitAutoRightToLeft
            || mode == .explicitRightToLeft
        let auto = mode == .implicitAutoLeftToRight || mode == .implicitAutoRightToLeft
        let state = BidiPresentationState(supportMode: explicitMode ? .explicit : .implicit,
                                         autodetectDirection: auto,
                                         fallbackDirection: rtl ? .rightToLeft : .leftToRight)
        let texts = [
            "", "abc", "שלום", "مرحبا بالعالم", "123 שלום abc", "(abc) מרחבא",
            "12 34", "\u{1F600} שלום", "\u{1F1EE}\u{1F1F1} abc",
            "\u{F02A2}\u{E0B0}", "\u{10900}\u{10901}", "\u{1EE00} abc", "\u{10400} שלום",
            "\u{1D7D9}\u{10D30} abc", "שָׁלוֹם 🙂", "a界b", "1234567 שלום", "abcdefgh\r\nשלום",
            "שלום\r\n\r\nabc", "\u{1b}[2 k12\u{1b}[0 k34",
        ]
        for text in texts {
            for (cols, cap) in [(12, 512), (4, 512), (4, 2), (3, 1)] {
                let terminal = makeTerminal(text, cols: cols, state: state, cap: cap)
                for row in 0..<terminal.buffer.lines.count {
                    let portable = TerminalBidi.baseDirection(
                        row: row, buffer: terminal.buffer, cols: terminal.cols,
                        maximumRows: cap, hostPolicy: .respectTerminal)
                    #expect(portable == direction(terminal, row: row),
                            "\(text.debugDescription) cols \(cols) cap \(cap) row \(row)")
                    #expect(TerminalBidi.baseDirection(
                        row: row, buffer: terminal.buffer, cols: terminal.cols,
                        maximumRows: cap, hostPolicy: .legacyLeftToRight)
                            == TerminalBidi.resolvedBaseDirection(
                                row: row, buffer: terminal.buffer, cols: terminal.cols,
                                terminal: terminal, font: font, hostPolicy: .legacyLeftToRight))
                }
            }
        }
    }

    @Test func portableResolverMatchesTheRendererWithImages() {
        let state = BidiPresentationState(autodetectDirection: true, fallbackDirection: .rightToLeft)
        for (text, images) in [("שabc", [Image(0, 1)]), ("aשלום", [Image(0, 1)]),
                               ("", [Image(2, 3)]), ("ab界שלום", [Image(3, 1)]),
                               ("abשלום", [Image(0, 2), Image(1, 3)])] {
            let terminal = makeTerminal(text, cols: 12, state: state)
            terminal.buffer.lines[0].images = images
            let portable = TerminalBidi.baseDirection(
                row: 0, buffer: terminal.buffer, cols: terminal.cols,
                maximumRows: 512, hostPolicy: .respectTerminal)
            #expect(portable == direction(terminal), "\(text.debugDescription)")
        }
    }
}
#endif
