import Testing
@testable import SwiftTerm

private final class MousePointerDelegate: TerminalDelegate {
    var supported = MousePointerShape.allCases
    var responses: [String] = []
    var changes: [MousePointerShape?] = []

    func supportedMousePointerShapes(source: Terminal) -> [MousePointerShape] { supported }
    func mousePointerShapeChanged(source: Terminal) { changes.append(source.mousePointerShape) }
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        responses.append(String(decoding: data, as: UTF8.self))
    }
}

struct MousePointerShapeTests {
    private let esc = "\u{1b}"

    private func makeTerminal() -> (Terminal, MousePointerDelegate) {
        let delegate = MousePointerDelegate()
        return (Terminal(delegate: delegate), delegate)
    }

    @Test func queriesReportOnlyShapesImplementedByTheHost() {
        let (terminal, delegate) = makeTerminal()
        terminal.feed(text: "\(esc)]22;?none,text,pointer,crosshair,default,unknown\(esc)\\")
        #expect(delegate.responses == ["\(esc)]22;1,1,1,1,1,0\(esc)\\"])
        delegate.supported = []
        terminal.feed(text: "\(esc)]22;?none,text\u{7}\(esc)]22;none\u{7}")
        #expect(delegate.responses.last == "\(esc)]22;0,0\(esc)\\")
        #expect(terminal.mousePointerShape == nil)
        #expect(delegate.changes.isEmpty)
    }

    @Test func setPushPopAndResetPreserveThePreviousPointer() {
        let (terminal, delegate) = makeTerminal()
        terminal.feed(text: "\(esc)]22;pointer\(esc)\\\(esc)]22;>none\(esc)\\")
        #expect(terminal.mousePointerShape == .hidden)
        terminal.feed(text: "\(esc)]22;?__current__,__default__,__grabbed__\(esc)\\")
        #expect(delegate.responses.last == "\(esc)]22;none,text,default\(esc)\\")
        terminal.feed(text: "\(esc)]22;<ignored\(esc)\\")
        #expect(terminal.mousePointerShape == .pointer)
        terminal.feed(text: "\(esc)]22;=text\(esc)\\\(esc)]22;unknown\(esc)\\")
        #expect(terminal.mousePointerShape == .text)
        terminal.feed(text: "\(esc)]22;\(esc)\\\(esc)]22;<\(esc)\\")
        #expect(terminal.mousePointerShape == nil)
        #expect(delegate.changes == [.pointer, .hidden, .pointer, .text, nil])
    }

    @Test func pointerStacksAreIndependentOfMouseTrackingAndScreenContents() {
        let (terminal, delegate) = makeTerminal()
        defer { withExtendedLifetime(delegate) {} }
        terminal.feed(text: "\(esc)]22;pointer\(esc)\\\(esc)[?1049h")
        #expect(terminal.mousePointerShape == nil)
        terminal.feed(text: "\(esc)]22;none\(esc)\\\(esc)[?1003h\(esc)[?1003l\(esc)[2J")
        #expect(terminal.mousePointerShape == .hidden)
        terminal.feed(text: "\(esc)[?1049l")
        #expect(terminal.mousePointerShape == .pointer)
        terminal.feed(text: "\(esc)[?1049h")
        #expect(terminal.mousePointerShape == .hidden)
        terminal.feed(text: "\(esc)c")
        #expect(terminal.mousePointerShape == nil)
        terminal.feed(text: "\(esc)[?1049h")
        #expect(terminal.mousePointerShape == nil)
    }

    @Test func pushIsBoundedAndIgnoresUnsupportedNames() {
        let (terminal, delegate) = makeTerminal()
        defer { withExtendedLifetime(delegate) {} }
        terminal.feed(text: "\(esc)]22;>pointer," + Array(repeating: "none", count: 16).joined(separator: ",") + "\(esc)\\")
        #expect(terminal.buffer.mousePointerShapes.count == 16)
        #expect(terminal.mousePointerShape == .hidden)
        terminal.feed(text: "\(esc)]22;>bad\(esc)\\")
        #expect(terminal.buffer.mousePointerShapes.count == 16)
        for _ in 0..<16 { terminal.feed(text: "\(esc)]22;<\(esc)\\") }
        #expect(terminal.mousePointerShape == nil)
    }

    @Test func splitSequencesAndCustomOscHandlersKeepTheirBehavior() {
        let sequence = Array("\(esc)]22;>none\(esc)\\".utf8)
        for split in 1..<sequence.count {
            let (terminal, delegate) = makeTerminal()
            defer { withExtendedLifetime(delegate) {} }
            terminal.feed(buffer: sequence[..<split])
            // The existing OSC parser dispatches when it sees ST's ESC byte.
            if split < sequence.count - 1 { #expect(terminal.mousePointerShape == nil) }
            terminal.feed(buffer: sequence[split...])
            #expect(terminal.mousePointerShape == .hidden)
        }
        let (terminal, _) = makeTerminal()
        var overridden = false
        terminal.registerOscHandler(code: 22) { _ in overridden = true }
        terminal.feed(text: "\(esc)]22;none\(esc)\\")
        #expect(overridden && terminal.mousePointerShape == nil)
    }
}
