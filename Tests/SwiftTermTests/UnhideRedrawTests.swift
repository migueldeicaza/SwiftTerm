import Testing
@testable import SwiftTerm

#if os(macOS)
import AppKit

/// `NSView.displayLink(target:selector:)` does not fire while the view is
/// hidden, so a hidden terminal produces no frames. Output that arrives in
/// that time only marks the frame driver dirty. When the view is shown again,
/// the first frame must be drawn as part of unhiding, not on the next
/// display-link tick: otherwise the layer keeps showing the content from
/// before it was hidden until the main thread is free again, which a host that
/// switches between several terminals (tabs) sees as the old screen flashing
/// before the current one.
@MainActor
struct UnhideRedrawTests {
    private final class RecordingDelegate: TerminalViewDelegate {
        var scrolledCount = 0
        var rangeChangedCount = 0

        func scrolled(source: TerminalView, position: Double) { scrolledCount += 1 }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) { rangeChangedCount += 1 }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }

    private let marker = "arrived while hidden"

    /// A terminal view in a window. Test windows are not on screen, so the
    /// occlusion pause is turned off; it is covered by the frame driver tests.
    private func makeWindowedView() -> (NSWindow, TerminalView) {
        let frame = CGRect(x: 0, y: 0, width: 640, height: 320)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TerminalView(frame: frame)
        window.contentView = view
        view.suspendsRenderingWhenNotVisible = false
        return (window, view)
    }

    private func drawnRowsContainMarker(_ view: TerminalView) -> Bool {
        view.renderOwner.inspection().rowTexts.contains { $0.contains(marker) }
    }

    @Test func unhidingDrawsTheCurrentContentImmediately() {
        let (window, view) = makeWindowedView()
        defer { window.close() }

        view.terminal.feed(text: "before hiding\r\n")
        view.isHidden = true
        view.terminal.feed(text: "\(marker)\r\n")
        #expect(!drawnRowsContainMarker(view))

        view.isHidden = false

        // No run loop turn: the frame was drawn while unhiding.
        #expect(drawnRowsContainMarker(view))
    }

    /// The frame is drawn inside `isHidden = false`, but host callbacks must
    /// not run there: the setter is often called from the host's own view
    /// update. They arrive on the next main-actor turn instead, and are not lost.
    @Test func hostCallbacksAreDeliveredAfterUnhidingNotInside() async {
        let (window, view) = makeWindowedView()
        defer { window.close() }
        let delegate = RecordingDelegate()
        view.terminalDelegate = delegate

        view.isHidden = true
        for i in 0..<(view.terminal.rows * 2) {
            view.terminal.feed(text: "\(marker) \(i)\r\n")
        }
        delegate.scrolledCount = 0
        delegate.rangeChangedCount = 0

        view.isHidden = false
        #expect(drawnRowsContainMarker(view))
        #expect(delegate.scrolledCount == 0)
        #expect(delegate.rangeChangedCount == 0)

        for _ in 0..<20 where delegate.scrolledCount == 0 {
            await Task.yield()
        }
        #expect(delegate.scrolledCount >= 1)
    }

    @Test(arguments: [false, true])
    func deferredEffectsUseTheLatestBlinkRows(latestFrameBlinks: Bool) async {
        let (window, view) = makeWindowedView()
        defer {
            view.updateUiClosed()
            window.close()
        }
        // Run frames manually to control their order relative to the task.
        view.frameDriver.shutdown()
        view.textBlinkApplicationActive = true
        view.isHidden = true
        view.terminal.feed(text: latestFrameBlinks ? "plain" : "\u{1b}[5mblink")
        view.isHidden = false

        // A newer frame runs before the unhide task can apply its effects.
        view.terminal.feed(text: "\r\u{1b}[0m\u{1b}[2K")
        view.terminal.feed(text: latestFrameBlinks ? "\u{1b}[5mblink" : "plain")
        view.frameTick()
        let shouldBlink = latestFrameBlinks
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #expect((view.textBlinkTimer != nil) == shouldBlink)

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        #expect(!view.publishedBlinkRows().isEmpty == latestFrameBlinks)
        #expect((view.textBlinkTimer != nil) == shouldBlink)
    }

    @Test func unhidingOutsideAWindowDoesNotDraw() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        view.isHidden = true
        view.terminal.feed(text: "\(marker)\r\n")

        view.isHidden = false

        #expect(!drawnRowsContainMarker(view))
    }

    /// AppKit also sends `viewDidUnhide` when a view is removed from a hidden
    /// ancestor; the view is not becoming visible, so nothing is drawn.
    @Test func removalFromAHiddenAncestorDoesNotDraw() {
        let frame = CGRect(x: 0, y: 0, width: 640, height: 320)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: frame)
        window.contentView = container
        let view = TerminalView(frame: frame)
        container.addSubview(view)
        view.suspendsRenderingWhenNotVisible = false

        container.isHidden = true
        view.terminal.feed(text: "\(marker)\r\n")

        view.removeFromSuperview()

        #expect(!drawnRowsContainMarker(view))
    }

    /// Hosts usually remove a tab's container rather than the terminal. AppKit
    /// clears the container's cached `isHiddenOrHasHiddenAncestor` before the
    /// terminal gets `viewDidUnhide`, so the guard has to walk `isHidden` itself.
    @Test func containerRemovedFromAHiddenAncestorDoesNotDraw() {
        let frame = CGRect(x: 0, y: 0, width: 640, height: 320)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hiddenAncestor = NSView(frame: frame)
        window.contentView = hiddenAncestor
        let container = NSView(frame: frame)
        hiddenAncestor.addSubview(container)
        let view = TerminalView(frame: frame)
        container.addSubview(view)
        view.suspendsRenderingWhenNotVisible = false

        hiddenAncestor.isHidden = true
        view.terminal.feed(text: "\(marker)\r\n")

        container.removeFromSuperview()

        #expect(!drawnRowsContainMarker(view))
    }

    /// The occlusion pause stays in charge: a window that was never put on
    /// screen is not visible, so unhiding in it does not draw.
    @Test func unhidingInAWindowThatIsNotVisibleDoesNotDraw() {
        let frame = CGRect(x: 0, y: 0, width: 640, height: 320)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = TerminalView(frame: frame)
        window.contentView = view
        #expect(view.frameDriver.isVisibilitySuspended)

        view.isHidden = true
        view.terminal.feed(text: "\(marker)\r\n")
        view.isHidden = false

        #expect(!drawnRowsContainMarker(view))
    }

    nonisolated static var metalAvailable: Bool { MetalTerminalRenderer.shaderLibraryIsAvailable }

    /// On the render-loop path the frame is drawn on the render thread; unhiding
    /// has to wake that thread right away.
    @Test(.enabled(if: UnhideRedrawTests.metalAvailable))
    func renderLoopIsSignalledWhileUnhiding() throws {
        let (window, view) = makeWindowedView()
        defer {
            window.close()
            view.updateUiClosed()
        }
        try view.setUseMetal(true)
        #expect(view.isUsingRenderLoop)

        view.isHidden = true
        view.terminal.feed(text: "\(marker)\r\n")
        let before = view.renderLoop?.currentCounters.signals ?? 0
        view.isHidden = false

        #expect((view.renderLoop?.currentCounters.signals ?? 0) > before)
    }
}
#endif
