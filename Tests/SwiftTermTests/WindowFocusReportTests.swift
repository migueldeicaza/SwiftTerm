//
//  WindowFocusReportTests.swift
//
//  Focus reporting (DECSET 1004) driven by window activation, not just by
//  responder changes. AppKit keeps a window's first responder when the window
//  loses key status, so a terminal in a background window stayed "focused" and
//  never told the application that focus was lost.
//
#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

/// A window whose key status the test controls, so activation can be driven
/// without a window server.
private final class StubWindow: NSWindow {
    var stubIsKey = false
    override var isKeyWindow: Bool { stubIsKey }
}

@MainActor
final class WindowFocusReportTests {

    private final class CapturingDelegate: TerminalViewDelegate {
        var sent: [UInt8] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
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

        var sentString: String { String(decoding: sent, as: UTF8.self) }
    }

    /// Output reaches the view delegate through a main-queue hop, so poll until
    /// the expected number of bytes arrives instead of reading them inline.
    private func waitForBytes(_ delegate: CapturingDelegate, _ count: Int) async {
        for _ in 0..<250 where delegate.sent.count < count {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    @Test func windowActivationDrivesFocusReports() async {
        let window = StubWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let delegate = CapturingDelegate()
        view.terminalDelegate = delegate
        window.contentView?.addSubview(view)
        window.stubIsKey = true
        #expect(window.makeFirstResponder(view), "the terminal view accepts first responder")

        view.feed(text: "\u{1b}[?1004h")
        await waitForBytes(delegate, 3)
        #expect(delegate.sentString == "\u{1b}[I", "enabling reporting in a key window reports focus-in")

        // Losing key status does not resign the first responder, so the report
        // has to come from the window notification.
        delegate.sent.removeAll()
        window.stubIsKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        await waitForBytes(delegate, 3)
        #expect(delegate.sentString == "\u{1b}[O", "a window that resigns key reports focus-out")

        delegate.sent.removeAll()
        window.stubIsKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await waitForBytes(delegate, 3)
        #expect(delegate.sentString == "\u{1b}[I", "a window that becomes key reports focus-in")
    }
}
#endif
