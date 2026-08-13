//
//  SelectionAutoScrollTimerLifecycleTests.swift
//
//  f971cbf ("Mac: restore auto-scroll while dragging a selection past an
//  edge") introduced `selectionAutoScrollTimer`, a repeating Timer that keeps
//  scrolling the viewport while the pointer is held past the top/bottom edge
//  during a selection drag. It is armed in `mouseDragged` and, before this
//  change, torn down only in `mouseUp`.
//
//  A view taken out of the view hierarchy while a drag is in flight never
//  receives that `mouseUp`: verified with a standalone AppKit probe, where a
//  view removed from its superview mid-drag logged no `mouseUp` at all while
//  a 20 Hz tick kept reporting the drag as still in progress for as long as
//  the probe was left running. Closing a tab or a split pane during a
//  selection drag is exactly that sequence.
//
//  The timer would then keep running: still scrolling while the view is
//  alive, and — because the timer block captures the view weakly — kept on
//  the run loop with nothing left that can invalidate it once the view goes
//  away. Hosts that close a tab or a split pane during a drag do this by
//  detaching or reparenting the view; the probe verified the explicit
//  removeFromSuperview form.
//
import Testing
@testable import SwiftTerm

#if os(macOS)
import AppKit

struct SelectionAutoScrollTimerLifecycleTests {
    @MainActor private func wait(seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            let timer = Timer(timeInterval: seconds, repeats: false) { _ in
                continuation.resume()
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// Builds a view with enough scrollback that an auto-scroll running
    /// unchecked for hundreds of milliseconds still has room to move --
    /// otherwise it could look "stopped" merely because it hit row 0.
    @MainActor private func makeViewWithScrollback() -> (view: TerminalView, window: NSWindow) {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view

        for i in 0..<4000 {
            view.terminal.feed(text: "line \(i)\r\n")
        }
        return (view, window)
    }

    /// Arms the auto-scroll timer the way a real selection drag past the top
    /// edge does.
    @MainActor private func beginDragPastTopEdge(view: TerminalView, window: NSWindow) {
        let pressPoint = CGPoint(x: 10, y: view.frame.height / 2)
        // Above the top edge of the view: negative screenRow arms the
        // scroll-up branch of mouseDragged.
        let dragPoint = CGPoint(x: 10, y: view.frame.height + 3 * view.cellDimension.height)

        let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: pressPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        )!
        let drag = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: dragPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1
        )!

        view.mouseDown(with: down)
        view.mouseDragged(with: drag)
    }

    @Test @MainActor func removingTheViewMidDragStopsAutoScroll() async {
        let (view, window) = makeViewWithScrollback()
        beginDragPastTopEdge(view: view, window: window)

        // Sanity: the drag really did arm the timer, otherwise the assertion
        // below would pass for the wrong reason.
        #expect(view.hasActiveSelectionAutoScrollForTesting, "precondition: dragging past the edge must arm the timer")

        // The tab/pane goes away mid-drag. No mouseUp will ever arrive.
        window.contentView = nil

        #expect(view.hasActiveSelectionAutoScrollForTesting == false, "the timer must not outlive the view's place in the hierarchy")

        let before = view.terminal.buffer.yDisp
        // 8 ticks' worth of the timer's 0.05s interval: plenty of time for a
        // surviving timer to show itself, short enough to keep the suite fast.
        await wait(seconds: 0.4)
        #expect(view.terminal.buffer.yDisp == before, "a torn-down timer cannot still be scrolling")
    }

    /// A live drag must keep auto-scrolling until mouseUp. This rules out
    /// fixes that guess at whether the button is still held (see the header).
    @Test @MainActor func normalDragKeepsAutoScrollRunning() async {
        let (view, window) = makeViewWithScrollback()
        beginDragPastTopEdge(view: view, window: window)

        let before = view.terminal.buffer.yDisp
        await wait(seconds: 0.4)

        #expect(view.terminal.buffer.yDisp < before, "auto-scroll must keep running for as long as the drag is live")
        #expect(view.hasActiveSelectionAutoScrollForTesting, "the timer stays armed until mouseUp")

        let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 0
        )!
        view.mouseUp(with: up)
        #expect(view.hasActiveSelectionAutoScrollForTesting == false, "mouseUp still tears the timer down")
    }

    /// A reparent that keeps the same window still ends the drag: AppKit calls
    /// viewDidMoveToWindow for it (with a non-nil window), and the view will not
    /// receive the mouseUp that would otherwise stop the timer.
    @Test @MainActor func reparentingWithinTheSameWindowMidDragStopsAutoScroll() async {
        let (view, window) = makeViewWithScrollback()
        // Rehome the view under a plain root so it can be reparented between two
        // sibling containers; a window's contentView cannot be moved into its own
        // descendant. No drag is in flight yet, so this move is inert.
        let root = NSView(frame: view.frame)
        let boxA = NSView(frame: view.frame)
        let boxB = NSView(frame: view.frame)
        window.contentView = root
        root.addSubview(boxA)
        root.addSubview(boxB)
        boxA.addSubview(view)

        beginDragPastTopEdge(view: view, window: window)
        #expect(view.hasActiveSelectionAutoScrollForTesting, "precondition: dragging past the edge must arm the timer")

        boxB.addSubview(view)   // same window, new superview

        #expect(view.hasActiveSelectionAutoScrollForTesting == false, "a hierarchy move ends the drag even when the window is unchanged")
    }
}
#endif
