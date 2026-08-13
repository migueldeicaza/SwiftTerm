//
//  ScrollWheelMouseReportCountTests.swift
//
//  Repro for the claim that, after 91863f0 ("Line-accurate scroll wheel with
//  optional sensitivity control (macOS)"), MacTerminalView.scrollWheel(with:)
//  sends one button4/5 mouse-report event per *line* of scroll rather than
//  one event per physical wheel *notch*, in the alternate-screen +
//  mouse-tracking-enabled case (e.g. vim `set mouse=a`, htop).
//
//  Enable with: RUN_APPKIT_TESTS=1 swift test --filter ScrollWheelMouseReportCountTests
//

#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import SwiftTerm

private func appKitTestsEnabled() -> Bool {
    ProcessInfo.processInfo.environment["RUN_APPKIT_TESTS"] == "1"
}

@Suite(.enabled(if: appKitTestsEnabled()))
@MainActor
final class ScrollWheelMouseReportCountTests {
    private final class CapturingDelegate: TerminalViewDelegate {
        var sent: [UInt8] = []

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            sent.append(contentsOf: data)
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

    /// Builds a classic (non-precise) mouse-wheel NSEvent the way a real USB
    /// scroll wheel notch would arrive: `wheelCount: 1`, units `.line`, so
    /// `hasPreciseScrollingDeltas == false`. `linesPerNotch` mimics what
    /// AppKit/WindowServer already bakes into `scrollingDeltaY` for a single
    /// physical notch (historically defaulted to 3 on a plain USB mouse).
    private func classicWheelEvent(linesPerNotch: Int32, window: NSWindow) -> NSEvent {
        let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: linesPerNotch,
            wheel2: 0,
            wheel3: 0
        )!
        let event = NSEvent(cgEvent: cgEvent)!
        return event
    }

    private func makeAltScreenMouseTrackingView() -> (TerminalView, CapturingDelegate, NSWindow) {
        _ = NSApplication.shared

        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let capture = CapturingDelegate()
        view.terminalDelegate = capture

        let window = NSWindow(contentRect: view.frame,
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)

        // Enter the alternate screen buffer (as vim/less/htop do) and turn on
        // basic mouse click/wheel tracking with SGR extended coordinates (as
        // `vim set mouse=a` or htop do -- SGR mode keeps each report's byte
        // length uniform and easy to count).
        view.feed(text: "\u{1b}[?1049h")
        view.feed(text: "\u{1b}[?1000h")
        view.feed(text: "\u{1b}[?1006h")

        #expect(view.terminal.isDisplayBufferAlternate)
        #expect(view.terminal.mouseMode != .off)

        capture.sent.removeAll()
        return (view, capture, window)
    }

    /// FACT CHECK: a single classic wheel notch, which macOS reports with
    /// scrollingDeltaY already expressed in "lines" (here simulated as 3,
    /// the historical default), produces 3 separate button-4 mouse reports,
    /// not 1. xterm's X11-derived convention is one Button4 press per
    /// physical notch; the receiving TUI (e.g. vim, whose default
    /// 'mousescroll' is ver:3) then multiplies each received press by its
    /// own lines-per-click, expecting one event per notch. Sending 3 events
    /// for what the user felt as a single notch means a TUI honoring the
    /// xterm convention scrolls 3x further than intended.
    @Test func classicWheelNotchSendsOneEventPerLineNotPerNotch() {
        let (view, capture, _) = makeAltScreenMouseTrackingView()

        let event = classicWheelEvent(linesPerNotch: 3, window: view.window!)
        #expect(event.hasPreciseScrollingDeltas == false)
        #expect(event.scrollingDeltaY == 3)

        view.scrollWheel(with: event)

        let sentString = String(bytes: capture.sent, encoding: .utf8) ?? ""
        let button4Reports = sentString.components(separatedBy: "\u{1b}[<64;").count - 1

        // What we WANT to find, if the bug claim is right: 1 event (one
        // notch -> one button4 press, xterm/X11 style).
        // What SwiftTerm ACTUALLY does after 91863f0 (and in fact since the
        // original PR #518/#506 that introduced mouse-report scroll
        // forwarding): one event per accumulated line.
        #expect(button4Reports == 3, "SwiftTerm sent \(button4Reports) button4 report(s) for a single 3-line wheel notch")
    }

    /// Same check against the pre-91863f0 step-function velocity to prove
    /// this is not a regression introduced by that commit: even the old
    /// `calcScrollingVelocity` fed `Int(abs(event.deltaY))` and looped that
    /// many times over `sendEvent`, i.e. "N deltaY units in -> N button
    /// presses out" already held before the rewrite.
    @Test func singleLineNotchStillSendsExactlyOneEvent() {
        let (view, capture, _) = makeAltScreenMouseTrackingView()

        let event = classicWheelEvent(linesPerNotch: 1, window: view.window!)
        #expect(event.scrollingDeltaY == 1)

        view.scrollWheel(with: event)

        let sentString = String(bytes: capture.sent, encoding: .utf8) ?? ""
        let button4Reports = sentString.components(separatedBy: "\u{1b}[<64;").count - 1
        #expect(button4Reports == 1)
    }
}
#endif
