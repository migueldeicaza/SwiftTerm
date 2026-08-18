import Testing

@testable import SwiftTerm

struct TerminfoTerminalTests {
    private let esc = "\u{1b}"

    @Test func xtversionAcceptsOnlyTheTwoSpecifiedRequests() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        let identity = Terminal.xtVersionIdentity(tag: SwiftTermBuildInfo.tag,
                                                  branch: SwiftTermBuildInfo.branch,
                                                  version: SwiftTermBuildInfo.version)
        let expected = Array("\u{1b}P>|\(identity)\u{1b}\\".utf8)

        terminal.feed(text: "\(esc)[>q")
        #expect(delegate.sentData.last == expected)
        delegate.clearSentData()
        terminal.feed(text: "\(esc)[>0q")
        #expect(delegate.sentData.last == expected)

        for invalid in ["\(esc)[>1q", "\(esc)[>0;0q", "\(esc)[>0 q"] {
            delegate.clearSentData()
            terminal.feed(text: invalid)
            #expect(delegate.sentData.isEmpty)
        }
    }

    @Test func xtversionAlwaysUsesSevenBitDcsFraming() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc) G")
        terminal.feed(text: "\(esc)[>0q")
        let response = delegate.sentData.last ?? []
        #expect(Array(response.prefix(2)) == [0x1b, 0x50])
        #expect(Array(response.suffix(2)) == [0x1b, 0x5c])
    }

    @Test func xtversionIdentityFormatting() {
        #expect(Terminal.xtVersionIdentity(tag: "v1.2.3", branch: "main",
                                           version: "v1.2.3-modified")
                == "SwiftTerm 1.2.3-main+v1.2.3-modified:")
        #expect(Terminal.xtVersionIdentity(tag: nil, branch: "feature", version: "abc123")
                == "SwiftTerm-feature+abc123:")
        #expect(Terminal.xtVersionIdentity(tag: "v1.2.3", branch: nil, version: "v1.2.3")
                == "SwiftTerm 1.2.3+v1.2.3:")
        #expect(Terminal.xtVersionIdentity(tag: nil, branch: nil, version: "unknown")
                == "SwiftTerm:")
        #expect(Terminal.xtVersionIdentity(tag: "v", branch: "", version: nil)
                == "SwiftTerm:")
        #expect(Terminal.xtVersionIdentity(tag: nil, branch: nil, version: "abc123")
                == "SwiftTerm+abc123:")
        #expect(Terminal.xtVersionIdentity(tag: "release", branch: nil, version: "unknown")
                == "SwiftTerm release:")
        #expect(Terminal.xtVersionIdentity(tag: "Vv1\n.é2", branch: "\u{1}maïn",
                                           version: "unknown")
                == "SwiftTerm Vv1.2-man:")

        let long = Terminal.xtVersionIdentity(tag: String(repeating: "a", count: 400),
                                              branch: "branch", version: "version")
        #expect(long.utf8.count == 256)
        #expect(long.hasPrefix("SwiftTerm"))
        #expect(long.hasSuffix(":"))
    }

    @Test func reverseScreenModeTracksStateWithoutChangingCellsOrCurrentAttributes() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 8, rows: 2)
        terminal.feed(text: "\(esc)[31;44mA")
        let storedAttribute = terminal.buffer.lines[terminal.buffer.yDisp][0].attribute

        terminal.feed(text: "\(esc)[?5h")
        #expect(terminal.reverseColors)
        #expect(terminal.buffer.lines[terminal.buffer.yDisp][0].attribute == storedAttribute)
        terminal.feed(text: "B")
        #expect(terminal.buffer.lines[terminal.buffer.yDisp][1].attribute == storedAttribute)

        delegate.clearSentData()
        terminal.feed(text: "\(esc)[?5$p")
        #expect(delegate.sentData.last == Array("\u{1b}[?5;1$y".utf8))

        terminal.feed(text: "\(esc)[?5l")
        #expect(!terminal.reverseColors)
        terminal.feed(text: "C")
        #expect(terminal.buffer.lines[terminal.buffer.yDisp][2].attribute == storedAttribute)
        delegate.clearSentData()
        terminal.feed(text: "\(esc)[?5$p")
        #expect(delegate.sentData.last == Array("\u{1b}[?5;2$y".utf8))
    }

    @Test func fullResetClearsReverseScreenMode() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?5h")
        #expect(terminal.reverseColors)
        terminal.feed(text: "\(esc)c")
        #expect(!terminal.reverseColors)
    }

    @Test func flashCapabilityReversesAndRestoresScreen() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[?5h")
        #expect(terminal.reverseColors)
        terminal.feed(text: "\(esc)[?5l")
        #expect(!terminal.reverseColors)
    }
}

