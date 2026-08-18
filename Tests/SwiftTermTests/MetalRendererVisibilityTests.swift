#if os(iOS)
import Testing
import UIKit

@testable import SwiftTerm

@MainActor
@Suite struct MetalRendererVisibilityTests {
    @Test func effectiveVisibilityIncludesAncestorsAndWindow() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let parent = UIView(frame: window.bounds)
        let terminalView = TerminalView(frame: parent.bounds)
        window.addSubview(parent)
        parent.addSubview(terminalView)
        window.isHidden = false
        terminalView.textBlinkApplicationActive = true

        #expect(terminalView.isEffectivelyVisibleForMetalRendering)

        parent.isHidden = true
        #expect(!terminalView.isEffectivelyVisibleForMetalRendering)
        parent.isHidden = false

        parent.alpha = 0
        #expect(!terminalView.isEffectivelyVisibleForMetalRendering)
        parent.alpha = 1

        window.isHidden = true
        #expect(!terminalView.isEffectivelyVisibleForMetalRendering)
        window.isHidden = false

        window.alpha = 0
        #expect(!terminalView.isEffectivelyVisibleForMetalRendering)
    }
}
#endif
