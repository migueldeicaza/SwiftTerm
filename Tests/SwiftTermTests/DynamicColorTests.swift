import Testing
@testable import SwiftTerm

struct DynamicColorTests {
    private final class Delegate: TerminalDelegate {
        var sent: [[UInt8]] = []
        var changes: [(TerminalDynamicColor, Color?)] = []
        var defaults: [TerminalDynamicColor: Color] = [:]

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            sent.append(Array(data))
        }

        func setDynamicColor(source: Terminal, target: TerminalDynamicColor, color: Color?) {
            changes.append((target, color))
        }

        func getDynamicColor(source: Terminal, target: TerminalDynamicColor) -> Color? {
            defaults[target]
        }
    }

    private func reply(_ target: TerminalDynamicColor, _ color: Color, terminator: String = "\u{07}") -> [UInt8] {
        Array("\u{1b}]\(target.oscCode);\(color.formatAsXcolor())\(terminator)".utf8)
    }

    @Test(arguments: TerminalDynamicColor.allCases)
    func setAndQuery(target: TerminalDynamicColor) {
        for terminator in ["\u{07}", "\u{1b}\\"] {
            let delegate = Delegate()
            let terminal = Terminal(delegate: delegate)
            let color = Color(red: 0x1234, green: 0x5678, blue: 0x9abc)

            terminal.feed(text: "\u{1b}]\(target.oscCode);rgb:1234/5678/9abc\(terminator)")
            #expect(terminal.dynamicColor(target) == color)
            #expect(delegate.changes.count == 1)
            #expect(delegate.changes.first?.0 == target)
            #expect(delegate.changes.first?.1 == color)

            terminal.feed(text: "\u{1b}]\(target.oscCode);?\(terminator)")
            // The reply uses the same terminator as the request.
            #expect(delegate.sent == [reply(target, color, terminator: terminator)])
            #expect(delegate.changes.count == 1)
        }
    }

    @Test(arguments: TerminalDynamicColor.allCases)
    func defaultsAndExplicitOverride(target: TerminalDynamicColor) {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        let foreground = Color(red: 0x1111, green: 0x2222, blue: 0x3333)
        let background = Color(red: 0x4444, green: 0x5555, blue: 0x6666)
        terminal.foregroundColor = foreground
        terminal.backgroundColor = background

        terminal.feed(text: "\u{1b}]\(target.oscCode);?\u{07}")
        let fallback = target.defaultsToBackground ? background : foreground
        #expect(delegate.sent == [reply(target, fallback)])
        #expect(terminal.dynamicColor(target) == nil)

        let hostDefault = Color(red8: 0x12, green8: 0x34, blue8: 0x56)
        delegate.defaults[target] = hostDefault
        terminal.feed(text: "\u{1b}]\(target.oscCode);?\u{07}")
        #expect(delegate.sent.last == reply(target, hostDefault))

        let explicit = Color(red8: 0xab, green8: 0xcd, blue8: 0xef)
        terminal.feed(text: "\u{1b}]\(target.oscCode);#abcdef\u{07}")
        terminal.feed(text: "\u{1b}]\(target.oscCode);?\u{07}")
        #expect(delegate.sent.last == reply(target, explicit))
    }

    @Test func multipleColorsKeepOscPositions() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: "\u{1b}]10;#010101;#020202;#030303;#040404;#050505;#060606;#070707;#080808;#090909;#0a0a0a;#ffffff\u{07}")

        #expect(terminal.foregroundColor == Color(red8: 1, green8: 1, blue8: 1))
        #expect(terminal.backgroundColor == Color(red8: 2, green8: 2, blue8: 2))
        #expect(terminal.cursorColor == Color(red8: 3, green8: 3, blue8: 3))
        #expect(delegate.changes.map { $0.0 } == TerminalDynamicColor.allCases)
        for target in TerminalDynamicColor.allCases {
            let value = UInt16(target.oscCode - 9)
            #expect(terminal.dynamicColor(target) == Color(red8: value, green8: value, blue8: value))
        }

        terminal.feed(text: "\u{1b}]13;?;?;?;?;?;?;?;?\u{07}")
        #expect(delegate.sent == TerminalDynamicColor.allCases.map { target in
            let value = UInt16(target.oscCode - 9)
            return reply(target, Color(red8: value, green8: value, blue8: value))
        })
    }

    @Test(arguments: TerminalDynamicColor.allCases)
    func oscResetRestoresHostDefault(target: TerminalDynamicColor) {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        let hostDefault = Color(red8: 0x12, green8: 0x34, blue8: 0x56)
        delegate.defaults[target] = hostDefault

        terminal.feed(text: "\u{1b}]\(target.oscCode);#abcdef\u{07}")
        terminal.feed(text: "\u{1b}]\(target.oscCode + 100)\u{07}")
        #expect(terminal.dynamicColor(target) == nil)
        #expect(delegate.changes.count == 2)
        #expect(delegate.changes.last?.0 == target)
        #expect(delegate.changes.last?.1 == nil)

        terminal.feed(text: "\u{1b}]\(target.oscCode);?\u{07}")
        #expect(delegate.sent == [reply(target, hostDefault)])

        // A reset without a stored color does not notify the host.
        terminal.feed(text: "\u{1b}]\(target.oscCode + 100)\u{07}")
        #expect(delegate.changes.count == 2)
    }

    @Test func fullResetClearsDynamicColors() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: "\u{1b}]13;#010101;#020202\u{07}")
        terminal.feed(text: "\u{1b}c")
        for target in TerminalDynamicColor.allCases {
            #expect(terminal.dynamicColor(target) == nil)
        }
        let resets = delegate.changes.filter { $0.1 == nil }.map { $0.0 }
        #expect(Set(resets) == [.pointerForeground, .pointerBackground])
        #expect(resets.count == 2)
    }

    @Test func hostCanResetDynamicColor() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: "\u{1b}]17;#123456\u{07}")
        terminal.resetDynamicColor(.highlightBackground)
        #expect(terminal.dynamicColor(.highlightBackground) == nil)
        #expect(delegate.changes.last?.1 == nil)
    }

    @Test func listStartingAtTektronixReachesHighlight() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: "\u{1b}]16;#000000;#ff0000\u{07}")
        #expect(terminal.dynamicColor(.tektronixBackground) == Color(red8: 0, green8: 0, blue8: 0))
        #expect(terminal.dynamicColor(.highlightBackground) == Color(red8: 0xff, green8: 0, blue8: 0))
    }

    @Test func mixedSetAndQueryUsesCurrentColors() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: "\u{1b}]10;#123456;?;?;?\u{07}")
        let color = Color(red8: 0x12, green8: 0x34, blue8: 0x56)
        #expect(delegate.sent.count == 3)
        #expect(delegate.sent.last == reply(.pointerForeground, color))
    }

    @Test func invalidColorStopsFollowingChanges() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: "\u{1b}]17;#123456;invalid;#abcdef\u{07}")
        #expect(terminal.dynamicColor(.highlightBackground) == Color(red8: 0x12, green8: 0x34, blue8: 0x56))
        #expect(terminal.dynamicColor(.tektronixCursor) == nil)
        #expect(terminal.dynamicColor(.highlightForeground) == nil)
        #expect(delegate.changes.count == 1)

        terminal.feed(text: "\u{1b}]13;?invalid;#abcdef\u{07}")
        #expect(delegate.sent.isEmpty)
        #expect(terminal.dynamicColor(.pointerBackground) == nil)
    }

    @Test func emptyFieldsMatchGhosttyTokenOrder() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: "\u{1b}]13;;#123456;;#abcdef;\u{07}")
        #expect(terminal.dynamicColor(.pointerForeground) == Color(red8: 0x12, green8: 0x34, blue8: 0x56))
        #expect(terminal.dynamicColor(.pointerBackground) == Color(red8: 0xab, green8: 0xcd, blue8: 0xef))
    }

    @Test(arguments: TerminalDynamicColor.allCases)
    func fragmentedInputWithoutDelegate(target: TerminalDynamicColor) {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.tdel = nil
        for byte in "\u{1b}]\(target.oscCode);#123456\u{1b}\\".utf8 {
            terminal.feed(byteArray: [byte])
        }
        #expect(terminal.dynamicColor(target) == Color(red8: 0x12, green8: 0x34, blue8: 0x56))
    }
}

