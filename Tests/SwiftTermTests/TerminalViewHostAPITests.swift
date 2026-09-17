#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

@Suite(.serialized)
@MainActor
struct TerminalViewHostAPITests {
    private final class RecordingDelegate: TerminalViewDelegate {
        var sent: [[UInt8]] = []

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

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(condition())
    }

    @Test func cursorStyleDoesNotSendHostInput() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let delegate = RecordingDelegate()
        view.terminalDelegate = delegate

        for style in CursorStyle.allCases {
            view.setCursorStyle(style)
            #expect(view.terminalStateSnapshot().cursorStyle == style)
        }

        await Task.yield()
        #expect(delegate.sent.isEmpty)
    }

    @Test func navigationKeysUseNormalAndApplicationModes() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let delegate = RecordingDelegate()
        view.terminalDelegate = delegate

        for applicationMode in [false, true] {
            view.feed(text: applicationMode ? "\u{1b}[?1h" : "\u{1b}[?1l")
            delegate.sent.removeAll()
            view.sendKeyUp()
            view.sendKeyDown()
            view.sendKeyLeft()
            view.sendKeyRight()
            view.sendKeyHome()
            view.sendKeyEnd()
            await waitUntil { delegate.sent.count == 6 }

            let prefix = applicationMode ? "\u{1b}O" : "\u{1b}["
            #expect(delegate.sent == ["A", "B", "D", "C", "H", "F"].map {
                Array((prefix + $0).utf8)
            })
        }
    }
}
#endif
