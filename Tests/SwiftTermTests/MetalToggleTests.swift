//
//  MetalToggleTests.swift
//  SwiftTermTests
//
//  Hosts expose "use the GPU renderer" as a user preference and flip it at
//  runtime, often across every open terminal at once. Each flip now starts or
//  stops a render loop and rebuilds a surface, so the toggle is worth pinning
//  (io-gaps.md G1).
//

#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct MetalToggleTests {

    private func makeView() -> TerminalView {
        let view = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 200),
            font: nil,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 100))
        // Metal needs a real device; the tests below skip themselves when the
        // machine has none rather than failing.
        return view
    }

    /// A device is not enough: the renderer also needs a usable shader library.
    /// These tests skip when either is unavailable, including on GPU-less CI.
    nonisolated static var metalIsUsable: Bool {
        MetalTerminalRenderer.shaderLibraryIsAvailable
    }

    @Test func permanentUIShutdownIsIdempotent() {
        let view = makeView()

        #expect(view.updateUiClosed())
        #expect(view.updateUiClosed())
        #expect(!view.isUsingRenderLoop)
    }

    /// The exact shape a host uses: a preference toggled repeatedly.
    @Test(.enabled(if: MetalToggleTests.metalIsUsable)) func repeatedOnOffTogglesAreStable() throws {
        let view = makeView()
        defer { view.frameDriver.invalidate() }

        for _ in 0..<8 {
            try view.setUseMetal(true)
            #expect(view.isUsingMetalRenderer)
            view.feed(text: "on\r\n")

            try view.setUseMetal(false)
            #expect(!view.isUsingMetalRenderer)
            #expect(!view.isUsingRenderLoop)
            view.feed(text: "off\r\n")
        }
        // Still usable afterwards.
        let cols = view.withTerminal { $0.cols }
        #expect(cols > 0)
    }

    /// Setting the value it already has must be a no-op, not a rebuild: hosts
    /// apply a preference to every terminal, including ones already in that
    /// state.
    @Test(.enabled(if: MetalToggleTests.metalIsUsable)) func settingTheSameValueDoesNothing() throws {
        let view = makeView()
        defer { view.frameDriver.invalidate() }

        try view.setUseMetal(true)
        let loopBefore = view.isUsingRenderLoop
        try view.setUseMetal(true)
        #expect(view.isUsingMetalRenderer)
        #expect(view.isUsingRenderLoop == loopBefore)

        try view.setUseMetal(false)
        try view.setUseMetal(false)
        #expect(!view.isUsingMetalRenderer)
    }

    /// Several terminals toggled together, which is what a host does when the
    /// preference changes: each owns its own render loop, and stopping one must
    /// not disturb another.
    @Test(.enabled(if: MetalToggleTests.metalIsUsable)) func togglingManyViewsTogether() throws {
        let views = (0..<4).map { _ in makeView() }
        defer { views.forEach { $0.frameDriver.invalidate() } }

        for _ in 0..<3 {
            for view in views { try view.setUseMetal(true) }
            #expect(views.allSatisfy { $0.isUsingMetalRenderer })
            for view in views { view.feed(text: "x\r\n") }

            for view in views { try view.setUseMetal(false) }
            #expect(views.allSatisfy { !$0.isUsingMetalRenderer })
            #expect(views.allSatisfy { !$0.isUsingRenderLoop })
        }
    }

    /// The OSC 9;4 progress bar is an overlay: the opaque Metal surface covers
    /// the whole view, so the bar has to stay the topmost subview across a
    /// renderer swap or it is simply never seen (which is how it shipped).
    @Test func progressBarStaysOnTopOfTheRendererSurface() throws {
        let view = makeView()
        defer { view.frameDriver.invalidate() }

        #expect(view.subviews.last is TerminalProgressBarView)

        if MetalToggleTests.metalIsUsable {
            try view.setUseMetal(true)
            #expect(view.subviews.last is TerminalProgressBarView)
            try view.setUseMetal(false)
            #expect(view.subviews.last is TerminalProgressBarView)
        }
    }

    /// `requestRedraw` is the documented replacement for `setNeedsDisplay` and
    /// has to be safe in both renderer states, including from another thread.
    @Test(.enabled(if: MetalToggleTests.metalIsUsable)) func requestRedrawIsSafeInEitherState() throws {
        let view = makeView()
        defer { view.frameDriver.invalidate() }

        for enabled in [true, false, true] {
            try view.setUseMetal(enabled)
            view.requestRedraw()
            let signal = view.frameSignal
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                signal.markDirty()
                done.signal()
            }
            #expect(done.wait(timeout: .now() + 5) == .success)
        }
    }

    /// A host can enable Metal before Auto Layout gives a new terminal its
    /// size. Keep the selected opaque background visible until the first
    /// drawable covers it instead of exposing the window's background.
    @Test(.enabled(if: MetalToggleTests.metalIsUsable)) func opaqueBackgroundCoversAZeroSizedMetalSurface() throws {
        let view = TerminalView(
            frame: .zero,
            font: nil,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 100))
        defer { view.frameDriver.invalidate() }
        let expected = NSColor(srgbRed: 0.84, green: 0.79, blue: 0.68, alpha: 1)
        view.nativeBackgroundColor = expected

        try view.setUseMetal(true)

        let actual = try #require(view.layer?.backgroundColor)
        #expect(actual == expected.cgColor)
    }

    /// A translucent background must not use the opaque first-frame fallback,
    /// because the Metal clear color would apply its alpha a second time.
    @Test(.enabled(if: MetalToggleTests.metalIsUsable)) func translucentMetalBackgroundKeepsTheHostLayerClear() throws {
        let view = makeView()
        defer { view.frameDriver.invalidate() }
        view.nativeBackgroundColor = NSColor(
            srgbRed: 0.20,
            green: 0.25,
            blue: 0.30,
            alpha: 0.5)

        try view.setUseMetal(true)

        let actual = try #require(view.layer?.backgroundColor)
        #expect(actual.alpha == 0)
        #expect(view.metalView?.layer?.isOpaque == false)
    }
}
#endif
