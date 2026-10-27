//
//  StaleColorEchoTests.swift
//  SwiftTermTests
//
//  The terminal broadcasts color changes to the view asynchronously, so an echo can land on main after a host installed its own palette.
//  setupOptions stamps the defaults on every pass, and without a guard that no-op stamp's echo transiently replaced the host color.
//  Hosts saw that as one black frame when a Metal renderer attached at the same moment.
//

#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct StaleColorEchoTests {

    private func makeView() -> TerminalView {
        TerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 200),
            font: nil,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 100))
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    @Test func staleBackgroundEchoDoesNotOverwriteTheHostColor() {
        let view = makeView()
        defer { view.frameDriver.invalidate() }

        view.nativeBackgroundColor = NSColor.white

        // The echo for a color the model no longer holds must be dropped.
        view.setNativeBackgroundColorFromTerminal(NSColor.black)

        #expect(view.nativeBackgroundColor == NSColor.white)
    }

    @Test func staleForegroundEchoDoesNotOverwriteTheHostColor() {
        let view = makeView()
        defer { view.frameDriver.invalidate() }

        view.nativeForegroundColor = NSColor.black

        view.setNativeForegroundColorFromTerminal(NSColor.white)

        #expect(view.nativeForegroundColor == NSColor.black)
    }

    @Test func liveOscBackgroundChangeStillReachesTheView() async {
        let view = makeView()
        defer { view.frameDriver.invalidate() }

        view.feed(text: "\u{1b}]11;rgb:ff/00/00\u{7}")
        await drainMainQueue()
        await drainMainQueue()

        #expect(view.nativeBackgroundColor == NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    }
}
#endif
