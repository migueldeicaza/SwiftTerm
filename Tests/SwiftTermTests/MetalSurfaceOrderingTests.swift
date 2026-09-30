#if os(macOS) && canImport(MetalKit)
import AppKit
import Testing
@testable import SwiftTerm

@MainActor
struct MetalSurfaceOrderingTests {
    @Test func detachedCaretKeepsReplacementAboveOldSurface() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        let caret = try #require(view.caretView)
        caret.removeFromSuperview()
        caret.isHidden = false
        let oldSurface = NSView(frame: view.bounds)
        view.addSubview(oldSurface)
        let newSurface = NSView(frame: view.bounds)

        view.insertMetalView(newSurface, replacing: oldSurface)

        let oldIndex = try #require(view.subviews.firstIndex { $0 === oldSurface })
        let newIndex = try #require(view.subviews.firstIndex { $0 === newSurface })
        #expect(newIndex > oldIndex)
        #expect(caret.superview == nil)
        #expect(caret.isHidden)
    }

    @Test func attachedCaretRemainsAboveTheMetalSurface() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        let caret = try #require(view.caretView)
        view.addSubview(caret)
        caret.isHidden = false
        let newSurface = NSView(frame: view.bounds)

        view.insertMetalView(newSurface, replacing: nil)

        let caretIndex = try #require(view.subviews.firstIndex { $0 === caret })
        let newIndex = try #require(view.subviews.firstIndex { $0 === newSurface })
        #expect(newIndex < caretIndex)
        #expect(caret.isHidden)
    }

    @Test func detachedCaretWithoutOldSurfaceKeepsOverlaysAboveMetal() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        let caret = try #require(view.caretView)
        caret.removeFromSuperview()
        caret.isHidden = false
        view.addSubview(NSView(frame: view.bounds))
        let overlays = view.subviews
        let newSurface = NSView(frame: view.bounds)

        view.insertMetalView(newSurface, replacing: nil)

        #expect(view.subviews.first === newSurface)
        for overlay in overlays {
            let index = try #require(view.subviews.firstIndex { $0 === overlay })
            #expect(index > 0)
        }
        #expect(caret.superview == nil)
        #expect(caret.isHidden)
    }
}
#endif