#if os(macOS)
import AppKit

@MainActor
@Suite(.serialized)
struct DynamicColorViewTests {
    private final class Delegate: TerminalViewDelegate {
        var sent: [[UInt8]] = []
        var changes: [(TerminalDynamicColor, Color?)] = []

        func dynamicColorChanged(source: TerminalView, target: TerminalDynamicColor, color: Color?) {
            changes.append((target, color))
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            sent.append(Array(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    private func waitForReplies(_ count: Int, from delegate: Delegate) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while delegate.sent.count < count, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(delegate.sent.count == count)
    }

    @Test func queriesUseConfiguredSelectionColors() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let delegate = Delegate()
        view.terminalDelegate = delegate
        let background = Color(red8: 0x12, green8: 0x34, blue8: 0x56)
        let foreground = Color(red8: 0xab, green8: 0xcd, blue8: 0xef)
        view.selectedTextBackgroundColor = NSColor.make(color: background)
        view.selectedTextForegroundColor = NSColor.make(color: foreground)

        view.feed(text: "\u{1b}]17;?\u{07}\u{1b}]19;?\u{07}")
        await waitForReplies(2, from: delegate)
        #expect(delegate.sent == [
            Array("\u{1b}]17;\(background.formatAsXcolor())\u{07}".utf8),
            Array("\u{1b}]19;\(foreground.formatAsXcolor())\u{07}".utf8)
        ])
    }

