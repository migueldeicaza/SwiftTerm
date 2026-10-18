#if os(iOS) && canImport(MetalKit)
import MetalKit
import Testing
@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct IOSMetalBackgroundOpacityTests {
    @Test func opacityChangesUpdateTheActiveMetalSurface() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        defer { view.frameDriver.invalidate() }
        view.backgroundOpacity = 1
        try view.setUseMetal(true)
        let surface = try #require(view.metalView)
        let delegate = try #require(surface.delegate)
        #expect(surface.isOpaque)
        #expect(surface.layer.isOpaque)

        // Change from solid to animated backgrounds, then back to solid.
        for opacity: CGFloat in [0, 0.5, 1, -1, 2] {
            view.backgroundOpacity = opacity
            let expectedOpacity = max(0, min(1, opacity))
            #expect(view.backgroundOpacity == expectedOpacity)
            #expect(surface.isOpaque == (expectedOpacity >= 1))
            #expect(surface.layer.isOpaque == (expectedOpacity >= 1))
            #expect(view.metalView === surface)
            #expect(surface.delegate === delegate)
        }
    }

    @Test(arguments: [CGFloat(0), 0.5, 1])
    func metalStartsWithTheCurrentBackgroundOpacity(_ opacity: CGFloat) throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        defer { view.frameDriver.invalidate() }
        view.backgroundOpacity = opacity

        try view.setUseMetal(true)

        let surface = try #require(view.metalView)
        #expect(surface.isOpaque == (opacity >= 1))
        #expect(surface.layer.isOpaque == (opacity >= 1))
    }
}
#endif
