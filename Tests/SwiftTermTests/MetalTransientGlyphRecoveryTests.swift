#if os(macOS) && canImport(MetalKit) && DEBUG
import AppKit
import Metal
import Testing
@testable import SwiftTerm

@MainActor
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct MetalTransientGlyphRecoveryTests {
    @MainActor
    private final class Fixture {
        let view: TerminalView
        let target: TerminalMetalLayerView
        let renderer: MetalTerminalRenderer
        let snapshot = TerminalSnapshot()
        let redraws = Locked(0)

        init(mode: MetalBufferingMode, text: String, font: NSFont? = nil) throws {
            let bounds = CGRect(x: 0, y: 0, width: 240, height: 90)
            let font = try #require(font ?? NSFont(name: "Menlo-Regular", size: 16))
            view = TerminalView(frame: bounds, font: font,
                                options: TerminalOptions(cols: 12, rows: 3))
            view.metalBufferingMode = mode
            view.caretViewTracksFocus = false
            view.customBlockGlyphs = true
            target = TerminalMetalLayerView(frame: bounds)
            target.renderContentsScale = view.metalRenderingScaleFactor()
            target.renderDrawableSize = CGSize(
                width: bounds.width * target.renderContentsScale,
                height: bounds.height * target.renderContentsScale)
            target.metalLayer.framebufferOnly = false
            renderer = try MetalTerminalRenderer(target: target)
            renderer.waitForCompletionAfterCommit = true
            renderer.capturesRenderedTexture = true
            let redraws = redraws
            renderer.requestRedraw = { redraws.withLock { $0 += 1 } }
            try feed("\u{1b}[?25l" + text)
        }

        var redrawCount: Int { redraws.withLock { $0 } }

        func feed(_ text: String) throws {
            view.feed(text: text)
            let state = FrameViewState(view: view)
            let result = view.withTerminal { terminal in
                snapshot.refresh(terminal: terminal, viewState: state,
                                 selection: SnapshotSelectionState(selection: view.selection))
            }
            try #require(result == .refreshed)
            try #require(!snapshot.rows.isEmpty)
        }

        func render() throws -> [UInt8] {
            let context = try #require(snapshot.renderContext)
            let before = renderer.completedRenders
            renderer.prepareSnapshotForImmediateDraw(snapshot: snapshot, context: context)
            let frame = try #require(target.acquireDrawableFrame())
            renderer.render(frame: frame)
            try #require(renderer.completedRenders == before + 1)
            try #require(renderer.waitForIdle())
            let texture = try #require(renderer.lastRenderedTexture)
            var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            pixels.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                                 from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                                 mipmapLevel: 0)
            }
            return pixels
        }
    }

    @Test(arguments: [MetalBufferingMode.perRowPersistent, .perFrameAggregated])
    func transientRowIsRebuiltWithoutASnapshotChange(mode: MetalBufferingMode) throws {
        let fixture = try Fixture(mode: mode, text: "A")
        defer { _ = fixture.view.updateUiClosed() }
        let original = try fixture.render()
        try fixture.feed("B")
        let revisions = fixture.snapshot.rows.map(\.revision)
        let generations = fixture.snapshot.rows.map(\.sourceGeneration)
        let rowCount = fixture.snapshot.rows.count

        fixture.renderer.forceContextCreationFailureForTesting = true
        let partial = try fixture.render()
        let preservedHealthyGlyph = partial == original
        #expect(preservedHealthyGlyph)
        #expect(fixture.redrawCount == 1)
        #expect(fixture.renderer.debugRowCacheCounts.rebuilt == 1)
        #expect(fixture.renderer.debugRowCacheCounts.cached == rowCount - 1)

        fixture.renderer.forceContextCreationFailureForTesting = false
        let recovered = try fixture.render()
        let missingGlyphRecovered = recovered != partial
        #expect(missingGlyphRecovered)
        #expect(fixture.renderer.debugRowCacheCounts.rebuilt == 1)
        #expect(fixture.renderer.debugRowCacheCounts.cached == rowCount - 1)
        #expect(fixture.redrawCount == 1)

        let cached = try fixture.render()
        let completeRowWasPreserved = cached == recovered
        #expect(completeRowWasPreserved)
        #expect(fixture.renderer.debugRowCacheCounts.rebuilt == 0)
        #expect(fixture.renderer.debugRowCacheCounts.cached == rowCount)
        #expect(fixture.snapshot.rows.map(\.revision) == revisions)
        #expect(fixture.snapshot.rows.map(\.sourceGeneration) == generations)
    }

    @Test(arguments: [MetalBufferingMode.perRowPersistent, .perFrameAggregated])
    func retriesAreBoundedButExternalFramesCanStillRecover(mode: MetalBufferingMode) throws {
        let fixture = try Fixture(mode: mode, text: "A")
        defer { _ = fixture.view.updateUiClosed() }
        fixture.renderer.forceContextCreationFailureForTesting = true
        let rowCount = fixture.snapshot.rows.count
        let revisions = fixture.snapshot.rows.map(\.revision)
        var partial: [UInt8] = []

        for attempt in 1...5 {
            partial = try fixture.render()
            #expect(fixture.redrawCount == min(attempt, 3))
            #expect(fixture.renderer.debugRowCacheCounts.rebuilt == (attempt == 1 ? rowCount : 1))
            // An abandoned frame before the build must not reset the budget.
            fixture.renderer.render()
            #expect(fixture.redrawCount == min(attempt, 3))
        }

        fixture.renderer.forceContextCreationFailureForTesting = false
        let recovered = try fixture.render()
        let missingGlyphRecovered = recovered != partial
        #expect(missingGlyphRecovered)
        #expect(fixture.renderer.debugRowCacheCounts.rebuilt == 1)
        #expect(fixture.redrawCount == 3)
        #expect(fixture.snapshot.rows.map(\.revision) == revisions)
        _ = try fixture.render()
        #expect(fixture.renderer.debugRowCacheCounts.rebuilt == 0)
        #expect(fixture.renderer.debugRowCacheCounts.cached == rowCount)

        // Use a new, uncached glyph so the next failure starts a new episode.
        try fixture.feed("B")
        fixture.renderer.forceContextCreationFailureForTesting = true
        _ = try fixture.render()
        #expect(fixture.redrawCount == 4)
        #expect(fixture.renderer.debugRowCacheCounts.rebuilt == 1)
    }

    @Test(arguments: [MetalBufferingMode.perRowPersistent, .perFrameAggregated])
    func stableEmptyGlyphsDoNotRequestRedraws(mode: MetalBufferingMode) throws {
        let fixture = try Fixture(mode: mode, text: "   \r\u{1b}[2 q\u{1b}[?25h")
        defer { _ = fixture.view.updateUiClosed() }
        let cursor = try #require(fixture.snapshot.cursor)
        try #require(!cursor.hidden)
        try #require(cursor.character == " ")
        try #require(fixture.snapshot.cursorStyle == .steadyBlock)
        let context = try #require(fixture.snapshot.renderContext)
        try #require(context.cursorHasFocus)
        fixture.renderer.forceContextCreationFailureForTesting = true

        for _ in 0..<4 {
            _ = try fixture.render()
            #expect(fixture.redrawCount == 0)
        }
        #expect(fixture.renderer.debugRowCacheCounts.rebuilt == 0)
        #expect(fixture.renderer.debugRowCacheCounts.cached == fixture.snapshot.rows.count)
    }

    @Test(arguments: [MetalBufferingMode.perRowPersistent, .perFrameAggregated])
    func oversizedAtlasGlyphDoesNotRequestRedraws(mode: MetalBufferingMode) throws {
        // Stretch only horizontally to exceed every atlas limit without
        // allocating a huge square bitmap or changing process-wide atlas caps.
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, 16, nil)
        var matrix = CGAffineTransform(scaleX: 4096, y: 1)
        let oversizedFont = CTFontCreateCopyWithAttributes(font, 16, &matrix, nil)
        var character: UniChar = 0x57
        var glyph: CGGlyph = 0
        try #require(CTFontGetGlyphsForCharacters(oversizedFont, &character, &glyph, 1))
        let metrics = GlyphMetrics.measure(font: oversizedFont, glyph: glyph)
        let fixture = try Fixture(mode: mode, text: "W", font: oversizedFont as NSFont)
        defer { _ = fixture.view.updateUiClosed() }
        let device = try #require(fixture.target.renderDevice)
        try #require(metrics.inkBounds.width > CGFloat(GlyphAtlas.maxTextureDimension(of: device)))
        try #require(fixture.snapshot.cols > 0)
        let row = try #require(fixture.snapshot.rows.first)
        try #require(row.text(at: 0, cell: row.line.packedView(at: 0)) == "W")

        _ = try fixture.render()
        #expect(fixture.redrawCount == 0)
        #expect(fixture.renderer.debugRowCacheCounts.rebuilt == fixture.snapshot.rows.count)
        fixture.renderer.forceContextCreationFailureForTesting = true
        _ = try fixture.render()
        #expect(fixture.redrawCount == 0)
        #expect(fixture.renderer.debugRowCacheCounts.rebuilt == 0)
        #expect(fixture.renderer.debugRowCacheCounts.cached == fixture.snapshot.rows.count)
    }

    @Test(arguments: [MetalBufferingMode.perRowPersistent, .perFrameAggregated])
    func cursorFailureRequestsARedrawWithoutEvictingRows(mode: MetalBufferingMode) throws {
        // The row uses the custom box-drawing path, but the block cursor shapes
        // this character with Core Text, so only the cursor can hit the fault.
        let fixture = try Fixture(mode: mode, text: "\u{2500}\r")
        defer { _ = fixture.view.updateUiClosed() }
        _ = try fixture.render()
        try fixture.feed("\u{1b}[2 q\u{1b}[?25h")
        let cursor = try #require(fixture.snapshot.cursor)
        try #require(!cursor.hidden && cursor.character == "\u{2500}")
        try #require(fixture.snapshot.cursorStyle == .steadyBlock)
        let revisions = fixture.snapshot.rows.map(\.revision)
        fixture.renderer.forceContextCreationFailureForTesting = true

        let partial = try fixture.render()
        #expect(fixture.redrawCount == 1)
        #expect(fixture.renderer.debugRowCacheCounts.rebuilt == 0)
        #expect(fixture.renderer.debugRowCacheCounts.cached == fixture.snapshot.rows.count)

        fixture.renderer.forceContextCreationFailureForTesting = false
        let recovered = try fixture.render()
        let cursorGlyphRecovered = recovered != partial
        #expect(cursorGlyphRecovered)
        #expect(fixture.redrawCount == 1)
        #expect(fixture.renderer.debugRowCacheCounts.rebuilt == 0)
        #expect(fixture.snapshot.rows.map(\.revision) == revisions)
    }
}
#endif