    private func waitForMain(until condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
    }

    @Test func oscSelectionColorsKeepConfiguredColors() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let delegate = Delegate()
        view.terminalDelegate = delegate
        let configured = NSColor.systemBlue.withAlphaComponent(0.3)
        view.selectedTextBackgroundColor = configured

        view.feed(text: "\u{1b}]17;#123456\u{07}")
        await waitForMain { view.oscSelectedTextBackgroundColor != nil }
        #expect(view.selectedTextBackgroundColor === configured)
        #expect(view.effectiveSelectedTextBackgroundColor.getTerminalColor() == Color(red8: 0x12, green8: 0x34, blue8: 0x56))

        // A host theme change does not replace the application color, so the
        // query reports the color that the view draws.
        view.selectedTextBackgroundColor = .systemPurple
        view.feed(text: "\u{1b}]17;?\u{07}")
        await waitForReplies(1, from: delegate)
        #expect(delegate.sent.last == Array("\u{1b}]17;rgb:1212/3434/5656\u{07}".utf8))

        view.resetDynamicColor(.highlightBackground)
        await waitForMain { view.oscSelectedTextBackgroundColor == nil }
        #expect(view.effectiveSelectedTextBackgroundColor === view.selectedTextBackgroundColor)
    }

    @Test func viewDelegateReceivesDynamicColors() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let delegate = Delegate()
        view.terminalDelegate = delegate
        view.feed(text: "\u{1b}]13;#123456\u{07}\u{1b}]113\u{07}")
        await waitForMain { delegate.changes.count == 2 }
        #expect(delegate.changes.map { $0.0 } == [.pointerForeground, .pointerForeground])
        #expect(delegate.changes.first?.1 == Color(red8: 0x12, green8: 0x34, blue8: 0x56))
        #expect(delegate.changes.last?.1 == nil)
    }

    @Test func queryAfterSetUsesNewForeground() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let delegate = Delegate()
        view.terminalDelegate = delegate
        view.nativeForegroundColor = .white
        view.nativeBackgroundColor = .black

        let sender = view.feedSender
        await Task.detached {
            sender.feed(text: "\u{1b}]10;#123456\u{07}\u{1b}]13;?\u{07}")
        }.value
        await waitForReplies(1, from: delegate)
        #expect(delegate.sent == [Array("\u{1b}]13;rgb:1212/3434/5656\u{07}".utf8)])
    }

    @Test func selectionQueryFollowsAppearance() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let delegate = Delegate()
        view.terminalDelegate = delegate
        let light = Color(red8: 0x11, green8: 0x22, blue8: 0x33)
        let dark = Color(red8: 0xaa, green8: 0xbb, blue8: 0xcc)
        view.appearance = NSAppearance(named: .aqua)
        view.selectedTextBackgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.make(color: dark) : NSColor.make(color: light)
        }

        view.feed(text: "\u{1b}]17;?\u{07}")
        await waitForReplies(1, from: delegate)
        #expect(delegate.sent.last == Array("\u{1b}]17;\(light.formatAsXcolor())\u{07}".utf8))

        view.appearance = NSAppearance(named: .darkAqua)
        view.viewDidChangeEffectiveAppearance()
        view.feed(text: "\u{1b}]17;?\u{07}")
        await waitForReplies(2, from: delegate)
        #expect(delegate.sent.last == Array("\u{1b}]17;\(dark.formatAsXcolor())\u{07}".utf8))
    }

    @Test func backgroundFeedUpdatesSelectionAndReportsExplicitColors() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let delegate = Delegate()
        view.terminalDelegate = delegate

        let sender = view.feedSender
        await Task.detached {
            sender.feed(text: "\u{1b}]17;#123456;#abcdef;#fedcba\u{07}\u{1b}]17;?;?;?\u{07}")
        }.value
        await waitForReplies(3, from: delegate)

        await waitForMain { view.oscSelectedTextForegroundColor != nil }
        #expect(view.effectiveSelectedTextBackgroundColor.getTerminalColor() == Color(red8: 0x12, green8: 0x34, blue8: 0x56))
        #expect(view.effectiveSelectedTextForegroundColor.getTerminalColor() == Color(red8: 0xfe, green8: 0xdc, blue8: 0xba))
        #expect(delegate.sent == [
            Array("\u{1b}]17;rgb:1212/3434/5656\u{07}".utf8),
            Array("\u{1b}]18;rgb:abab/cdcd/efef\u{07}".utf8),
            Array("\u{1b}]19;rgb:fefe/dcdc/baba\u{07}".utf8)
        ])
    }
}
#endif
