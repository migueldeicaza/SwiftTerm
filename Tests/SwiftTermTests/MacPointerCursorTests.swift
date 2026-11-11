//
//  MacPointerCursorTests.swift
//
//  The pointer over a macOS TerminalView: the I-beam for selecting text, the
//  arrow while the application receives the mouse, and the I-beam again while
//  Shift bypasses mouse reporting.
//

#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
struct MacPointerCursorTests {
    private let esc = "\u{1b}"

    private func makeView() -> (TerminalView, NSWindow) {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        return (view, window)
    }

    @Test func plainOutputShowsTheIBeam() {
        let (view, _) = makeView()
        view.feed(text: "$ ls")
        #expect(view.pointerCursor(modifiers: []) === NSCursor.iBeam)
    }

    @Test func mouseReportingShowsTheArrow() {
        let (view, _) = makeView()
        view.feed(text: "\(esc)[?1000h\(esc)[?1006h")
        #expect(view.pointerCursor(modifiers: []) === NSCursor.arrow)
    }

    @Test func shiftShowsTheIBeamWhileItBypassesReporting() {
        let (view, _) = makeView()
        view.feed(text: "\(esc)[?1002h\(esc)[?1006h")
        #expect(view.pointerCursor(modifiers: .shift) === NSCursor.iBeam)

        view.feed(text: "\(esc)[>1s")
        #expect(view.pointerCursor(modifiers: .shift) === NSCursor.arrow)
    }

    @Test func turningReportingOffBringsBackTheIBeam() {
        let (view, _) = makeView()
        view.feed(text: "\(esc)[?1003h")
        #expect(view.pointerCursor(modifiers: []) === NSCursor.arrow)

        view.feed(text: "\(esc)[?1003l")
        #expect(view.pointerCursor(modifiers: []) === NSCursor.iBeam)
    }

    @Test func disallowedReportingShowsTheIBeam() {
        let (view, _) = makeView()
        view.feed(text: "\(esc)[?1000h")
        view.allowMouseReporting = false
        #expect(view.pointerCursor(modifiers: []) === NSCursor.iBeam)
    }

    @Test func cursorUpdateSetsTheArrowWhileReporting() throws {
        let (view, window) = makeView()
        view.feed(text: "\(esc)[?1003h\(esc)[?1006h")
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: CGPoint(x: 10, y: 10), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 0, pressure: 0))

        view.cursorUpdate(with: event)
        #expect(NSCursor.current === NSCursor.arrow)

        view.feed(text: "\(esc)[?1003l")
        view.cursorUpdate(with: event)
        #expect(NSCursor.current === NSCursor.iBeam)
    }
}
#endif