#if os(macOS)
import AppKit

@MainActor
struct TerminfoRendererTests {
    @Test func reverseModeSwapsOnlyEffectiveDefaultColors() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 160, height: 40))
        view.nativeForegroundColor = .red
        view.nativeBackgroundColor = .blue
        // mapColor/getAttributes read terminal state, so they must run under
        // the terminal lock (they precondition on it).
        let (ansiBefore, rgbBefore) = view.withTerminal { _ in
            (view.mapColor(color: .ansi256(code: 1), isFg: true, isBold: false),
             view.mapColor(color: .trueColor(red: 1, green: 2, blue: 3),
                           isFg: true, isBold: false))
        }
        #expect(view.withTerminal { _ in view.mapColor(color: .defaultColor, isFg: true, isBold: false) } == .red)
        #expect(view.withTerminal { _ in view.effectiveCaretColor } == .red)
        #expect(view.withTerminal { _ in view.effectiveCaretTextColor } == .blue)

        view.feed(text: "\u{1b}[?5h")
        view.withTerminal { _ in
            #expect(view.mapColor(color: .defaultColor, isFg: true, isBold: false) == .blue)
            #expect(view.mapColor(color: .defaultColor, isFg: false, isBold: false) == .red)
            #expect(view.mapColor(color: .ansi256(code: 1), isFg: true, isBold: false) == ansiBefore)
            #expect(view.mapColor(color: .trueColor(red: 1, green: 2, blue: 3),
                                  isFg: true, isBold: false) == rgbBefore)
        }
        #expect(view.withTerminal { _ in view.effectiveCaretColor } == .blue)
        #expect(view.withTerminal { _ in view.effectiveCaretTextColor } == .red)

        let inverseDefaults = Attribute(fg: .defaultColor, bg: .defaultColor,
                                        style: .inverse)
        let inverseAttributes = try #require(view.withTerminal { _ in view.getAttributes(inverseDefaults, withUrl: false) })
        #expect(inverseAttributes[.foregroundColor] as? NSColor == .red)
        #expect(inverseAttributes[.backgroundColor] as? NSColor == .blue)

        view.caretColor = .green
        view.caretTextColor = .yellow
        #expect(view.withTerminal { _ in view.effectiveCaretColor } == .green)
        #expect(view.withTerminal { _ in view.effectiveCaretTextColor } == .yellow)
    }

    @Test func hiddenBlinkPhaseKeepsBackgroundAndRemovesTextDecorations() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 160, height: 40))
        view.feed(text: "\u{1b}[5;4;9;44mA")
        view.setTextBlinkVisibleForTesting(false)
        let rendered = view.withTerminal { terminal in
            let row = terminal.displayBuffer.yDisp
            let line = terminal.displayBuffer.lines[row]
            return view.buildAttributedStringLocked(row: row, line: line,
                                                    cols: terminal.cols)
        }
        let segment = try #require(rendered.segments.first)
        #expect(segment.attributedString.string.first == " ")
        let attributes = segment.attributedString.attributes(at: 0, effectiveRange: nil)
        #expect(attributes[.backgroundColor] != nil)
        #expect(attributes[.underlineStyle] == nil)
        #expect(attributes[.strikethroughStyle] == nil)
    }

    @Test func blinkTimerStopsWhenViewDetachesOrApplicationIsInactive() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 160, height: 40))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        view.textBlinkApplicationActive = true
        view.feed(text: "\u{1b}[5mA")
        view.updateTextBlinkLifecycle()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(view.textBlinkTimer == nil)
        } else {
            #expect(view.textBlinkTimer != nil)
        }

        view.textBlinkApplicationActive = false
        view.updateTextBlinkLifecycle()
        #expect(view.textBlinkTimer == nil)
        #expect(view.textBlinkVisible)

        view.textBlinkApplicationActive = true
        window.contentView = nil
        view.updateTextBlinkLifecycle()
        #expect(view.textBlinkTimer == nil)
    }
}
#endif
