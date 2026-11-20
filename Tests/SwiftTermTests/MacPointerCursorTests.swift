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

    private func makeView() -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        // Not the real keys: a Shift that the user holds must not change a result.
        view.heldModifierFlags = { [] }
        return view
    }

    @Test func plainOutputShowsTheIBeam() {
        let view = makeView()
        view.feed(text: "$ ls")
        #expect(view.pointerCursor(modifiers: []) === NSCursor.iBeam)
    }

    @Test func osc22SelectsShapesAndRestoresThemWithoutMouseTracking() throws {
        let view = makeView()
        view.feed(text: "\(esc)]22;pointer\(esc)\\")
        #expect(view.currentMousePointerShape == .pointer)
        #expect(view.pointerCursor(modifiers: []) === NSCursor.pointingHand)
        view.feed(text: "\(esc)]22;>none\(esc)\\")
        let hidden = view.pointerCursor(modifiers: [])
        #expect(view.currentMousePointerShape == .hidden)
        #expect(hidden !== NSCursor.arrow && hidden !== NSCursor.iBeam)
        #expect(view.pointerCursor(modifiers: []) === hidden)
        let image = try #require(hidden.image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: image))
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                #expect(bitmap.colorAt(x: x, y: y)?.alphaComponent == 0)
            }
        }
        view.feed(text: "\(esc)]22;<\(esc)\\")
        #expect(view.pointerCursor(modifiers: []) === NSCursor.pointingHand)
        view.feed(text: "\(esc)]22;\(esc)\\")
        #expect(view.currentMousePointerShape == nil)
        #expect(view.pointerCursor(modifiers: []) === NSCursor.iBeam)
    }

    @Test func osc22RespectsLocalSelectionAndScreenSwitches() {
        let view = makeView()
        view.feed(text: "\(esc)[?1003h\(esc)]22;none\(esc)\\")
        let hidden = view.pointerCursor(modifiers: [])
        #expect(view.pointerCursor(modifiers: .shift) === NSCursor.iBeam)
        view.feed(text: "\(esc)[>1s")
        #expect(view.pointerCursor(modifiers: .shift) === hidden)
        view.feed(text: "\(esc)[?1049h")
        #expect(view.currentMousePointerShape == nil)
        #expect(view.pointerCursor(modifiers: []) === NSCursor.arrow)
        view.feed(text: "\(esc)[?1049l")
        #expect(view.currentMousePointerShape == .hidden)
        view.resetToInitialState()
        #expect(view.currentMousePointerShape == nil)
    }

    @Test func mouseReportingShowsTheArrow() {
        let view = makeView()
        view.feed(text: "\(esc)[?1000h\(esc)[?1006h")
        #expect(view.pointerCursor(modifiers: []) === NSCursor.arrow)
    }

    @Test func shiftShowsTheIBeamWhileItBypassesReporting() {
        let view = makeView()
        view.feed(text: "\(esc)[?1002h\(esc)[?1006h")
        #expect(view.pointerCursor(modifiers: .shift) === NSCursor.iBeam)

        view.feed(text: "\(esc)[>1s")
        #expect(view.pointerCursor(modifiers: .shift) === NSCursor.arrow)
    }

    @Test func turningReportingOffBringsBackTheIBeam() {
        let view = makeView()
        view.feed(text: "\(esc)[?1003h")
        #expect(view.pointerCursor(modifiers: []) === NSCursor.arrow)

        view.feed(text: "\(esc)[?1003l")
        #expect(view.pointerCursor(modifiers: []) === NSCursor.iBeam)
    }

    @Test func disallowedReportingShowsTheIBeam() {
        let view = makeView()
        view.feed(text: "\(esc)[?1000h")
        view.allowMouseReporting = false
        #expect(view.pointerCursor(modifiers: []) === NSCursor.iBeam)
    }

    @Test func cursorUpdateSetsTheArrowWhileReporting() throws {
        let view = makeView()
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        view.feed(text: "\(esc)[?1003h\(esc)[?1006h")
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: CGPoint(x: 10, y: 10), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 0, pressure: 0))

        NSCursor.iBeam.set()
        view.cursorUpdate(with: event)
        #expect(NSCursor.current === NSCursor.arrow)

        view.feed(text: "\(esc)[?1003l")
        view.cursorUpdate(with: event)
        #expect(NSCursor.current === NSCursor.iBeam)
    }

    @Test func shiftEscapeNotifiesTheViewOnlyWhenItChanges() {
        let view = makeView()
        view.feed(text: "\(esc)[?1002h")
        let posts = view.eventQueue.posts

        view.feed(text: "\(esc)[>1s")
        #expect(view.eventQueue.posts == posts + 1)

        view.feed(text: "\(esc)[>1s")
        #expect(view.eventQueue.posts == posts + 1)
    }

    /// A visible window off screen holding the view, with the pointer placed
    /// over the view, since a test cannot move the real pointer.
    private func showInWindow(_ view: TerminalView) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: -30_000, y: -30_000, width: 400, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = content
        content.addSubview(view)
        view.pointerLocationInTopmostWindow = { _ in CGPoint(x: 10, y: 10) }
        window.orderFrontRegardless()
        return window
    }

    @Test func osc22UpdatesAStationaryPointerAndFullResetRestoresIt() {
        let view = makeView()
        let window = showInWindow(view)
        defer {
            window.orderOut(nil)
            NSCursor.arrow.set()
        }
        NSCursor.iBeam.set()
        view.feed(text: "\(esc)]22;none\(esc)\\")
        view.eventQueue.drain()
        #expect(NSCursor.current === view.pointerCursor(modifiers: []))
        #expect(view.currentMousePointerShape == .hidden)
        view.resetToInitialState()
        view.eventQueue.drain()
        #expect(NSCursor.current === NSCursor.iBeam)
    }

    @Test func osc22DoesNotHideThePointerOutsideItsView() {
        let view = makeView()
        let window = showInWindow(view)
        defer { window.orderOut(nil) }
        view.pointerLocationInTopmostWindow = { _ in nil }
        NSCursor.arrow.set()
        view.feed(text: "\(esc)]22;none\(esc)\\")
        view.eventQueue.drain()
        #expect(view.currentMousePointerShape == .hidden)
        #expect(NSCursor.current === NSCursor.arrow)
    }

    @Test func mouseModeChangeUpdatesThePointerAtOnce() {
        let view = makeView()
        let window = showInWindow(view)
        defer { window.orderOut(nil) }
        NSCursor.iBeam.set()

        view.feed(text: "\(esc)[?1000h\(esc)[?1006h")
        view.eventQueue.drain()
        #expect(NSCursor.current === NSCursor.arrow)

        view.feed(text: "\(esc)[?1000l")
        view.eventQueue.drain()
        #expect(NSCursor.current === NSCursor.iBeam)
    }

    @Test func allowMouseReportingUpdatesThePointerAtOnce() {
        let view = makeView()
        let window = showInWindow(view)
        defer { window.orderOut(nil) }
        NSCursor.iBeam.set()
        view.feed(text: "\(esc)[?1000h")
        view.eventQueue.drain()
        #expect(NSCursor.current === NSCursor.arrow)

        view.allowMouseReporting = false
        #expect(NSCursor.current === NSCursor.iBeam)
    }

    @Test func shiftUpdatesThePointerOfTheViewUnderIt() {
        let view = makeView()
        let window = showInWindow(view)
        defer { window.orderOut(nil) }
        view.feed(text: "\(esc)[?1002h")
        view.eventQueue.drain()

        view.refreshPointer(modifiers: .shift)
        #expect(NSCursor.current === NSCursor.iBeam)

        view.refreshPointer(modifiers: [])
        #expect(NSCursor.current === NSCursor.arrow)
    }

    @Test func aHiddenViewLeavesThePointerAlone() {
        let view = makeView()
        let window = showInWindow(view)
        defer { window.orderOut(nil) }
        NSCursor.iBeam.set()
        view.feed(text: "\(esc)[?1000h")
        view.eventQueue.drain()
        #expect(NSCursor.current === NSCursor.arrow)

        view.isHidden = true
        view.feed(text: "\(esc)[?1000l")
        view.eventQueue.drain()
        #expect(NSCursor.current === NSCursor.arrow)
    }

    @Test func theViewFollowsShiftOnlyWhileReportingInAWindow() {
        let view = makeView()
        view.feed(text: "\(esc)[?1000h")
        view.eventQueue.drain()
        #expect(!view.followsPointerFlags)

        let window = showInWindow(view)
        defer { window.orderOut(nil) }
        #expect(view.followsPointerFlags)

        view.feed(text: "\(esc)[?1000l")
        view.eventQueue.drain()
        #expect(!view.followsPointerFlags)

        view.feed(text: "\(esc)[?1000h")
        view.eventQueue.drain()
        view.allowMouseReporting = false
        #expect(!view.followsPointerFlags)

        view.allowMouseReporting = true
        #expect(view.followsPointerFlags)
        view.removeFromSuperview()
        #expect(!view.followsPointerFlags)
    }

    @Test func closingTheViewStopsFollowingShift() {
        let view = makeView()
        let window = showInWindow(view)
        defer { window.orderOut(nil) }
        view.feed(text: "\(esc)[?1000h")
        view.eventQueue.drain()
        #expect(view.followsPointerFlags)

        #expect(view.updateUiClosed())
        #expect(!view.followsPointerFlags)
    }

    @Test func shiftEscapeUpdatesThePointerAtOnce() {
        let view = makeView()
        let window = showInWindow(view)
        defer { window.orderOut(nil) }
        view.feed(text: "\(esc)[?1002h")
        view.eventQueue.drain()
        view.refreshPointer(modifiers: .shift)
        #expect(NSCursor.current === NSCursor.iBeam)

        view.feed(text: "\(esc)[>1s")
        view.eventQueue.drain()
        #expect(NSCursor.current === NSCursor.arrow)
    }

    @Test func aWindowOrderedOutLeavesThePointerAlone() {
        let view = makeView()
        let window = showInWindow(view)
        window.orderOut(nil)
        NSCursor.iBeam.set()

        view.feed(text: "\(esc)[?1000h")
        view.eventQueue.drain()
        #expect(NSCursor.current === NSCursor.iBeam)
    }

    private final class HandPointerView: TerminalView {
        override func pointerCursor(modifiers: NSEvent.ModifierFlags) -> NSCursor {
            .pointingHand
        }
    }

    @Test func aSubclassChoosesThePointer() {
        let view = HandPointerView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let window = showInWindow(view)
        defer { window.orderOut(nil) }
        NSCursor.iBeam.set()

        view.allowMouseReporting = false
        #expect(NSCursor.current === NSCursor.pointingHand)
    }

    @Test func aCoveredViewLeavesThePointerAlone() {
        let view = makeView()
        let window = showInWindow(view)
        defer { window.orderOut(nil) }
        window.contentView?.addSubview(NSView(frame: view.frame))
        NSCursor.iBeam.set()

        view.feed(text: "\(esc)[?1000h")
        view.eventQueue.drain()
        #expect(NSCursor.current === NSCursor.iBeam)
    }

    @Test func aViewInAnotherWindowLeavesThePointerAlone() {
        let view = makeView()
        let window = showInWindow(view)
        defer { window.orderOut(nil) }
        view.pointerLocationInTopmostWindow = { _ in nil }
        NSCursor.iBeam.set()

        view.feed(text: "\(esc)[?1000h")
        view.eventQueue.drain()
        #expect(NSCursor.current === NSCursor.iBeam)
    }
}
#endif
