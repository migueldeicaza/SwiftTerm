import Testing
@testable import SwiftTerm

#if os(macOS)
import AppKit

/// A CAMetalLayer keeps a pool of up to three drawables at its last size for
/// as long as the layer lives. A host that keeps a terminal per tab and puts
/// only the visible ones in its window would hold a pool of window-sized
/// surfaces for every hidden terminal (about 48 MB each at Retina sizes).
/// Leaving the window gives them back; coming back draws a frame at once.
@MainActor
struct MetalOffscreenDrawablesTests {
    nonisolated static var metalAvailable: Bool { MetalTerminalRenderer.shaderLibraryIsAvailable }

    private let marker = "arrived while away"

    private func makeWindowedMetalView() throws -> (NSWindow, NSView, TerminalView) {
        let frame = CGRect(x: 0, y: 0, width: 640, height: 320)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: frame)
        window.contentView = container
        let view = TerminalView(frame: frame)
        container.addSubview(view)
        view.suspendsRenderingWhenNotVisible = false
        try view.setUseMetal(true)
        view.drawMetalFrameNow()
        return (window, container, view)
    }

    private func layer(_ view: TerminalView) -> CAMetalLayer? {
        (view.metalView as? TerminalMetalLayerView)?.metalLayer
    }

    @Test(.enabled(if: MetalOffscreenDrawablesTests.metalAvailable))
    func leavingTheWindowReleasesTheDrawables() throws {
        let (window, _, view) = try makeWindowedMetalView()
        defer {
            window.close()
            view.updateUiClosed()
        }
        let layer = try #require(layer(view))
        #expect(layer.drawableSize.width > 1)

        view.removeFromSuperview()

        #expect(layer.drawableSize == CGSize(width: 1, height: 1))
        #expect(!view.isUsingRenderLoop)
    }

    @Test(.enabled(if: MetalOffscreenDrawablesTests.metalAvailable))
    func comingBackRestoresTheSizeAndDrawsAtOnce() throws {
        let (window, container, view) = try makeWindowedMetalView()
        defer {
            window.close()
            view.updateUiClosed()
        }
        let layer = try #require(layer(view))
        let size = layer.drawableSize

        view.removeFromSuperview()
        view.terminal.feed(text: "\(marker)\r\n")
        container.addSubview(view)

        #expect(layer.drawableSize == size)
        #expect(view.isUsingRenderLoop)
        // No run loop turn: the frame was drawn while joining the window.
        #expect(view.renderOwner.inspection().rowTexts.contains { $0.contains(marker) })
    }
}
#endif
