#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
#if canImport(os)
import os
#endif
import CoreText
import Metal
import MetalKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct GlyphKey: Hashable {
    let fontName: String
    let size: CGFloat
    let glyph: CGGlyph
}

struct GlyphEntry {
    let region: AtlasRegion
    let size: CGSize
    let bearing: CGPoint
    let isColor: Bool
    let atlasKind: GlyphAtlasKind
}

enum GlyphAtlasKind {
    case grayscale
    case color
}

struct GlyphVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
    var color: SIMD4<Float>
}

struct ColorVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

struct TextCell {
    var position: SIMD2<Float>
    var size: SIMD2<Float>
    var texOrigin: SIMD2<Float>
    var texSize: SIMD2<Float>
    var color: SIMD4<Float>
}

struct ColorCell {
    var position: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
}

struct ImageDraw {
    let texture: MTLTexture
    let vertices: [GlyphVertex]
}

struct ImageDrawBuffer {
    let texture: MTLTexture
    let buffer: MTLBuffer
    let vertexCount: Int
}

struct RowDrawData {
    var backgroundCells: [ColorCell]
    var powerlineJoinCells: [ColorCell]
    var glyphCellsGray: [TextCell]
    var glyphCellsColor: [TextCell]
    var decorationCells: [ColorCell]
    var underImageDraws: [ImageDraw]
    var placeholderImageDraws: [ImageDraw]
    var overImageDraws: [ImageDraw]
    var otherImageDraws: [ImageDraw]
}

struct RowDrawBuffers {
    var backgroundBuffer: MTLBuffer?
    var backgroundCount: Int
    var powerlineJoinBuffer: MTLBuffer?
    var powerlineJoinCount: Int
    var glyphGrayBuffer: MTLBuffer?
    var glyphGrayCount: Int
    var glyphColorBuffer: MTLBuffer?
    var glyphColorCount: Int
    var decorationBuffer: MTLBuffer?
    var decorationCount: Int
    var underImageBuffers: [ImageDrawBuffer]
    var placeholderImageBuffers: [ImageDrawBuffer]
    var overImageBuffers: [ImageDrawBuffer]
    var otherImageBuffers: [ImageDrawBuffer]
}

struct RowCacheEntry {
    var sourceIdentity: ObjectIdentifier
    // Both are needed: snapshot Row.revision counters are per-Row-object, and
    // the snapshot's row pool can put a different Row (with an independently
    // colliding revision) at this screen index across refreshes. The source
    // generation pins the content; the revision pins style/bidi/image state.
    var sourceGeneration: UInt64
    var revision: UInt64
    var data: RowDrawData?
    var buffers: RowDrawBuffers?
}

struct FrameDrawData {
    var backgroundCells: [ColorCell]
    var powerlineJoinCells: [ColorCell]
    var glyphCellsGray: [TextCell]
    var glyphCellsColor: [TextCell]
    var decorationCells: [ColorCell]
    var underImageDraws: [ImageDraw]
    var placeholderImageDraws: [ImageDraw]
    var overImageDraws: [ImageDraw]
    var otherImageDraws: [ImageDraw]
}

struct DrawData {
    var rows: [RowDrawBuffers]
    var frame: FrameDrawData?
    var cursorColorVertices: [ColorVertex]
    var cursorGlyphVerticesGray: [GlyphVertex]
    var cursorGlyphVerticesColor: [GlyphVertex]
}

struct KittyImageSignature: Hashable {
    let kind: UInt8
    let width: Int
    let height: Int
    let byteCount: Int
    let headHash: UInt32
}

struct ClipRect {
    let minX: Float
    let minY: Float
    let maxX: Float
    let maxY: Float
}

struct CustomGlyphKey: Hashable {
    let codePoint: UInt32
    let cellWidthPx: Int
    let cellHeightPx: Int
    let baseThicknessPx: Int
    let scale: Int
    let antiAlias: Bool
}

struct CustomGlyphEntry {
    let region: AtlasRegion
    let size: CGSize
}

struct CustomGlyphBitmap {
    let width: Int
    let height: Int
    let pixels: [UInt8]
}

struct KittyCacheStamp: Hashable {
    let imagesCount: Int
    let placementsCount: Int
}

struct CacheSignature: Hashable {
    let scale: Double
    let cellWidth: Double
    let cellHeight: Double
    let viewWidth: Double
    let viewHeight: Double
    let yDisp: Int
    let rows: Int
    let cols: Int
    let fontName: String
    let fontSize: Double
    let isAltBuffer: Bool
    let kittyStamp: KittyCacheStamp
    let bidiHostPolicy: BidiHostPolicy
}

final class MetalTerminalRenderer: NSObject, MTKViewDelegate {
#if canImport(os)
    private static let profileLog = OSLog(subsystem: "org.tirania.SwiftTerm", category: "MetalProfile")
    private static let profileEnabled = ProcessInfo.processInfo.environment["SWIFTTERM_PROFILE"] == "1"
#endif
    private weak var terminalView: TerminalView?
    private weak var view: (any MetalRenderTarget)?
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textPipeline: MTLRenderPipelineState
    private let textGrayPipeline: MTLRenderPipelineState
    private let colorPipeline: MTLRenderPipelineState
    private let cellTextPipeline: MTLRenderPipelineState
    private let cellTextGrayPipeline: MTLRenderPipelineState
    private let cellColorPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let textureLoader: MTKTextureLoader
    private let bufferPool: BufferPool
    private let shaperCache = ShaperCache(maxEntries: 2048)
    private let grayscaleAtlas: GlyphAtlas
    private let colorAtlas: GlyphAtlas
    private let rasterizer = CoreTextGlyphRasterizer()
    private var glyphCache: [GlyphKey: GlyphEntry] = [:]
    private var scaledFontCache: [GlyphKey: CTFont] = [:]
    private var customGlyphCache: [CustomGlyphKey: CustomGlyphEntry] = [:]
    private let imageTextureCache = NSMapTable<AnyObject, MTLTexture>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var kittyTextureCache: [UInt32: (signature: KittyImageSignature, texture: MTLTexture)] = [:]
    private var rowCache: [Int: RowCacheEntry] = [:]
    private var cacheBufferingMode: MetalBufferingMode?
    private var cacheSignature: CacheSignature?
    private var atlasInvalidatedDuringBuild = false
    /// Lives on main; see `updateCursorBlinkTimer`.
    private var cursorBlinkTimer: Timer?
    /// Toggled by the blink timer on main, read while building a frame on the
    /// render loop. Guarded by `redrawLock`.
    private var cursorBlinkOn = true
    /// Whether the last frame asked for a blinking cursor. Guarded by
    /// `redrawLock`.
    private var cursorBlinkWanted = false
    private let frameSemaphore = DispatchSemaphore(value: 1)
    private var pendingRedraw = false
    private let redrawLock = NSLock()
    private var preparedSnapshot: (snapshot: TerminalSnapshot,
                                   context: SnapshotRenderContext)?

    /// Testing hook: block until the GPU finishes, so the drawable texture can
    /// be read back. Never set in production; a synchronous wait on the render
    /// path is exactly what this work is trying to remove.
    var waitForCompletionAfterCommit = false

    /// Frames actually submitted to the GPU.
    ///
    /// Distinct from the frame driver's tick count on purpose: a driver that
    /// ticks without drawing looks identical in the tick counter, which is how
    /// a spin loop once reported *better* numbers than the working path while
    /// the window sat frozen.
    /// Guarded by `redrawLock`: written on the render loop, read from main.
    private var completedRenderCount = 0

    var completedRenders: Int {
        get {
            redrawLock.lock()
            defer { redrawLock.unlock() }
            return completedRenderCount
        }
    }

    func resetRenderCounter() {
        redrawLock.lock()
        completedRenderCount = 0
        redrawLock.unlock()
    }

    /// Testing hook: retains the texture this renderer actually drew into.
    ///
    /// Necessary because asking the surface for a drawable a second time
    /// returns a *different* one from the pool, not the frame just rendered —
    /// comparing that instead silently compares uninitialised memory.
    var capturesRenderedTexture = false
    private(set) var lastRenderedTexture: MTLTexture?

    /// Asks the host to schedule a frame. A callback rather than a reference to
    /// the view's frame driver, so the renderer needs no view access
    /// (io-gaps.md G1, WO-F1c).
    var requestRedraw: (() -> Void)?

    /// The renderer's own text builder. Owning it, rather than calling into
    /// the view, is what frees this path from the main thread (io-gaps.md G1).
    /// It also means this cache is never shared with the Core Graphics path.
    private let textBuilder = SnapshotTextBuilder()
#if DEBUG
    private var debugFrameCount = 0
    private var debugLastLogTime = CFAbsoluteTimeGetCurrent()
    private var debugRowsRebuilt = 0
    private var debugRowsCached = 0

    var debugRowCacheCounts: (rebuilt: Int, cached: Int) {
        (debugRowsRebuilt, debugRowsCached)
    }
#endif
#if DEBUG
    private var imageTextureFailures: Set<ObjectIdentifier> = []
    private var kittyTextureFailures: Set<UInt32> = []
#endif

    init(view: any MetalRenderTarget, terminalView: TerminalView) throws {
        guard let device = view.renderDevice ?? MTLCreateSystemDefaultDevice() else {
            throw MetalError.deviceUnavailable
        }
        self.device = device
        var target = view
        target.renderDevice = device
        self.view = view
        self.textureLoader = MTKTextureLoader(device: device)
        self.bufferPool = BufferPool(device: device)
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalError.commandQueueUnavailable
        }
        self.commandQueue = commandQueue
        guard let grayscaleAtlas = GlyphAtlas(device: device,
                                              maxSize: GlyphAtlas.recommendedMaxSize(device: device, format: .grayscale),
                                              format: .grayscale),
              let colorAtlas = GlyphAtlas(device: device,
                                          maxSize: GlyphAtlas.recommendedMaxSize(device: device, format: .bgra),
                                          format: .bgra) else {
            throw MetalError.atlasUnavailable
        }
        self.grayscaleAtlas = grayscaleAtlas
        self.colorAtlas = colorAtlas
        let library = try MetalTerminalRenderer.makeLibrary(device: device)
        guard let textPipeline = MetalTerminalRenderer.makeTextPipeline(device: device,
                                                                        library: library,
                                                                        view: view,
                                                                        vertexName: "terminal_text_vertex",
                                                                        fragmentName: "terminal_text_fragment"),
              let textGrayPipeline = MetalTerminalRenderer.makeTextPipeline(device: device,
                                                                            library: library,
                                                                            view: view,
                                                                            vertexName: "terminal_text_vertex",
                                                                            fragmentName: "terminal_text_fragment_gray"),
              let cellTextPipeline = MetalTerminalRenderer.makeTextPipeline(device: device,
                                                                            library: library,
                                                                            view: view,
                                                                            vertexName: "terminal_cell_text_vertex",
                                                                            fragmentName: "terminal_text_fragment"),
              let cellTextGrayPipeline = MetalTerminalRenderer.makeTextPipeline(device: device,
                                                                                library: library,
                                                                                view: view,
                                                                                vertexName: "terminal_cell_text_vertex",
                                                                                fragmentName: "terminal_text_fragment_gray"),
              let colorPipeline = MetalTerminalRenderer.makeColorPipeline(device: device,
                                                                          library: library,
                                                                          view: view,
                                                                          vertexName: "terminal_color_vertex",
                                                                          fragmentName: "terminal_color_fragment"),
              let cellColorPipeline = MetalTerminalRenderer.makeColorPipeline(device: device,
                                                                              library: library,
                                                                              view: view,
                                                                              vertexName: "terminal_cell_color_vertex",
                                                                              fragmentName: "terminal_color_fragment") else {
            throw MetalError.pipelineCreationFailed("text/color/cell")
        }
        self.textPipeline = textPipeline
        self.textGrayPipeline = textGrayPipeline
        self.colorPipeline = colorPipeline
        self.cellTextPipeline = cellTextPipeline
        self.cellTextGrayPipeline = cellTextGrayPipeline
        self.cellColorPipeline = cellColorPipeline
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
            throw MetalError.samplerUnavailable
        }
        self.sampler = sampler
        self.terminalView = terminalView
        super.init()
    }

    deinit {
        cursorBlinkTimer?.invalidate()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // The view already updates drawableSize; avoid feedback loops.
    }

    func prepareSnapshotForImmediateDraw(snapshot: TerminalSnapshot,
                                         context: SnapshotRenderContext) {
        preparedSnapshot = (snapshot, context)
    }

    func discardPreparedSnapshot() {
        preparedSnapshot = nil
    }

    /// `MTKViewDelegate` entry point. Kept thin: everything below works
    /// against `MetalRenderTarget`, so a surface we drive ourselves can call
    /// `render()` directly (io-gaps.md G1).
    func draw(in view: MTKView) {
        render()
    }

    /// Renders one frame into the current target.
    func render() {
        guard let view = self.view else { return }
        // Same event as the Core Graphics draw: only one renderer is active at
        // a time, and the report names which. Needed to compare the two paths
        // and to grade io-gaps.md G1.
        let drawInterval = Profiling.begin(.frameDraw)
        defer { drawInterval.end() }

#if canImport(os)
        let drawID = OSSignpostID(log: MetalTerminalRenderer.profileLog)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.begin, log: MetalTerminalRenderer.profileLog, name: "Metal.Draw", signpostID: drawID)
        }
        defer {
            if MetalTerminalRenderer.profileEnabled {
                os_signpost(.end, log: MetalTerminalRenderer.profileLog, name: "Metal.Draw", signpostID: drawID)
            }
        }
#endif
        if frameSemaphore.wait(timeout: .now()) != .success {
            markPendingRedraw()
            return
        }
        guard let terminalView = terminalView else {
            frameSemaphore.signal()
            return
        }
        let refreshed: (snapshot: TerminalSnapshot, context: SnapshotRenderContext)
        if let preparedSnapshot {
            refreshed = preparedSnapshot
            self.preparedSnapshot = nil
        } else if let fallback = terminalView.refreshSnapshotForMetal() {
            refreshed = fallback
        } else {
            frameSemaphore.signal()
            return
        }
        let snapshot = refreshed.snapshot
        let renderContext = refreshed.context
#if os(macOS)
        rasterizer.fontSmoothing = renderContext.fontSmoothing
        let scale = renderContext.renderingScale
#else
        let scale = renderContext.renderingScale
#endif
        let drawableSize = CGSize(width: renderContext.viewBounds.width * scale,
                                  height: renderContext.viewBounds.height * scale)
#if canImport(os)
        let drawableID = OSSignpostID(log: MetalTerminalRenderer.profileLog)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.begin, log: MetalTerminalRenderer.profileLog, name: "Metal.CurrentDrawable", signpostID: drawableID)
        }
#endif
        let drawableInterval = Profiling.begin(.metalDrawable)
        let drawable = view.acquireDrawable()
        drawableInterval.end()
#if canImport(os)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.end, log: MetalTerminalRenderer.profileLog, name: "Metal.CurrentDrawable", signpostID: drawableID)
        }
#endif

#if canImport(os)
        let passID = OSSignpostID(log: MetalTerminalRenderer.profileLog)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.begin, log: MetalTerminalRenderer.profileLog, name: "Metal.RenderPass", signpostID: passID)
        }
#endif
        let passDescriptor = drawable.map { view.makeRenderPassDescriptor(for: $0) } ?? nil
#if canImport(os)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.end, log: MetalTerminalRenderer.profileLog, name: "Metal.RenderPass", signpostID: passID)
        }
#endif
        guard let drawable, let passDescriptor else {
            markPendingRedraw()
            frameSemaphore.signal()
            return
        }
#if canImport(os)
        let buildID = OSSignpostID(log: MetalTerminalRenderer.profileLog)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.begin, log: MetalTerminalRenderer.profileLog, name: "Metal.BuildDrawData", signpostID: buildID)
        }
#endif
        let shouldBlink = isBlinkStyle(snapshot.cursorStyle)
            && snapshot.cursor?.hidden == false
            && renderContext.cursorHasFocus
        updateCursorBlinkTimer(shouldBlink: shouldBlink)
        let buildInterval = Profiling.begin(.metalBuildDrawData)
        let drawData = buildDrawData(snapshot: snapshot, context: renderContext)
        buildInterval.end()
#if canImport(os)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.end, log: MetalTerminalRenderer.profileLog, name: "Metal.BuildDrawData", signpostID: buildID)
        }
#endif
#if DEBUG
        debugFrameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - debugLastLogTime
        if elapsed >= 1.0 {
            let totalRows = debugRowsRebuilt + debugRowsCached
            let fps = Double(debugFrameCount) / elapsed
            print(String(format: "Metal FPS: %.1f (rows rebuilt: %d/%d)", fps, debugRowsRebuilt, totalRows))
            debugFrameCount = 0
            debugLastLogTime = now
        }
#endif
        let encodeInterval = Profiling.begin(.metalEncode)
        defer { encodeInterval.end() }
        let bgColor = colorToSIMD(renderContext.effectiveBackgroundColor)
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(Double(bgColor.x),
                                                                         Double(bgColor.y),
                                                                         Double(bgColor.z),
                                                                         Double(bgColor.w))
        passDescriptor.colorAttachments[0].loadAction = .clear

#if canImport(os)
        let encodeID = OSSignpostID(log: MetalTerminalRenderer.profileLog)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.begin, log: MetalTerminalRenderer.profileLog, name: "Metal.Encode", signpostID: encodeID)
        }
#endif
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
#if canImport(os)
            if MetalTerminalRenderer.profileEnabled {
                os_signpost(.end, log: MetalTerminalRenderer.profileLog, name: "Metal.Encode", signpostID: encodeID)
            }
#endif
            frameSemaphore.signal()
            return
        }
        let frameSemaphore = self.frameSemaphore
        commandBuffer.addCompletedHandler { [weak self, weak view] _ in
            frameSemaphore.signal()
            // Fires on a Metal thread the moment the frame is done, which is
            // the closest thing to "the glyph is on screen" available without
            // a display-link correlation.
            TerminalView.onFramePresented?()
            guard let self, let view else {
                return
            }
            if self.consumePendingRedraw() {
                DispatchQueue.main.async {
                    view.requestDisplay()
                }
            }
        }
        bufferPool.beginFrame()
        let viewport = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))

        if let frame = drawData.frame {
            drawFrameData(frame, encoder: encoder, viewport: viewport)
        } else {
            let rows = drawData.rows
            drawVertexBuffers(rows: rows,
                              bufferKey: \.backgroundBuffer,
                              countKey: \.backgroundCount,
                              pipeline: cellColorPipeline,
                              texture: nil,
                              encoder: encoder,
                              viewport: viewport)

            drawImageRows(rows: rows,
                          imageKey: \.underImageBuffers,
                          encoder: encoder,
                          viewport: viewport)

            drawVertexBuffers(rows: rows,
                              bufferKey: \.powerlineJoinBuffer,
                              countKey: \.powerlineJoinCount,
                              pipeline: cellColorPipeline,
                              texture: nil,
                              encoder: encoder,
                              viewport: viewport)

            drawVertexBuffers(rows: rows,
                              bufferKey: \.glyphGrayBuffer,
                              countKey: \.glyphGrayCount,
                              pipeline: cellTextGrayPipeline,
                              texture: grayscaleAtlas.texture,
                              encoder: encoder,
                              viewport: viewport)

            drawVertexBuffers(rows: rows,
                              bufferKey: \.glyphColorBuffer,
                              countKey: \.glyphColorCount,
                              pipeline: cellTextPipeline,
                              texture: colorAtlas.texture,
                              encoder: encoder,
                              viewport: viewport)

            drawVertexBuffers(rows: rows,
                              bufferKey: \.decorationBuffer,
                              countKey: \.decorationCount,
                              pipeline: cellColorPipeline,
                              texture: nil,
                              encoder: encoder,
                              viewport: viewport)

            drawImageRows(rows: rows,
                          imageKey: \.placeholderImageBuffers,
                          encoder: encoder,
                          viewport: viewport)
            drawImageRows(rows: rows,
                          imageKey: \.overImageBuffers,
                          encoder: encoder,
                          viewport: viewport)
            drawImageRows(rows: rows,
                          imageKey: \.otherImageBuffers,
                          encoder: encoder,
                          viewport: viewport)
        }

        if !drawData.cursorColorVertices.isEmpty {
            if let buffer = makeBuffer(drawData.cursorColorVertices) {
                encoder.setRenderPipelineState(colorPipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                var viewportVar = viewport
                encoder.setVertexBytes(&viewportVar, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: drawData.cursorColorVertices.count)
            }
        }

        if !drawData.cursorGlyphVerticesGray.isEmpty {
            if let buffer = makeBuffer(drawData.cursorGlyphVerticesGray) {
                encoder.setRenderPipelineState(textGrayPipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                var viewportVar = viewport
                encoder.setVertexBytes(&viewportVar, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                encoder.setFragmentTexture(grayscaleAtlas.texture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: drawData.cursorGlyphVerticesGray.count)
            }
        }

        if !drawData.cursorGlyphVerticesColor.isEmpty {
            if let buffer = makeBuffer(drawData.cursorGlyphVerticesColor) {
                encoder.setRenderPipelineState(textPipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                var viewportVar = viewport
                encoder.setVertexBytes(&viewportVar, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                encoder.setFragmentTexture(colorAtlas.texture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: drawData.cursorGlyphVerticesColor.count)
            }
        }

        encoder.endEncoding()
#if canImport(os)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.end, log: MetalTerminalRenderer.profileLog, name: "Metal.Encode", signpostID: encodeID)
        }
        let commitID = OSSignpostID(log: MetalTerminalRenderer.profileLog)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.begin, log: MetalTerminalRenderer.profileLog, name: "Metal.Commit", signpostID: commitID)
        }
#endif
        redrawLock.lock()
        completedRenderCount += 1
        redrawLock.unlock()
        if capturesRenderedTexture {
            lastRenderedTexture = drawable.texture
        }
        commandBuffer.present(drawable)
        bufferPool.commit(commandBuffer: commandBuffer)
        commandBuffer.commit()
        if waitForCompletionAfterCommit {
            // Testing only: makes the drawable texture readable right after
            // render() returns, so a test can compare what two surfaces
            // actually produced.
            commandBuffer.waitUntilCompleted()
        }
#if canImport(os)
        if MetalTerminalRenderer.profileEnabled {
            os_signpost(.end, log: MetalTerminalRenderer.profileLog, name: "Metal.Commit", signpostID: commitID)
        }
#endif
    }


    private func markPendingRedraw() {
        redrawLock.lock()
        pendingRedraw = true
        redrawLock.unlock()
    }

    private func consumePendingRedraw() -> Bool {
        redrawLock.lock()
        let needsRedraw = pendingRedraw
        pendingRedraw = false
        redrawLock.unlock()
        return needsRedraw
    }

    /// Worst case before the working set is stable: a few grows
    /// (1024 -> ... -> maxSize) can invalidate passes, then one reset, and
    /// finally one frozen pass that is guaranteed not to invalidate.
    private static let maxAtlasRebuildPasses = 5

    private func buildDrawData(snapshot: TerminalSnapshot,
                               context: SnapshotRenderContext) -> DrawData {
        defer {
            grayscaleAtlas.frozen = false
            colorAtlas.frozen = false
        }
        var attempt = 0
        while true {
            if attempt == Self.maxAtlasRebuildPasses {
                // Final pass: no grow/reset allowed. Glyphs that do not fit
                // are skipped (rendered blank) instead of invalidating the
                // regions this pass has already referenced.
                GlyphAtlas.log.fault("glyph working set exceeds max atlas capacity; some glyphs will be skipped this frame")
                grayscaleAtlas.frozen = true
                colorAtlas.frozen = true
            }
            atlasInvalidatedDuringBuild = false
            let result = buildDrawDataPass(snapshot: snapshot, context: context)
            if !atlasInvalidatedDuringBuild || attempt >= Self.maxAtlasRebuildPasses {
                return result
            }
            // The invalidation site flushed the caches, but the row being
            // built when it struck mixes pre- and post-invalidation UVs and
            // was cached after the flush along with the rows that followed.
            // Drop them all so the retry pass rebuilds every row.
            rowCache.removeAll()
            attempt += 1
            GlyphAtlas.log.info("glyph atlas changed during frame build; rebuild pass \(attempt)/\(Self.maxAtlasRebuildPasses)")
        }
    }

    private func buildDrawDataPass(snapshot: TerminalSnapshot,
                                   context: SnapshotRenderContext) -> DrawData {
        guard terminalView != nil else {
#if DEBUG
            debugRowsRebuilt = 0
            debugRowsCached = 0
#endif
            return DrawData(rows: [],
                            frame: nil,
                            cursorColorVertices: [],
                            cursorGlyphVerticesGray: [],
                            cursorGlyphVerticesColor: [])
        }
        pruneKittyTextureCache(kitty: snapshot.kitty)
        let scale = context.renderingScale
        let cellWidth = context.cellDimension.width
        let cellHeight = context.cellDimension.height
        let lineDescent = CTFontGetDescent(context.fonts.normal)
        let lineLeading = CTFontGetLeading(context.fonts.normal)
        let yOffset = ceil(lineDescent + lineLeading)
        let viewWidthPx = context.viewBounds.width * scale

        let rowInfo = visibleRowRange(snapshot: snapshot)
        guard let (firstRow, lastRow, visibleDisp) = rowInfo else {
#if DEBUG
            debugRowsRebuilt = 0
            debugRowsCached = 0
#endif
            return DrawData(rows: [],
                            frame: nil,
                            cursorColorVertices: [],
                            cursorGlyphVerticesGray: [],
                            cursorGlyphVerticesColor: [])
        }
        let bufferingMode = context.metalBufferingMode
        if cacheBufferingMode != bufferingMode {
            if bufferingMode == .perFrameAggregated {
                for (key, var entry) in rowCache {
                    entry.buffers = nil
                    rowCache[key] = entry
                }
            }
            cacheBufferingMode = bufferingMode
        }
        let kittyStamp = KittyCacheStamp(imagesCount: snapshot.kitty.imagesById.count,
                                         placementsCount: snapshot.kitty.placementsByKey.count)
        let signature = CacheSignature(scale: Double(scale),
                                       cellWidth: Double(cellWidth),
                                       cellHeight: Double(cellHeight),
                                       viewWidth: Double(context.viewBounds.width),
                                       viewHeight: Double(context.viewBounds.height),
                                       yDisp: visibleDisp,
                                       rows: snapshot.rowCount,
                                       cols: snapshot.cols,
                                       fontName: context.fonts.normal.fontName,
                                       fontSize: Double(context.fonts.normal.pointSize),
                                       isAltBuffer: snapshot.isAltBuffer,
                                       kittyStamp: kittyStamp,
                                       bidiHostPolicy: context.bidiHostPolicy)
        let signatureChanged = signature != cacheSignature
        if signatureChanged {
            rowCache.removeAll()
            cacheSignature = signature
        }

        let visibleRange = firstRow...lastRow
        if !rowCache.isEmpty {
            rowCache = rowCache.filter { visibleRange.contains($0.key) }
        }

        let needsFullRebuild = signatureChanged || rowCache.isEmpty

        var rows: [RowDrawBuffers] = []
        var frameData: FrameDrawData?
        if bufferingMode == .perFrameAggregated {
            frameData = FrameDrawData(backgroundCells: [],
                                      powerlineJoinCells: [],
                                      glyphCellsGray: [],
                                      glyphCellsColor: [],
                                      decorationCells: [],
                                      underImageDraws: [],
                                      placeholderImageDraws: [],
                                      overImageDraws: [],
                                      otherImageDraws: [])
        }

        var rebuiltRows = 0
        var cachedRows = 0
        for absoluteRow in visibleRange {
            guard let snapshotRow = snapshot.row(atAbsolute: absoluteRow) else {
                continue
            }
            let sourceIdentity = ObjectIdentifier(snapshotRow.sourceLine!)
            var entry = rowCache[absoluteRow]
            let cacheValid = entry?.sourceIdentity == sourceIdentity &&
                entry?.sourceGeneration == snapshotRow.sourceGeneration &&
                entry?.revision == snapshotRow.revision
            let needsRebuild = needsFullRebuild ||
                !cacheValid ||
                (bufferingMode == .perFrameAggregated && entry?.data == nil)
            let rowBuffers: RowDrawBuffers?
            let rowData: RowDrawData
            if needsRebuild {
                let rowInterval = Profiling.begin(.metalRowBuild)
                defer { rowInterval.end() }
                rowData = buildRowDrawData(row: snapshotRow,
                                           absoluteRow: absoluteRow,
                                           snapshot: snapshot,
                                           context: context,
                                           yDisp: visibleDisp,
                                           cellWidth: cellWidth,
                                           cellHeight: cellHeight,
                                           yOffset: yOffset,
                                           viewWidthPx: viewWidthPx,
                                           scale: scale)
                let buffers = bufferingMode == .perRowPersistent ? makeRowBuffers(from: rowData) : nil
                entry = RowCacheEntry(sourceIdentity: sourceIdentity,
                                      sourceGeneration: snapshotRow.sourceGeneration,
                                      revision: snapshotRow.revision,
                                      data: rowData, buffers: buffers)
                rowCache[absoluteRow] = entry
                rowBuffers = buffers
                rebuiltRows += 1
            } else if let cached = entry {
                rowData = cached.data ?? buildRowDrawData(row: snapshotRow,
                                                          absoluteRow: absoluteRow,
                                                          snapshot: snapshot,
                                                          context: context,
                                                          yDisp: visibleDisp,
                                                          cellWidth: cellWidth,
                                                          cellHeight: cellHeight,
                                                          yOffset: yOffset,
                                                          viewWidthPx: viewWidthPx,
                                                          scale: scale)
                if cached.data == nil {
                    entry = RowCacheEntry(sourceIdentity: sourceIdentity,
                                          sourceGeneration: snapshotRow.sourceGeneration,
                                          revision: snapshotRow.revision,
                                          data: rowData, buffers: cached.buffers)
                    rowCache[absoluteRow] = entry
                }
                if bufferingMode == .perRowPersistent {
                    if let buffers = cached.buffers {
                        rowBuffers = buffers
                    } else {
                        let buffers = makeRowBuffers(from: rowData)
                        entry?.buffers = buffers
                        rowCache[absoluteRow] = entry
                        rowBuffers = buffers
                    }
                } else {
                    rowBuffers = nil
                }
                cachedRows += 1
            } else {
                continue
            }
            if let rowBuffers {
                rows.append(rowBuffers)
            }
            if bufferingMode == .perFrameAggregated {
                if var currentFrame = frameData {
                    currentFrame.backgroundCells.append(contentsOf: rowData.backgroundCells)
                    currentFrame.powerlineJoinCells.append(contentsOf: rowData.powerlineJoinCells)
                    currentFrame.glyphCellsGray.append(contentsOf: rowData.glyphCellsGray)
                    currentFrame.glyphCellsColor.append(contentsOf: rowData.glyphCellsColor)
                    currentFrame.decorationCells.append(contentsOf: rowData.decorationCells)
                    currentFrame.underImageDraws.append(contentsOf: rowData.underImageDraws)
                    currentFrame.placeholderImageDraws.append(contentsOf: rowData.placeholderImageDraws)
                    currentFrame.overImageDraws.append(contentsOf: rowData.overImageDraws)
                    currentFrame.otherImageDraws.append(contentsOf: rowData.otherImageDraws)
                    frameData = currentFrame
                }
            }
        }
#if DEBUG
        debugRowsRebuilt = rebuiltRows
        debugRowsCached = cachedRows
#endif

        let cursorData = buildCursorDrawData(snapshot: snapshot,
                                             context: context,
                                             scale: scale,
                                             cellWidth: cellWidth,
                                             cellHeight: cellHeight,
                                             lineDescent: lineDescent,
                                             lineLeading: lineLeading,
                                             yDisp: visibleDisp,
                                             firstRow: firstRow,
                                             lastRow: lastRow)

        return DrawData(rows: rows,
                        frame: frameData,
                        cursorColorVertices: cursorData.colorVertices,
                        cursorGlyphVerticesGray: cursorData.glyphVerticesGray,
                        cursorGlyphVerticesColor: cursorData.glyphVerticesColor)
    }

    private func visibleRowRange(snapshot: TerminalSnapshot) -> (Int, Int, Int)? {
        guard snapshot.linesCount > 0, snapshot.rowCount > 0,
              !snapshot.rows.isEmpty else {
            return nil
        }
        let firstRow = snapshot.firstRow
        let lastRow = min(snapshot.linesCount - 1,
                          firstRow + min(snapshot.rowCount, snapshot.rows.count) - 1)
        guard firstRow <= lastRow else { return nil }
        return (firstRow, lastRow, snapshot.yDisp)
    }

    private func buildRowDrawData(row: TerminalSnapshot.Row,
                                  absoluteRow: Int,
                                  snapshot: TerminalSnapshot,
                                  context: SnapshotRenderContext,
                                  yDisp: Int,
                                  cellWidth: CGFloat,
                                  cellHeight: CGFloat,
                                  yOffset: CGFloat,
                                  viewWidthPx: CGFloat,
                                  scale: CGFloat) -> RowDrawData {
        guard let terminalView = terminalView else {
            return RowDrawData(backgroundCells: [],
                               powerlineJoinCells: [],
                               glyphCellsGray: [],
                               glyphCellsColor: [],
                               decorationCells: [],
                               underImageDraws: [],
                               placeholderImageDraws: [],
                               overImageDraws: [],
                               otherImageDraws: [])
        }
        var backgroundCells: [ColorCell] = []
        var powerlineJoinCells: [ColorCell] = []
        var glyphCellsGray: [TextCell] = []
        var glyphCellsColor: [TextCell] = []
        var decorationCells: [ColorCell] = []
        var underImageDraws: [ImageDraw] = []
        var placeholderImageDraws: [ImageDraw] = []
        var overImageDraws: [ImageDraw] = []
        var otherImageDraws: [ImageDraw] = []

        let line = row.line
        let renderMode = line.renderMode
        let lineOffset = cellHeight * CGFloat(absoluteRow - yDisp + 1)
        let lineOrigin = CGPoint(x: 0, y: context.viewBounds.height - lineOffset)
        let rowBase = lineOrigin.y + cellHeight
        let attrInterval = Profiling.begin(.rowAttributedString)
        let lineInfo = textBuilder.buildAttributedString(row: row,
                                                         absoluteRow: absoluteRow,
                                                         context: context)
        attrInterval.end()
        let shapeInterval = Profiling.begin(.rowShape)
        let shapedSegments = buildShapedSegments(lineInfo.segments, context: context)
        shapeInterval.end()
        let lineOriginPx = CGPoint(x: lineOrigin.x * scale, y: lineOrigin.y * scale)
        let cellWidthPx = cellWidth * scale
        let cellHeightPx = cellHeight * scale
        let baseCellWidthPx = max(1, Int(round(cellWidthPx)))
        let baseCellHeightPx = max(1, Int(round(cellHeightPx)))
        let clipRect: ClipRect? = {
            switch renderMode {
            case .doubledDown, .doubledTop:
                return ClipRect(minX: 0,
                                minY: Float(lineOriginPx.y),
                                maxX: Float(viewWidthPx),
                                maxY: Float(lineOriginPx.y + cellHeightPx))
            case .single, .doubleWidth:
                return nil
            }
        }()
        let pivotY: CGFloat = {
            switch renderMode {
            case .doubledDown:
                return lineOrigin.y * scale
            case .doubledTop:
                return (lineOrigin.y + cellHeight) * scale
            case .single, .doubleWidth:
                return 0
            }
        }()
        let underlinePosition = context.fonts.underlinePosition()
        let underlineThickness = max(round(scale * context.fonts.underlineThickness()) / scale, 0.5)
        let decorationCellWidth = ceil(cellWidth)

        if !lineInfo.boxDrawings.isEmpty || !lineInfo.blockElements.isEmpty || !lineInfo.powerlineGlyphs.isEmpty {
            let boxThicknessScale: CGFloat = 1.35
            let minThicknessPx = max(1, Int(round(scale)))
            let baseThicknessPx = max(minThicknessPx,
                                      Int(round(scale * context.fonts.underlineThickness() * boxThicknessScale)))
            let antiAliasBlocks = context.antiAliasCustomBlockGlyphs

            for item in lineInfo.boxDrawings {
                let itemWidthPx = baseCellWidthPx * item.columnWidth
                guard let entry = customGlyphEntry(codePoint: item.codePoint,
                                                   cellWidthPx: itemWidthPx,
                                                   cellHeightPx: baseCellHeightPx,
                                                   scale: scale,
                                                   baseThicknessPx: baseThicknessPx,
                                                   antiAlias: false) else {
                    continue
                }
                let atlasSize = Float(grayscaleAtlas.size)
                let u0 = Float(entry.region.x) / atlasSize
                let v0 = Float(entry.region.y) / atlasSize
                let u1 = Float(entry.region.x + entry.region.width) / atlasSize
                let v1 = Float(entry.region.y + entry.region.height) / atlasSize
                let alignedOriginX = round(lineOriginPx.x)
                let alignedOriginY = round(lineOriginPx.y)
                let x0 = alignedOriginX + CGFloat(item.column * baseCellWidthPx)
                let y0 = alignedOriginY
                let x1 = x0 + CGFloat(itemWidthPx)
                let placementHeightPx = antiAliasBlocks ? cellHeightPx : CGFloat(baseCellHeightPx)
                let y1 = y0 + placementHeightPx
                let (tx0, ty0, tx1, ty1) = transformRect(x0: x0, y0: y0, x1: x1, y1: y1)
                if let clipped = self.clipRect(tx0, ty0, tx1, ty1, u0, v0, u1, v1, clipRect) {
                    let color = colorToSIMD(item.foregroundColor)
                    glyphCellsGray.append(makeTextCell(x0: clipped.x0,
                                                       y0: clipped.y0,
                                                       x1: clipped.x1,
                                                       y1: clipped.y1,
                                                       u0: clipped.u0,
                                                       v0: clipped.v0,
                                                       u1: clipped.u1,
                                                       v1: clipped.v1,
                                                       color: color))
                }
            }

            for element in lineInfo.blockElements {
                let itemWidthPx: Int
                if antiAliasBlocks {
                    itemWidthPx = max(1, Int(round(cellWidthPx * CGFloat(element.columnWidth))))
                } else {
                    itemWidthPx = baseCellWidthPx * element.columnWidth
                }
                guard let entry = customGlyphEntry(codePoint: element.codePoint,
                                                   cellWidthPx: itemWidthPx,
                                                   cellHeightPx: baseCellHeightPx,
                                                   scale: scale,
                                                   baseThicknessPx: 0,
                                                   antiAlias: antiAliasBlocks) else {
                    continue
                }
                let atlasSize = Float(grayscaleAtlas.size)
                let u0 = Float(entry.region.x) / atlasSize
                let v0 = Float(entry.region.y) / atlasSize
                let u1 = Float(entry.region.x + entry.region.width) / atlasSize
                let v1 = Float(entry.region.y + entry.region.height) / atlasSize
                let originX: CGFloat
                let originY: CGFloat
                if antiAliasBlocks {
                    originX = lineOriginPx.x + CGFloat(element.column) * cellWidthPx
                    originY = lineOriginPx.y
                } else {
                    let alignedOriginX = round(lineOriginPx.x)
                    let alignedOriginY = round(lineOriginPx.y)
                    originX = alignedOriginX + CGFloat(element.column * baseCellWidthPx)
                    originY = alignedOriginY
                }
                let x0 = originX
                let y0 = originY
                let placementWidthPx = antiAliasBlocks ? (cellWidthPx * CGFloat(element.columnWidth)) : CGFloat(itemWidthPx)
                let x1 = x0 + placementWidthPx
                let y1 = y0 + CGFloat(baseCellHeightPx)
                let (tx0, ty0, tx1, ty1) = transformRect(x0: x0, y0: y0, x1: x1, y1: y1)
                if let clipped = self.clipRect(tx0, ty0, tx1, ty1, u0, v0, u1, v1, clipRect) {
                    let color = colorToSIMD(element.foregroundColor)
                    glyphCellsGray.append(makeTextCell(x0: clipped.x0,
                                                       y0: clipped.y0,
                                                       x1: clipped.x1,
                                                       y1: clipped.y1,
                                                       u0: clipped.u0,
                                                       v0: clipped.v0,
                                                       u1: clipped.u1,
                                                       v1: clipped.v1,
                                                       color: color))
                }
            }

            for item in lineInfo.powerlineGlyphs {
                let itemWidthPx = baseCellWidthPx * item.columnWidth
                guard let entry = customGlyphEntry(codePoint: item.codePoint,
                                                   cellWidthPx: itemWidthPx,
                                                   cellHeightPx: baseCellHeightPx,
                                                   scale: scale,
                                                   baseThicknessPx: 0,
                                                   antiAlias: true) else {
                    continue
                }
                let atlasSize = Float(grayscaleAtlas.size)
                let u0 = Float(entry.region.x) / atlasSize
                let v0 = Float(entry.region.y) / atlasSize
                let u1 = Float(entry.region.x + entry.region.width) / atlasSize
                let v1 = Float(entry.region.y + entry.region.height) / atlasSize
                let alignedOriginX = round(lineOriginPx.x) + CGFloat(item.column * baseCellWidthPx)
                let alignedOriginY = round(lineOriginPx.y)
                let x0 = alignedOriginX
                let y0 = alignedOriginY
                let x1 = x0 + entry.size.width
                let y1 = y0 + entry.size.height
                let (tx0, ty0, tx1, ty1) = transformRect(x0: x0, y0: y0, x1: x1, y1: y1)
                if let clipped = self.clipRect(tx0, ty0, tx1, ty1, u0, v0, u1, v1, clipRect) {
                    let color = colorToSIMD(item.foregroundColor)
                    glyphCellsGray.append(makeTextCell(x0: clipped.x0,
                                                       y0: clipped.y0,
                                                       x1: clipped.x1,
                                                       y1: clipped.y1,
                                                       u0: clipped.u0,
                                                       v0: clipped.v0,
                                                       u1: clipped.u1,
                                                       v1: clipped.v1,
                                                       color: color))
                }
                // Add the joining edge after the DEC line transform so it is
                // exactly one final device pixel even for 2x line modes.
                let transformedCellRect = CGRect(x: CGFloat(min(tx0, tx1)),
                                                 y: CGFloat(min(ty0, ty1)),
                                                 width: CGFloat(abs(tx1 - tx0)),
                                                 height: CGFloat(abs(ty1 - ty0)))
                if let joinRect = PowerlineRenderer.devicePixelJoinRect(codePoint: item.codePoint,
                                                                        transformedCellRect: transformedCellRect),
                   let clippedJoin = self.clipRect(Float(joinRect.minX),
                                                   Float(joinRect.minY),
                                                   Float(joinRect.maxX),
                                                   Float(joinRect.maxY),
                                                   clipRect) {
                    powerlineJoinCells.append(makeColorCell(x0: clippedJoin.0,
                                                            y0: clippedJoin.1,
                                                            x1: clippedJoin.2,
                                                            y1: clippedJoin.3,
                                                            color: colorToSIMD(item.foregroundColor)))
                }
            }
        }

        func transformPoint(_ point: CGPoint) -> CGPoint {
            switch renderMode {
            case .single:
                return point
            case .doubleWidth:
                return CGPoint(x: point.x * 2, y: point.y)
            case .doubledDown, .doubledTop:
                return CGPoint(x: point.x * 2, y: pivotY + (point.y - pivotY) * 2)
            }
        }

        func transformRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> (Float, Float, Float, Float) {
            let p0 = transformPoint(CGPoint(x: x0, y: y0))
            let p1 = transformPoint(CGPoint(x: x1, y: y1))
            let minX = min(p0.x, p1.x)
            let minY = min(p0.y, p1.y)
            let maxX = max(p0.x, p1.x)
            let maxY = max(p0.y, p1.y)
            return (Float(minX), Float(minY), Float(maxX), Float(maxY))
        }

        for shaped in shapedSegments {
            for run in shaped.runs {
                let runGlyphsCount = run.shaperRun.glyphCount
                if runGlyphsCount == 0 {
                    continue
                }
                let runAttributes = run.attributes
                var minOrdinal = Int.max
                var maxOrdinal = Int.min
                for index in run.shaperRun.stringIndices {
                    let ordinal = shaped.segment.cellOrdinal(forUTF16: run.utf16Offset + index)
                    minOrdinal = min(minOrdinal, ordinal)
                    maxOrdinal = max(maxOrdinal, ordinal)
                }
                let startColumn = shaped.segment.column + (minOrdinal * shaped.segment.columnWidth)
                let endColumn = shaped.segment.column + ((maxOrdinal + 1) * shaped.segment.columnWidth)
                var backgroundColor: TTColor?
                if runAttributes.keys.contains(.selectionBackgroundColor) {
                    backgroundColor = runAttributes[.selectionBackgroundColor] as? TTColor
                } else if runAttributes.keys.contains(.backgroundColor) {
                    backgroundColor = runAttributes[.backgroundColor] as? TTColor
                }
                    // Runs carrying the default background emit no quad: the
                    // pass's clear color already paints it (including the
                    // margins), and a quad on top would double-composite when
                    // the background is translucent (backgroundOpacity < 1)
                    if let backgroundColor = backgroundColor,
                       backgroundColor != context.effectiveBackgroundColor {
                        let columnSpan = max(0, endColumn - startColumn)
                        if columnSpan > 0 {
                            let x0 = lineOriginPx.x + (CGFloat(startColumn) * cellWidthPx)
                            let y0 = lineOriginPx.y
                            let x1 = lineOriginPx.x + (CGFloat(startColumn + columnSpan) * cellWidthPx)
                            let y1 = lineOriginPx.y + cellHeightPx
                            let (tx0, ty0, tx1, ty1) = transformRect(x0: x0, y0: y0, x1: x1, y1: y1)
                            if let clipped = self.clipRect(tx0, ty0, tx1, ty1, clipRect) {
                                let color = colorToSIMD(backgroundColor)
                            backgroundCells.append(makeColorCell(x0: clipped.0,
                                                                  y0: clipped.1,
                                                                  x1: clipped.2,
                                                                  y1: clipped.3,
                                                                  color: color))
                        }
                    }
                }
            }
        }

        if let images = lineInfo.images {
            var underTextImages: [SnapshotImage] = []
            var overTextKittyImages: [SnapshotImage] = []
            var otherImages: [SnapshotImage] = []
            for basicImage in images {
                guard let image = basicImage as? SnapshotImage else {
                    continue
                }
                if image.kittyIsKitty {
                    if image.kittyZIndex < 0 {
                        underTextImages.append(image)
                    } else {
                        overTextKittyImages.append(image)
                    }
                } else {
                    otherImages.append(image)
                }
            }
            let sortKitty: (SnapshotImage, SnapshotImage) -> Bool = { lhs, rhs in
                if lhs.kittyZIndex != rhs.kittyZIndex {
                    return lhs.kittyZIndex < rhs.kittyZIndex
                }
                let leftId = lhs.kittyImageId ?? 0
                let rightId = rhs.kittyImageId ?? 0
                return leftId < rightId
            }
            underTextImages.sort(by: sortKitty)
            overTextKittyImages.sort(by: sortKitty)

            let offsetScale = context.imageScale
            for image in underTextImages {
                guard let texture = texture(for: image) else {
                    continue
                }
                let offsetX = CGFloat(image.kittyPixelOffsetX) / offsetScale
                let offsetY = CGFloat(image.kittyPixelOffsetY) / offsetScale
                let rect = CGRect(x: CGFloat(image.col) * cellWidth + offsetX,
                                  y: rowBase - CGFloat(image.pixelHeight) + offsetY,
                                  width: CGFloat(image.pixelWidth),
                                  height: CGFloat(image.pixelHeight))
                if let draw = imageDraw(texture: texture,
                                        rect: rect,
                                        uvRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                        renderMode: renderMode,
                                        clipRect: clipRect,
                                        pivotY: pivotY,
                                        scale: scale) {
                    underImageDraws.append(draw)
                }
            }

            for image in overTextKittyImages {
                guard let texture = texture(for: image) else {
                    continue
                }
                let offsetX = CGFloat(image.kittyPixelOffsetX) / offsetScale
                let offsetY = CGFloat(image.kittyPixelOffsetY) / offsetScale
                let rect = CGRect(x: CGFloat(image.col) * cellWidth + offsetX,
                                  y: rowBase - CGFloat(image.pixelHeight) + offsetY,
                                  width: CGFloat(image.pixelWidth),
                                  height: CGFloat(image.pixelHeight))
                if let draw = imageDraw(texture: texture,
                                        rect: rect,
                                        uvRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                        renderMode: renderMode,
                                        clipRect: clipRect,
                                        pivotY: pivotY,
                                        scale: scale) {
                    overImageDraws.append(draw)
                }
            }

            for image in otherImages {
                guard let texture = texture(for: image) else {
                    continue
                }
                let rect = CGRect(x: CGFloat(image.col) * cellWidth,
                                  y: rowBase - CGFloat(image.pixelHeight),
                                  width: CGFloat(image.pixelWidth),
                                  height: CGFloat(image.pixelHeight))
                if let draw = imageDraw(texture: texture,
                                        rect: rect,
                                        uvRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                        renderMode: renderMode,
                                        clipRect: clipRect,
                                        pivotY: pivotY,
                                        scale: scale) {
                    otherImageDraws.append(draw)
                }
            }
        }

        for shaped in shapedSegments {
            for run in shaped.runs {
                let runGlyphsCount = run.shaperRun.glyphCount
                if runGlyphsCount == 0 {
                    continue
                }
                let runAttributes = run.attributes
                let runFont = runAttributes[.font] as? TTFont ?? context.fonts.normal
                let ctFont = runFont as CTFont

                let textColor = runAttributes[.foregroundColor] as? TTColor ?? context.effectiveForegroundColor
                let textColorSIMD = colorToSIMD(textColor)

                // Same-cell glyphs (base + combining marks) are adjacent in
                // glyph order, so a pair of locals replaces a per-run anchor
                // dictionary.
                var anchorOrdinal = -1
                var anchorX: CGFloat = 0
                for glyphRun in run.shaperRun.glyphRuns {
                    let scaledFont = scaledFontFor(font: glyphRun.font, scale: scale)
                    for i in 0..<glyphRun.glyphs.count {
                        let glyph = glyphRun.glyphs[i]
                        guard let entry = glyphEntry(for: scaledFont, glyph: glyph) else {
                            continue
                        }
                        if entry.size.width <= 0 || entry.size.height <= 0 {
                            continue
                        }
                        let ctPos = glyphRun.positions[i]
                        let stringIndex = run.utf16Offset + glyphRun.stringIndices[i]
                        let ordinal = shaped.segment.cellOrdinal(forUTF16: stringIndex)
                        let intraCluster: CGFloat
                        if ordinal == anchorOrdinal {
                            intraCluster = ctPos.x - anchorX
                        } else {
                            anchorOrdinal = ordinal
                            anchorX = ctPos.x
                            intraCluster = 0
                        }
                        let glyphColumn = shaped.segment.column + (ordinal * shaped.segment.columnWidth)
                        // Center full-width (CJK) and substituted glyphs within
                        // their multi-cell slot instead of pinning them to the
                        // cell's left edge, mirroring the CoreGraphics path. The
                        // decoration loops below keep using the grid column, so
                        // underlines/strikethroughs stay cell-aligned.
                        let fit = shaped.segment.columnWidth >= 2
                            ? context.glyphSlotFit(font: glyphRun.font,
                                                   glyph: glyph,
                                                   columnWidth: shaped.segment.columnWidth)
                            : GlyphSlotFit.identity
                        let basePos = CGPoint(x: lineOrigin.x + (cellWidth * CGFloat(glyphColumn)) + intraCluster + fit.dx,
                                              y: lineOrigin.y + yOffset + ctPos.y + fit.dy)
                        let pxX = basePos.x * scale + entry.bearing.x * fit.scale
                        let pxY = basePos.y * scale + entry.bearing.y * fit.scale

                        let x0 = pxX
                        let y0 = pxY
                        let x1 = pxX + entry.size.width * fit.scale
                        let y1 = pxY + entry.size.height * fit.scale
                        let (tx0, ty0, tx1, ty1) = transformRect(x0: x0, y0: y0, x1: x1, y1: y1)

                        let atlasSize = entry.atlasKind == .color ? colorAtlas.size : grayscaleAtlas.size
                        let u0 = Float(entry.region.x) / Float(atlasSize)
                        let v0 = Float(entry.region.y) / Float(atlasSize)
                        let u1 = Float(entry.region.x + entry.region.width) / Float(atlasSize)
                        let v1 = Float(entry.region.y + entry.region.height) / Float(atlasSize)

                        let color = entry.isColor ? SIMD4<Float>(1, 1, 1, 1) : textColorSIMD
                        if let clipped = self.clipRect(tx0, ty0, tx1, ty1, u0, v0, u1, v1, clipRect) {
                            let cell = makeTextCell(x0: clipped.x0,
                                                    y0: clipped.y0,
                                                    x1: clipped.x1,
                                                    y1: clipped.y1,
                                                    u0: clipped.u0,
                                                    v0: clipped.v0,
                                                    u1: clipped.u1,
                                                    v1: clipped.v1,
                                                    color: color)
                            switch entry.atlasKind {
                            case .grayscale:
                                glyphCellsGray.append(cell)
                            case .color:
                                glyphCellsColor.append(cell)
                            }
                        }
                    }
                }

                if let rawStyle = runAttributes[.underlineStyle] as? Int,
                   rawStyle != 0 {
                    let underlineStyle = resolveUnderlineStyle(runAttributes)
                    let underlineColor = (runAttributes[.underlineColor] as? TTColor) ??
                        context.effectiveForegroundColor
                    let underlineColorSIMD = colorToSIMD(underlineColor)
                    let thickness = underlineThickness * scale
                    let segmentStyle: UnderlineStyle = underlineStyle == .double ? .single : underlineStyle

                    for (glyphIndex, ctPos) in run.shaperRun.positions.enumerated() {
                        let stringIndex = run.utf16Offset + run.shaperRun.stringIndices[glyphIndex]
                        let ordinal = shaped.segment.cellOrdinal(forUTF16: stringIndex)
                        let glyphColumn = shaped.segment.column + (ordinal * shaped.segment.columnWidth)
                        let basePos = CGPoint(x: lineOrigin.x + (cellWidth * CGFloat(glyphColumn)),
                                              y: lineOrigin.y + yOffset + ctPos.y)
                        let x0 = basePos.x * scale
                        let x1 = (basePos.x + decorationCellWidth) * scale
                        let yCenter = (basePos.y + underlinePosition) * scale
                        appendUnderlineSegments(x0: x0,
                                                x1: x1,
                                                yCenter: yCenter,
                                                thickness: thickness,
                                                color: underlineColorSIMD,
                                                style: segmentStyle,
                                                patternScale: scale,
                                                renderMode: renderMode,
                                                clipRect: clipRect,
                                                pivotY: pivotY,
                                                output: &decorationCells)
                        if underlineStyle == .double {
                            let yDouble = (basePos.y + underlinePosition - underlineThickness - 1) * scale
                            appendUnderlineSegments(x0: x0,
                                                    x1: x1,
                                                    yCenter: yDouble,
                                                    thickness: thickness,
                                                    color: underlineColorSIMD,
                                                    style: segmentStyle,
                                                    patternScale: scale,
                                                    renderMode: renderMode,
                                                    clipRect: clipRect,
                                                    pivotY: pivotY,
                                                    output: &decorationCells)
                        }
                    }
                }

                if let rawStyle = runAttributes[.strikethroughStyle] as? Int,
                   rawStyle != 0 {
                    let style = NSUnderlineStyle(rawValue: rawStyle)
                    let strikeColor = (runAttributes[.strikethroughColor] as? TTColor) ??
                        context.effectiveForegroundColor
                    let strikeColorSIMD = colorToSIMD(strikeColor)
                    let strikeStyle: UnderlineStyle
                    if style.contains(.patternDot) {
                        strikeStyle = .dotted
                    } else if style.contains(.patternDash) || style.contains(.patternDashDot) || style.contains(.patternDashDotDot) {
                        strikeStyle = .dashed
                    } else {
                        strikeStyle = .single
                    }
                    let isDouble = style.contains(.double)
                    let strikeThickness = max(round(scale * CTFontGetUnderlineThickness(ctFont)) / scale, 0.5)
                    let strikePosition = (CTFontGetXHeight(ctFont) + strikeThickness) * 0.5

                    for (glyphIndex, ctPos) in run.shaperRun.positions.enumerated() {
                        let stringIndex = run.utf16Offset + run.shaperRun.stringIndices[glyphIndex]
                        let ordinal = shaped.segment.cellOrdinal(forUTF16: stringIndex)
                        let glyphColumn = shaped.segment.column + (ordinal * shaped.segment.columnWidth)
                        let basePos = CGPoint(x: lineOrigin.x + (cellWidth * CGFloat(glyphColumn)),
                                              y: lineOrigin.y + yOffset + ctPos.y)
                        let x0 = basePos.x * scale
                        let x1 = (basePos.x + decorationCellWidth) * scale
                        let yCenter = (basePos.y + strikePosition) * scale
                        let thickness = strikeThickness * scale
                        appendUnderlineSegments(x0: x0,
                                                x1: x1,
                                                yCenter: yCenter,
                                                thickness: thickness,
                                                color: strikeColorSIMD,
                                                style: strikeStyle,
                                                patternScale: scale,
                                                renderMode: renderMode,
                                                clipRect: clipRect,
                                                pivotY: pivotY,
                                                output: &decorationCells)
                        if isDouble {
                            let yDouble = (basePos.y + strikePosition - strikeThickness - 1) * scale
                            appendUnderlineSegments(x0: x0,
                                                    x1: x1,
                                                    yCenter: yDouble,
                                                    thickness: thickness,
                                                    color: strikeColorSIMD,
                                                    style: strikeStyle,
                                                    patternScale: scale,
                                                    renderMode: renderMode,
                                                    clipRect: clipRect,
                                                    pivotY: pivotY,
                                                    output: &decorationCells)
                        }
                    }
                }

            }
        }

        if !lineInfo.kittyPlaceholders.isEmpty {
            for placeholder in lineInfo.kittyPlaceholders {
                guard let records = snapshot.kitty.virtualPlacementsByImageId[placeholder.imageId] else {
                    continue
                }
                guard let record = records.first(where: { record in
                    if placeholder.placementId != 0 && record.placementId != placeholder.placementId {
                        return false
                    }
                    return record.cols > placeholder.placeholderCol &&
                        record.rows > placeholder.placeholderRow &&
                        record.cols > 0 &&
                        record.rows > 0
                }) else {
                    continue
                }
                guard let texture = kittyTexture(imageId: placeholder.imageId,
                                                 kitty: snapshot.kitty) else {
                    continue
                }

                let offsetScale = context.imageScale
                let offsetX = CGFloat(record.pixelOffsetX) / offsetScale
                let offsetY = CGFloat(record.pixelOffsetY) / offsetScale
                let placementOriginX = lineOrigin.x + CGFloat(placeholder.col - placeholder.placeholderCol) * cellWidth + offsetX
                let placementTopY = lineOrigin.y + CGFloat(placeholder.placeholderRow) * cellHeight
                let placementOriginY = placementTopY - CGFloat(record.rows - 1) * cellHeight + offsetY
                let placementRect = CGRect(x: placementOriginX,
                                           y: placementOriginY,
                                           width: CGFloat(record.cols) * cellWidth,
                                           height: CGFloat(record.rows) * cellHeight)
                if placementRect.width <= 0 || placementRect.height <= 0 {
                    continue
                }
                let imageSize = CGSize(width: CGFloat(texture.width) / scale, height: CGFloat(texture.height) / scale)
                let imageRect = kittyAspectFitRect(imageSize: imageSize, in: placementRect)
                let cellRect = CGRect(x: lineOrigin.x + CGFloat(placeholder.col) * cellWidth,
                                      y: lineOrigin.y,
                                      width: cellWidth,
                                      height: cellHeight)
                let visible = imageRect.intersection(cellRect)
                if visible.isEmpty {
                    continue
                }
                let u0 = (visible.minX - imageRect.minX) / imageRect.width
                let v0 = (visible.minY - imageRect.minY) / imageRect.height
                let u1 = (visible.maxX - imageRect.minX) / imageRect.width
                let v1 = (visible.maxY - imageRect.minY) / imageRect.height
                let uvRect = CGRect(x: u0, y: v0, width: u1 - u0, height: v1 - v0)
                if let draw = imageDraw(texture: texture,
                                        rect: visible,
                                        uvRect: uvRect,
                                        renderMode: renderMode,
                                        clipRect: clipRect,
                                        pivotY: pivotY,
                                        scale: scale) {
                    placeholderImageDraws.append(draw)
                }
            }
        }

        return RowDrawData(backgroundCells: backgroundCells,
                           powerlineJoinCells: powerlineJoinCells,
                           glyphCellsGray: glyphCellsGray,
                           glyphCellsColor: glyphCellsColor,
                           decorationCells: decorationCells,
                           underImageDraws: underImageDraws,
                           placeholderImageDraws: placeholderImageDraws,
                           overImageDraws: overImageDraws,
                           otherImageDraws: otherImageDraws)
    }

    private func buildShapedSegments(_ segments: [ViewLineSegment],
                                     context: SnapshotRenderContext) -> [ShapedSegment] {
        var shapedSegments: [ShapedSegment] = []
        for segment in segments {
            guard segment.attributedString.length > 0 else {
                continue
            }
            let fullString = segment.attributedString.string as NSString
            var shapedRuns: [ShapedRun] = []
            segment.attributedString.enumerateAttributes(in: NSRange(location: 0, length: segment.attributedString.length),
                                                         options: []) { attributes, range, _ in
                let text = fullString.substring(with: range)
                guard !text.isEmpty else {
                    return
                }
                let runFont = attributes[.font] as? TTFont ?? context.fonts.normal
                guard let shaped = shaperCache.shape(text: text, font: runFont as CTFont) else {
                    return
                }
                shapedRuns.append(ShapedRun(attributes: attributes,
                                            utf16Offset: range.location,
                                            shaperRun: shaped))
            }
            if !shapedRuns.isEmpty {
                shapedSegments.append(ShapedSegment(segment: segment, runs: shapedRuns))
            }
        }
        return shapedSegments
    }

    /// Reacts to a grow or reset that `ensureRegion` performed on `atlas`.
    /// A reset invalidates every previously issued region, so all glyph
    /// caches must go. A grow preserves pixel coordinates, so glyph entries
    /// stay valid; only UVs already normalized against the old atlas size
    /// (the row caches, and rows emitted earlier in this build pass) are
    /// stale. Either way the current build pass must be redone.
    private func handleAtlasChange(_ atlas: GlyphAtlas, previousSize: Int) {
        if atlas.didReset {
            glyphCache.removeAll()
            customGlyphCache.removeAll()
            rowCache.removeAll()
            atlasInvalidatedDuringBuild = true
        } else if atlas.size != previousSize {
            rowCache.removeAll()
            atlasInvalidatedDuringBuild = true
        }
    }

    private func glyphEntry(for font: CTFont, glyph: CGGlyph) -> GlyphEntry? {
        let key = GlyphKey(fontName: CTFontCopyPostScriptName(font) as String,
                           size: CTFontGetSize(font),
                           glyph: glyph)
        if let cached = glyphCache[key] {
            return cached
        }
        guard let bitmap = rasterizer.rasterize(font: font, glyph: glyph) else {
            return nil
        }
        let atlasKind: GlyphAtlasKind = bitmap.isColor ? .color : .grayscale
        let atlas = atlasKind == .color ? colorAtlas : grayscaleAtlas
        let previousSize = atlas.size
        let maybeRegion = atlas.ensureRegion(width: bitmap.width, height: bitmap.height)
        handleAtlasChange(atlas, previousSize: previousSize)
        guard let region = maybeRegion else {
            return nil
        }
        atlas.write(region: region, pixels: bitmap.pixels, width: bitmap.width, height: bitmap.height)
        let entry = GlyphEntry(region: region,
                               size: CGSize(width: bitmap.width, height: bitmap.height),
                               bearing: bitmap.bearing,
                               isColor: bitmap.isColor,
                               atlasKind: atlasKind)
        glyphCache[key] = entry
        return entry
    }

    private func scaledFontFor(font: CTFont, scale: CGFloat) -> CTFont {
        let key = GlyphKey(fontName: CTFontCopyPostScriptName(font) as String,
                           size: CTFontGetSize(font) * scale,
                           glyph: 0)
        if let cached = scaledFontCache[key] {
            return cached
        }
        let scaled = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * scale, nil, nil)
        scaledFontCache[key] = scaled
        return scaled
    }

    private func alignToPixel(_ value: CGFloat, scale: CGFloat, rule: FloatingPointRoundingRule) -> CGFloat {
        guard scale > 0 else {
            return value
        }
        return (value * scale).rounded(rule) / scale
    }

    private func pixelAlignedRect(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let minX = alignToPixel(rect.minX, scale: scale, rule: .down)
        let maxX = alignToPixel(rect.maxX, scale: scale, rule: .up)
        let minY = alignToPixel(rect.minY, scale: scale, rule: .down)
        let maxY = alignToPixel(rect.maxY, scale: scale, rule: .up)
        return CGRect(x: minX,
                      y: minY,
                      width: max(0, maxX - minX),
                      height: max(0, maxY - minY))
    }

    private func customGlyphEntry(codePoint: UInt32,
                                  cellWidthPx: Int,
                                  cellHeightPx: Int,
                                  scale: CGFloat,
                                  baseThicknessPx: Int,
                                  antiAlias: Bool) -> CustomGlyphEntry? {
        let scaleInt = max(1, Int(round(scale)))
        let key = CustomGlyphKey(codePoint: codePoint,
                                 cellWidthPx: cellWidthPx,
                                 cellHeightPx: cellHeightPx,
                                 baseThicknessPx: baseThicknessPx,
                                 scale: scaleInt,
                                 antiAlias: antiAlias)
        if let cached = customGlyphCache[key] {
            return cached
        }
        guard let bitmap = renderCustomGlyphBitmap(codePoint: codePoint,
                                                   cellWidthPx: cellWidthPx,
                                                   cellHeightPx: cellHeightPx,
                                                   scale: scale,
                                                   baseThicknessPx: baseThicknessPx,
                                                   antiAlias: antiAlias) else {
            return nil
        }
        let previousSize = grayscaleAtlas.size
        let maybeRegion = grayscaleAtlas.ensureRegion(width: bitmap.width, height: bitmap.height)
        handleAtlasChange(grayscaleAtlas, previousSize: previousSize)
        guard let region = maybeRegion else {
            return nil
        }
        grayscaleAtlas.write(region: region,
                             pixels: bitmap.pixels,
                             width: bitmap.width,
                             height: bitmap.height)
        let entry = CustomGlyphEntry(region: region,
                                     size: CGSize(width: bitmap.width, height: bitmap.height))
        customGlyphCache[key] = entry
        return entry
    }

    private func renderCustomGlyphBitmap(codePoint: UInt32,
                                         cellWidthPx: Int,
                                         cellHeightPx: Int,
                                         scale: CGFloat,
                                         baseThicknessPx: Int,
                                         antiAlias: Bool) -> CustomGlyphBitmap? {
        guard cellWidthPx > 0, cellHeightPx > 0 else {
            return nil
        }
        let bytesPerPixel = 4
        var pixels = Array(repeating: UInt8(0), count: cellWidthPx * cellHeightPx * bytesPerPixel)
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else {
                return false
            }
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                return false
            }
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            guard let context = CGContext(data: base,
                                          width: cellWidthPx,
                                          height: cellHeightPx,
                                          bitsPerComponent: 8,
                                          bytesPerRow: cellWidthPx * bytesPerPixel,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo) else {
                return false
            }

            let cellSize = CGSize(width: CGFloat(cellWidthPx) / scale,
                                  height: CGFloat(cellHeightPx) / scale)
            let cellOrigin = CGPoint.zero

            switch codePoint {
            case let value where PowerlineRenderer.glyph(for: value) != nil:
                context.setShouldAntialias(true)
                context.setAllowsAntialiasing(true)
                context.scaleBy(x: scale, y: scale)
                PowerlineRenderer.draw(codePoint: codePoint,
                                       in: context,
                                       cellRect: CGRect(x: 0,
                                                        y: 0,
                                                        width: cellSize.width,
                                                        height: cellSize.height),
                                       scaleX: scale,
                                       scaleY: scale,
                                       color: TTColor.white.cgColor,
                                       includeJoinOverdraw: false)
                return true
            case UInt32(BoxDrawingRenderer.lowerBoundary)...UInt32(BoxDrawingRenderer.upperBoundary):
                context.setShouldAntialias(false)
                context.setAllowsAntialiasing(false)
                context.scaleBy(x: scale, y: scale)
                BoxDrawingRenderer.draw(codePoint: codePoint,
                                        in: context,
                                        cellOrigin: cellOrigin,
                                        cellSize: cellSize,
                                        scale: scale,
                                        color: TTColor.white,
                                        baseThicknessPx: baseThicknessPx)
                return true
            case UInt32(BlockElementMapping.lowerBoundary)...UInt32(BlockElementMapping.upperBoundary):
                guard let rects = BlockElementMapping.rects(for: codePoint) else {
                    return false
                }
                context.setShouldAntialias(antiAlias)
                context.setAllowsAntialiasing(antiAlias)
                context.scaleBy(x: scale, y: scale)
                let xEighth = cellSize.width / 8.0
                let yEighth = cellSize.height / 8.0
                for rect in rects {
                    var drawRect = rect.rect(in: cellOrigin,
                                             xEighth: xEighth,
                                             yEighth: yEighth,
                                             cellHeight: cellSize.height)
                    if !antiAlias {
                        drawRect = pixelAlignedRect(drawRect, scale: scale)
                    }
                    if drawRect.width <= 0 || drawRect.height <= 0 {
                        continue
                    }
                    let alpha = max(0, min(1, rect.alpha.rawValue))
                    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
                    context.fill(drawRect)
                }
                return true
            default:
                return false
            }
        }
        guard drew else {
            return nil
        }
        return CustomGlyphBitmap(width: cellWidthPx,
                                 height: cellHeightPx,
                                 pixels: pixels)
    }

    private func quadVertices(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat, color: SIMD4<Float>) -> [ColorVertex] {
        let p0 = SIMD2<Float>(Float(x0), Float(y0))
        let p1 = SIMD2<Float>(Float(x1), Float(y0))
        let p2 = SIMD2<Float>(Float(x0), Float(y1))
        let p3 = SIMD2<Float>(Float(x1), Float(y1))
        return [
            ColorVertex(position: p0, color: color),
            ColorVertex(position: p1, color: color),
            ColorVertex(position: p2, color: color),
            ColorVertex(position: p1, color: color),
            ColorVertex(position: p3, color: color),
            ColorVertex(position: p2, color: color),
        ]
    }

    private func glyphQuadVertices(x0: Float, y0: Float, x1: Float, y1: Float,
                                   u0: Float, v0: Float, u1: Float, v1: Float,
                                   color: SIMD4<Float>) -> [GlyphVertex] {
        let p0 = SIMD2<Float>(x0, y0)
        let p1 = SIMD2<Float>(x1, y0)
        let p2 = SIMD2<Float>(x0, y1)
        let p3 = SIMD2<Float>(x1, y1)
        let t0 = SIMD2<Float>(u0, v0)
        let t1 = SIMD2<Float>(u1, v0)
        let t2 = SIMD2<Float>(u0, v1)
        let t3 = SIMD2<Float>(u1, v1)
        return [
            GlyphVertex(position: p0, texCoord: t0, color: color),
            GlyphVertex(position: p1, texCoord: t1, color: color),
            GlyphVertex(position: p2, texCoord: t2, color: color),
            GlyphVertex(position: p1, texCoord: t1, color: color),
            GlyphVertex(position: p3, texCoord: t3, color: color),
            GlyphVertex(position: p2, texCoord: t2, color: color),
        ]
    }

    private func makeColorCell(x0: Float, y0: Float, x1: Float, y1: Float, color: SIMD4<Float>) -> ColorCell {
        let position = SIMD2<Float>(x0, y0)
        let size = SIMD2<Float>(x1 - x0, y1 - y0)
        return ColorCell(position: position, size: size, color: color)
    }

    private func makeTextCell(x0: Float,
                              y0: Float,
                              x1: Float,
                              y1: Float,
                              u0: Float,
                              v0: Float,
                              u1: Float,
                              v1: Float,
                              color: SIMD4<Float>) -> TextCell {
        let position = SIMD2<Float>(x0, y0)
        let size = SIMD2<Float>(x1 - x0, y1 - y0)
        let texOrigin = SIMD2<Float>(u0, v0)
        let texSize = SIMD2<Float>(u1 - u0, v1 - v0)
        return TextCell(position: position,
                        size: size,
                        texOrigin: texOrigin,
                        texSize: texSize,
                        color: color)
    }

    private final class BufferPool {
        private let device: MTLDevice
        private let alignment = 256
        private let maxBuffersPerSize = 4
        private let lock = NSLock()
        private var available: [Int: [MTLBuffer]] = [:]
        private var frameBuffers: [MTLBuffer] = []

        init(device: MTLDevice) {
            self.device = device
        }

        func beginFrame() {
            frameBuffers.removeAll(keepingCapacity: true)
        }

        func makeBuffer<T>(_ vertices: [T]) -> MTLBuffer? {
            let byteCount = vertices.count * MemoryLayout<T>.stride
            guard byteCount > 0 else {
                return nil
            }
            let length = alignedLength(byteCount)
            guard let buffer = dequeue(length: length) else {
                return nil
            }
            vertices.withUnsafeBytes { raw in
                memcpy(buffer.contents(), raw.baseAddress!, byteCount)
            }
            frameBuffers.append(buffer)
            return buffer
        }

        func commit(commandBuffer: MTLCommandBuffer) {
            let buffers = frameBuffers
            guard !buffers.isEmpty else {
                return
            }
            commandBuffer.addCompletedHandler { [weak self] _ in
                self?.recycle(buffers)
            }
        }

        private func alignedLength(_ length: Int) -> Int {
            // Round up to a coarse power-of-two size class. Exact-length
            // buckets never match again when the number of drawn cells
            // changes every frame (e.g. htop), so the pool would retain
            // up to maxBuffersPerSize buffers per distinct length and grow
            // without bound. Size classes keep the bucket count small and
            // make recycled buffers actually reusable.
            let aligned = ((length + alignment - 1) / alignment) * alignment
            let minimumClass = 4096
            if aligned <= minimumClass {
                return minimumClass
            }
            var size = minimumClass
            while size < aligned {
                size *= 2
            }
            return size
        }

        private func dequeue(length: Int) -> MTLBuffer? {
            lock.lock()
            if var bucket = available[length], let buffer = bucket.popLast() {
                available[length] = bucket
                lock.unlock()
                return buffer
            }
            lock.unlock()
            return device.makeBuffer(length: length, options: .storageModeShared)
        }

        private func recycle(_ buffers: [MTLBuffer]) {
            lock.lock()
            defer { lock.unlock() }
            for buffer in buffers {
                let length = buffer.length
                var bucket = available[length, default: []]
                if bucket.count < maxBuffersPerSize {
                    bucket.append(buffer)
                    available[length] = bucket
                }
            }
        }
    }

    private struct ShaperKey: Hashable {
        let fontName: String
        let fontSize: CGFloat
        let text: String
    }

    private struct ShaperGlyphRun {
        let font: CTFont
        let glyphs: [CGGlyph]
        let positions: [CGPoint]
        let stringIndices: [CFIndex]
    }

    private struct ShaperRun {
        let glyphRuns: [ShaperGlyphRun]
        let positions: [CGPoint]
        let stringIndices: [CFIndex]
        let glyphCount: Int
    }

    private struct ShapedRun {
        let attributes: [NSAttributedString.Key: Any]
        let utf16Offset: Int
        let shaperRun: ShaperRun
    }

    private struct ShapedSegment {
        let segment: ViewLineSegment
        let runs: [ShapedRun]
    }

    private final class ShaperCache {
        private let maxEntries: Int
        private var cache: [ShaperKey: ShaperRun] = [:]
        private var order: [ShaperKey] = []

        init(maxEntries: Int) {
            self.maxEntries = maxEntries
        }

        func shape(text: String, font: CTFont) -> ShaperRun? {
            guard !text.isEmpty else {
                return nil
            }
            let key = ShaperKey(fontName: CTFontCopyPostScriptName(font) as String,
                                fontSize: CTFontGetSize(font),
                                text: text)
            if let cached = cache[key] {
                return cached
            }

            // buildAttributedString supplies terminal cells in their final
            // screen order. Keep that order when CoreText shapes glyphs for
            // the Metal atlas; otherwise CoreText applies BiDi a second time.
            let writingDirectionKey = NSAttributedString.Key(kCTWritingDirectionAttributeName as String)
            let attributedString = NSAttributedString(string: text, attributes: [
                .font: font,
                writingDirectionKey: [NSNumber(value: 2)],
            ])
            let line = CTLineCreateWithAttributedString(attributedString)
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], !runs.isEmpty else {
                return nil
            }

            var glyphRuns: [ShaperGlyphRun] = []
            var positions: [CGPoint] = []
            var stringIndices: [CFIndex] = []
            for run in runs {
                let count = CTRunGetGlyphCount(run)
                if count == 0 {
                    continue
                }
                let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
                let runFont: CTFont = {
                    if let runFont = attributes[.font] as? TTFont {
                        return runFont as CTFont
                    }
                    return font
                }()
                let glyphs = [CGGlyph](unsafeUninitializedCapacity: count) { bufferPointer, countOut in
                    CTRunGetGlyphs(run, CFRange(), bufferPointer.baseAddress!)
                    countOut = count
                }
                var runPositions = [CGPoint](repeating: .zero, count: count)
                CTRunGetPositions(run, CFRange(), &runPositions)
                var runStringIndices = [CFIndex](repeating: 0, count: count)
                CTRunGetStringIndices(run, CFRange(), &runStringIndices)
                glyphRuns.append(ShaperGlyphRun(font: runFont,
                                                glyphs: glyphs,
                                                positions: runPositions,
                                                stringIndices: runStringIndices))
                positions.append(contentsOf: runPositions)
                stringIndices.append(contentsOf: runStringIndices)
            }

            let result = ShaperRun(glyphRuns: glyphRuns,
                                   positions: positions,
                                   stringIndices: stringIndices,
                                   glyphCount: positions.count)
            insert(key: key, run: result)
            return result
        }

        private func insert(key: ShaperKey, run: ShaperRun) {
            if cache[key] == nil {
                order.append(key)
            }
            cache[key] = run
            while order.count > maxEntries {
                let evicted = order.removeFirst()
                cache.removeValue(forKey: evicted)
            }
        }
    }

    private func colorToSIMD(_ color: TTColor) -> SIMD4<Float> {
        #if os(macOS)
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
        #else
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
        }
        let cgColor = color.cgColor
        let components = cgColor.components ?? [0, 0, 0, 1]
        if components.count >= 4 {
            return SIMD4<Float>(Float(components[0]),
                                Float(components[1]),
                                Float(components[2]),
                                Float(components[3]))
        }
        if components.count == 2 {
            return SIMD4<Float>(Float(components[0]),
                                Float(components[0]),
                                Float(components[0]),
                                Float(components[1]))
        }
        return SIMD4<Float>(0, 0, 0, 1)
        #endif
    }

    private func makeBuffer<T>(_ vertices: [T]) -> MTLBuffer? {
        return bufferPool.makeBuffer(vertices)
    }

    private func makeStaticBuffer<T>(_ vertices: [T]) -> (MTLBuffer?, Int) {
        let count = vertices.count
        guard count > 0 else {
            return (nil, 0)
        }
        let byteCount = count * MemoryLayout<T>.stride
        guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
            return (nil, 0)
        }
        vertices.withUnsafeBytes { raw in
            memcpy(buffer.contents(), raw.baseAddress!, byteCount)
        }
        return (buffer, count)
    }

    private func makeImageDrawBuffers(_ draws: [ImageDraw]) -> [ImageDrawBuffer] {
        guard !draws.isEmpty else {
            return []
        }
        var result: [ImageDrawBuffer] = []
        result.reserveCapacity(draws.count)
        for draw in draws {
            let (buffer, count) = makeStaticBuffer(draw.vertices)
            guard let buffer, count > 0 else {
                continue
            }
            result.append(ImageDrawBuffer(texture: draw.texture, buffer: buffer, vertexCount: count))
        }
        return result
    }

    private func makeRowBuffers(from data: RowDrawData) -> RowDrawBuffers {
        let (backgroundBuffer, backgroundCount) = makeStaticBuffer(data.backgroundCells)
        let (powerlineJoinBuffer, powerlineJoinCount) = makeStaticBuffer(data.powerlineJoinCells)
        let (glyphGrayBuffer, glyphGrayCount) = makeStaticBuffer(data.glyphCellsGray)
        let (glyphColorBuffer, glyphColorCount) = makeStaticBuffer(data.glyphCellsColor)
        let (decorationBuffer, decorationCount) = makeStaticBuffer(data.decorationCells)
        return RowDrawBuffers(backgroundBuffer: backgroundBuffer,
                              backgroundCount: backgroundCount,
                              powerlineJoinBuffer: powerlineJoinBuffer,
                              powerlineJoinCount: powerlineJoinCount,
                              glyphGrayBuffer: glyphGrayBuffer,
                              glyphGrayCount: glyphGrayCount,
                              glyphColorBuffer: glyphColorBuffer,
                              glyphColorCount: glyphColorCount,
                              decorationBuffer: decorationBuffer,
                              decorationCount: decorationCount,
                              underImageBuffers: makeImageDrawBuffers(data.underImageDraws),
                              placeholderImageBuffers: makeImageDrawBuffers(data.placeholderImageDraws),
                              overImageBuffers: makeImageDrawBuffers(data.overImageDraws),
                              otherImageBuffers: makeImageDrawBuffers(data.otherImageDraws))
    }

    private func drawCellBuffer<T>(_ cells: [T],
                                   pipeline: MTLRenderPipelineState,
                                   texture: MTLTexture?,
                                   encoder: MTLRenderCommandEncoder,
                                   viewport: SIMD2<Float>) {
        guard !cells.isEmpty, let buffer = makeBuffer(cells) else {
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        var viewportVar = viewport
        encoder.setVertexBytes(&viewportVar, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        if let texture {
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cells.count * 6)
    }

    private func drawFrameData(_ frame: FrameDrawData, encoder: MTLRenderCommandEncoder, viewport: SIMD2<Float>) {
        drawCellBuffer(frame.backgroundCells,
                       pipeline: cellColorPipeline,
                       texture: nil,
                       encoder: encoder,
                       viewport: viewport)

        drawImageBatches(frame.underImageDraws, encoder: encoder, viewport: viewport)

        drawCellBuffer(frame.powerlineJoinCells,
                       pipeline: cellColorPipeline,
                       texture: nil,
                       encoder: encoder,
                       viewport: viewport)

        drawCellBuffer(frame.glyphCellsGray,
                       pipeline: cellTextGrayPipeline,
                       texture: grayscaleAtlas.texture,
                       encoder: encoder,
                       viewport: viewport)

        drawCellBuffer(frame.glyphCellsColor,
                       pipeline: cellTextPipeline,
                       texture: colorAtlas.texture,
                       encoder: encoder,
                       viewport: viewport)

        drawCellBuffer(frame.decorationCells,
                       pipeline: cellColorPipeline,
                       texture: nil,
                       encoder: encoder,
                       viewport: viewport)

        drawImageBatches(frame.placeholderImageDraws, encoder: encoder, viewport: viewport)
        drawImageBatches(frame.overImageDraws, encoder: encoder, viewport: viewport)
        drawImageBatches(frame.otherImageDraws, encoder: encoder, viewport: viewport)
    }

    private func drawImageBatches(_ draws: [ImageDraw], encoder: MTLRenderCommandEncoder, viewport: SIMD2<Float>) {
        guard !draws.isEmpty else {
            return
        }
        encoder.setRenderPipelineState(textPipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        var viewportVar = viewport
        encoder.setVertexBytes(&viewportVar, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        for draw in draws {
            guard let buffer = makeBuffer(draw.vertices) else {
                continue
            }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setFragmentTexture(draw.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: draw.vertices.count)
        }
    }

    private func drawVertexBuffers(rows: [RowDrawBuffers],
                                   bufferKey: KeyPath<RowDrawBuffers, MTLBuffer?>,
                                   countKey: KeyPath<RowDrawBuffers, Int>,
                                   pipeline: MTLRenderPipelineState,
                                   texture: MTLTexture?,
                                   encoder: MTLRenderCommandEncoder,
                                   viewport: SIMD2<Float>) {
        var hasAny = false
        for row in rows {
            if row[keyPath: bufferKey] != nil {
                hasAny = true
                break
            }
        }
        guard hasAny else {
            return
        }
        encoder.setRenderPipelineState(pipeline)
        var viewportVar = viewport
        encoder.setVertexBytes(&viewportVar, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        if let texture {
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
        }
        for row in rows {
            guard let buffer = row[keyPath: bufferKey] else {
                continue
            }
            let count = row[keyPath: countKey]
            if count == 0 {
                continue
            }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count * 6)
        }
    }

    private func drawImageRows(rows: [RowDrawBuffers],
                               imageKey: KeyPath<RowDrawBuffers, [ImageDrawBuffer]>,
                               encoder: MTLRenderCommandEncoder,
                               viewport: SIMD2<Float>) {
        var hasAny = false
        for row in rows {
            if !row[keyPath: imageKey].isEmpty {
                hasAny = true
                break
            }
        }
        guard hasAny else {
            return
        }
        encoder.setRenderPipelineState(textPipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        var viewportVar = viewport
        encoder.setVertexBytes(&viewportVar, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        for row in rows {
            for draw in row[keyPath: imageKey] {
                encoder.setVertexBuffer(draw.buffer, offset: 0, index: 0)
                encoder.setFragmentTexture(draw.texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: draw.vertexCount)
            }
        }
    }

    private func buildCursorDrawData(snapshot: TerminalSnapshot,
                                     context: SnapshotRenderContext,
                                     scale: CGFloat,
                                     cellWidth: CGFloat,
                                     cellHeight: CGFloat,
                                     lineDescent: CGFloat,
                                     lineLeading: CGFloat,
                                     yDisp: Int,
                                     firstRow: Int,
                                     lastRow: Int) -> (colorVertices: [ColorVertex],
                                                       glyphVerticesGray: [GlyphVertex],
                                                       glyphVerticesColor: [GlyphVertex]) {
        guard let cursor = snapshot.cursor, !cursor.hidden else {
            return ([], [], [])
        }
        let cursorRow = cursor.absoluteRow
        if cursorRow < firstRow || cursorRow > lastRow {
            return ([], [], [])
        }
        if cursor.visualCol < 0 || cursor.visualCol >= snapshot.cols {
            return ([], [], [])
        }
        let cursorStyle = snapshot.cursorStyle
        let hasFocus = context.cursorHasFocus
        redrawLock.lock()
        let blinkOn = cursorBlinkOn
        redrawLock.unlock()
        if hasFocus && isBlinkStyle(cursorStyle) && !blinkOn {
            return ([], [], [])
        }
        let lineOffset = cellHeight * CGFloat(cursorRow - yDisp + 1)
        let lineOrigin = CGPoint(x: 0, y: context.viewBounds.height - lineOffset)
        let lineOriginPx = CGPoint(x: lineOrigin.x * scale, y: lineOrigin.y * scale)
        let cellWidthPx = cellWidth * scale
        let cellHeightPx = cellHeight * scale
        let doublePosition: CGFloat = cursor.renderMode == .single ? 1.0 : 2.0
        // Span the cursor across the full character so a block/underline cursor
        // covers a full-width (CJK) glyph instead of only its left half, matching
        // the CoreGraphics caret.
        let cursorColumnWidth = CGFloat(cursor.columnWidth)

        let x0 = lineOriginPx.x + CGFloat(cursor.visualCol) * cellWidthPx * doublePosition
        let y0 = lineOriginPx.y
        let x1 = x0 + cellWidthPx * doublePosition * cursorColumnWidth
        let y1 = y0 + cellHeightPx

        let renderData = cursor.renderData
        let cursorColor = colorToSIMD(renderData.cursorColor)
        let cursorClip = ClipRect(minX: Float(x0), minY: Float(y0), maxX: Float(x1), maxY: Float(y1))
        var colorVertices: [ColorVertex] = []
        var glyphVerticesGray: [GlyphVertex] = []
        var glyphVerticesColor: [GlyphVertex] = []

        if !hasFocus {
            // Core Graphics centers its 3-point stroke on the cell boundary.
            // Clipping keeps only the inner half of that stroke.
            let stroke = max(1, 1.5 * scale)
            colorVertices.append(contentsOf: quadVertices(x0: CGFloat(x0),
                                                          y0: CGFloat(y0),
                                                          x1: CGFloat(x1),
                                                          y1: CGFloat(y0 + stroke),
                                                          color: cursorColor))
            colorVertices.append(contentsOf: quadVertices(x0: CGFloat(x0),
                                                          y0: CGFloat(y1 - stroke),
                                                          x1: CGFloat(x1),
                                                          y1: CGFloat(y1),
                                                          color: cursorColor))
            colorVertices.append(contentsOf: quadVertices(x0: CGFloat(x0),
                                                          y0: CGFloat(y0 + stroke),
                                                          x1: CGFloat(x0 + stroke),
                                                          y1: CGFloat(y1 - stroke),
                                                          color: cursorColor))
            colorVertices.append(contentsOf: quadVertices(x0: CGFloat(x1 - stroke),
                                                          y0: CGFloat(y0 + stroke),
                                                          x1: CGFloat(x1),
                                                          y1: CGFloat(y1 - stroke),
                                                          color: cursorColor))
            return (colorVertices, [], [])
        }

        switch cursorStyle {
        case .blinkBar, .steadyBar:
            let barWidth = max(1, 2 * scale)
            colorVertices.append(contentsOf: quadVertices(x0: CGFloat(x0),
                                                          y0: CGFloat(y0),
                                                          x1: CGFloat(x0 + barWidth),
                                                          y1: CGFloat(y1),
                                                          color: cursorColor))
            return (colorVertices, [], [])
        case .blinkUnderline, .steadyUnderline:
            let underlineHeight = max(1, 2 * scale)
            colorVertices.append(contentsOf: quadVertices(x0: CGFloat(x0),
                                                          y0: CGFloat(y0),
                                                          x1: CGFloat(x1),
                                                          y1: CGFloat(y0 + underlineHeight),
                                                          color: cursorColor))
            return (colorVertices, [], [])
        case .blinkBlock, .steadyBlock:
            colorVertices.append(contentsOf: quadVertices(x0: CGFloat(x0),
                                                          y0: CGFloat(y0),
                                                          x1: CGFloat(x1),
                                                          y1: CGFloat(y1),
                                                          color: cursorColor))
        }

        let caretTextColor = renderData.textColor
        if !snapshot.style.textBlinkVisible && renderData.cellAttribute.style.contains(.blink) {
            return (colorVertices, [], [])
        }
        if PowerlineRenderer.shouldRender(codePoint: UInt32(renderData.code),
                                          customGlyphsEnabled: renderData.customBlockGlyphs) {
            let cursorCellWidthPx = max(1, Int(round(cellWidthPx * doublePosition * cursorColumnWidth)))
            let cursorCellHeightPx = max(1, Int(round(cellHeightPx)))
            if let entry = customGlyphEntry(codePoint: UInt32(renderData.code),
                                            cellWidthPx: cursorCellWidthPx,
                                            cellHeightPx: cursorCellHeightPx,
                                            scale: scale,
                                            baseThicknessPx: 0,
                                            antiAlias: true) {
                let atlasSize = Float(grayscaleAtlas.size)
                let u0 = Float(entry.region.x) / atlasSize
                let v0 = Float(entry.region.y) / atlasSize
                let u1 = Float(entry.region.x + entry.region.width) / atlasSize
                let v1 = Float(entry.region.y + entry.region.height) / atlasSize
                let glyphX0 = Float(x0)
                let glyphY0 = Float(y0)
                let glyphX1 = glyphX0 + Float(entry.size.width)
                let glyphY1 = glyphY0 + Float(entry.size.height)
                if let clipped = self.clipRect(glyphX0, glyphY0, glyphX1, glyphY1,
                                               u0, v0, u1, v1, cursorClip) {
                    glyphVerticesGray.append(contentsOf: glyphQuadVertices(x0: clipped.x0,
                                                                           y0: clipped.y0,
                                                                           x1: clipped.x1,
                                                                           y1: clipped.y1,
                                                                           u0: clipped.u0,
                                                                           v0: clipped.v0,
                                                                           u1: clipped.u1,
                                                                           v1: clipped.v1,
                                                                           color: colorToSIMD(caretTextColor)))
                }
            }
            return (colorVertices, glyphVerticesGray, glyphVerticesColor)
        }
        let attributes = renderData.attributes.isEmpty
            ? [.font: renderData.normalFont] : renderData.attributes
        let attributedString = NSAttributedString(
            string: UnicodeUtil.textPresentationAdjusted(renderData.character),
            attributes: attributes)
        let ctline = CTLineCreateWithAttributedString(attributedString)
        guard let runs = CTLineGetGlyphRuns(ctline) as? [CTRun] else {
            return (colorVertices, [], [])
        }
        let yOffset = ceil(lineDescent + lineLeading)
        let textColorSIMD = colorToSIMD(caretTextColor)

        for run in runs {
            let runGlyphsCount = CTRunGetGlyphCount(run)
            if runGlyphsCount == 0 {
                continue
            }
            let runAttributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
            let runFont = runAttributes[.font] as? TTFont ?? renderData.normalFont
            let ctFont = runFont as CTFont
            let scaledFont = scaledFontFor(font: ctFont, scale: scale)

            let runGlyphs = [CGGlyph](unsafeUninitializedCapacity: runGlyphsCount) { bufferPointer, count in
                CTRunGetGlyphs(run, CFRange(), bufferPointer.baseAddress!)
                count = runGlyphsCount
            }
            var coreTextPositions = [CGPoint](repeating: .zero, count: runGlyphsCount)
            CTRunGetPositions(run, CFRange(), &coreTextPositions)

            for i in 0..<runGlyphsCount {
                let glyph = runGlyphs[i]
                guard let entry = glyphEntry(for: scaledFont, glyph: glyph) else {
                    continue
                }
                if entry.size.width <= 0 || entry.size.height <= 0 {
                    continue
                }
                let ctPos = coreTextPositions[i]
                // Center the glyph under the cursor the same way as normal text so
                // a full-width (CJK) character doesn't shift when the caret lands on it.
                let fit = context.glyphSlotFit(font: ctFont, glyph: glyph,
                                               columnWidth: cursor.columnWidth)
                let basePos = CGPoint(x: lineOrigin.x + cellWidth * doublePosition * CGFloat(cursor.visualCol) + fit.dx * doublePosition,
                                      y: lineOrigin.y + yOffset + ctPos.y + fit.dy)
                let pxX = basePos.x * scale + entry.bearing.x * fit.scale
                let pxY = basePos.y * scale + entry.bearing.y * fit.scale
                let x0 = Float(pxX)
                let y0 = Float(pxY)
                let x1 = x0 + Float(entry.size.width * fit.scale)
                let y1 = y0 + Float(entry.size.height * fit.scale)

                let atlasSize = entry.atlasKind == .color ? colorAtlas.size : grayscaleAtlas.size
                let u0 = Float(entry.region.x) / Float(atlasSize)
                let v0 = Float(entry.region.y) / Float(atlasSize)
                let u1 = Float(entry.region.x + entry.region.width) / Float(atlasSize)
                let v1 = Float(entry.region.y + entry.region.height) / Float(atlasSize)

                let color = entry.isColor ? SIMD4<Float>(1, 1, 1, 1) : textColorSIMD
                if let clipped = self.clipRect(x0, y0, x1, y1, u0, v0, u1, v1, cursorClip) {
                    let vertices = glyphQuadVertices(x0: clipped.x0, y0: clipped.y0,
                                                     x1: clipped.x1, y1: clipped.y1,
                                                     u0: clipped.u0, v0: clipped.v0,
                                                     u1: clipped.u1, v1: clipped.v1,
                                                     color: color)
                    switch entry.atlasKind {
                    case .grayscale:
                        glyphVerticesGray.append(contentsOf: vertices)
                    case .color:
                        glyphVerticesColor.append(contentsOf: vertices)
                    }
                }
            }
        }

        return (colorVertices, glyphVerticesGray, glyphVerticesColor)
    }

    private func texture(for image: SnapshotImage) -> MTLTexture? {
        if let cached = imageTextureCache.object(forKey: image) {
            return cached
        }
        var texture: MTLTexture?
        if let cgImage = cgImage(from: image.image) {
            texture = try? textureLoader.newTexture(cgImage: cgImage, options: textureOptions())
        }
        #if os(macOS)
        if texture == nil, let data = image.image.tiffRepresentation {
            texture = try? textureLoader.newTexture(data: data, options: textureOptions())
        }
        #else
        if texture == nil, let data = image.image.pngData() {
            texture = try? textureLoader.newTexture(data: data, options: textureOptions())
        }
        #endif
        if let texture {
            imageTextureCache.setObject(texture, forKey: image)
        } else {
#if DEBUG
            let key = ObjectIdentifier(image)
            if !imageTextureFailures.contains(key) {
                imageTextureFailures.insert(key)
                print("Metal: failed to create texture for image size=\(image.image.size)")
            }
#endif
        }
        return texture
    }

    private func kittyTexture(imageId: UInt32, kitty: SnapshotKitty) -> MTLTexture? {
        guard let kittyImage = kitty.imagesById[imageId] else {
            return nil
        }
        let signature = kittySignature(for: kittyImage.payload)
        if let cached = kittyTextureCache[imageId], cached.signature == signature {
            return cached.texture
        }
        let texture: MTLTexture?
        switch kittyImage.payload {
        case .png(let data):
            texture = try? textureLoader.newTexture(data: data, options: textureOptions())
        case .rgba(let bytes, let width, let height):
            texture = textureFromRGBA(bytes: bytes, width: width, height: height)
        }
        if let texture {
            kittyTextureCache[imageId] = (signature, texture)
        } else {
#if DEBUG
            if !kittyTextureFailures.contains(imageId) {
                kittyTextureFailures.insert(imageId)
                print("Metal: failed to create texture for kitty image id=\(imageId)")
            }
#endif
        }
        return texture
    }

    private func kittySignature(for payload: KittyGraphicsPayload) -> KittyImageSignature {
        switch payload {
        case .png(let data):
            let headHash = hashBytes(data, limit: 64)
            return KittyImageSignature(kind: 1, width: 0, height: 0, byteCount: data.count, headHash: headHash)
        case .rgba(let bytes, let width, let height):
            let headHash = hashBytes(Data(bytes), limit: 64)
            return KittyImageSignature(kind: 2, width: width, height: height, byteCount: bytes.count, headHash: headHash)
        }
    }

    private func hashBytes(_ data: Data, limit: Int) -> UInt32 {
        let count = min(limit, data.count)
        if count == 0 {
            return 0
        }
        var hash: UInt32 = 2166136261
        for byte in data.prefix(count) {
            hash ^= UInt32(byte)
            hash &*= 16777619
        }
        return hash
    }

    private func textureFromRGBA(bytes: [UInt8], width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        let region = MTLRegionMake2D(0, 0, width, height)
        texture.replace(region: region, mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return texture
    }

    private func cgImage(from image: TTImage) -> CGImage? {
        #if os(macOS)
        var rect = CGRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return cgImage
        }
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else {
            return nil
        }
        return bitmap.cgImage
        #else
        return image.cgImage
        #endif
    }

    private func textureOptions() -> [MTKTextureLoader.Option: Any] {
        return [
            .SRGB: false,
            .origin: MTKTextureLoader.Origin.bottomLeft
        ]
    }

    private func imageDraw(texture: MTLTexture,
                           rect: CGRect,
                           uvRect: CGRect,
                           renderMode: BufferLine.RenderLineMode,
                           clipRect: ClipRect?,
                           pivotY: CGFloat,
                           scale: CGFloat) -> ImageDraw? {
        let x0 = rect.minX * scale
        let y0 = rect.minY * scale
        let x1 = rect.maxX * scale
        let y1 = rect.maxY * scale
        let (tx0, ty0, tx1, ty1) = transformImageRect(x0: x0, y0: y0, x1: x1, y1: y1, renderMode: renderMode, pivotY: pivotY)
        let u0 = Float(uvRect.minX)
        let v0 = Float(uvRect.minY)
        let u1 = Float(uvRect.maxX)
        let v1 = Float(uvRect.maxY)
        guard let clipped = self.clipRect(tx0, ty0, tx1, ty1, u0, v0, u1, v1, clipRect) else {
            return nil
        }
        let vertices = glyphQuadVertices(x0: clipped.x0, y0: clipped.y0, x1: clipped.x1, y1: clipped.y1,
                                         u0: clipped.u0, v0: clipped.v0, u1: clipped.u1, v1: clipped.v1,
                                         color: SIMD4<Float>(1, 1, 1, 1))
        return ImageDraw(texture: texture, vertices: vertices)
    }

    private func clipRect(_ x0: Float,
                          _ y0: Float,
                          _ x1: Float,
                          _ y1: Float,
                          _ clip: ClipRect?) -> (Float, Float, Float, Float)? {
        guard let clip = clip else {
            return (x0, y0, x1, y1)
        }
        let minX = max(x0, clip.minX)
        let minY = max(y0, clip.minY)
        let maxX = min(x1, clip.maxX)
        let maxY = min(y1, clip.maxY)
        if minX >= maxX || minY >= maxY {
            return nil
        }
        return (minX, minY, maxX, maxY)
    }

    private func clipRect(_ x0: Float,
                          _ y0: Float,
                          _ x1: Float,
                          _ y1: Float,
                          _ u0: Float,
                          _ v0: Float,
                          _ u1: Float,
                          _ v1: Float,
                          _ clip: ClipRect?) -> (x0: Float, y0: Float, x1: Float, y1: Float,
                                                 u0: Float, v0: Float, u1: Float, v1: Float)? {
        guard let clip = clip else {
            return (x0: x0, y0: y0, x1: x1, y1: y1, u0: u0, v0: v0, u1: u1, v1: v1)
        }
        let width = x1 - x0
        let height = y1 - y0
        if width <= 0 || height <= 0 {
            return nil
        }
        let minX = max(x0, clip.minX)
        let minY = max(y0, clip.minY)
        let maxX = min(x1, clip.maxX)
        let maxY = min(y1, clip.maxY)
        if minX >= maxX || minY >= maxY {
            return nil
        }
        let du = u1 - u0
        let dv = v1 - v0
        let newU0 = u0 + (minX - x0) / width * du
        let newU1 = u0 + (maxX - x0) / width * du
        let newV0 = v0 + (minY - y0) / height * dv
        let newV1 = v0 + (maxY - y0) / height * dv
        return (x0: minX, y0: minY, x1: maxX, y1: maxY,
                u0: newU0, v0: newV0, u1: newU1, v1: newV1)
    }

    private func transformImageRect(x0: CGFloat,
                                    y0: CGFloat,
                                    x1: CGFloat,
                                    y1: CGFloat,
                                    renderMode: BufferLine.RenderLineMode,
                                    pivotY: CGFloat) -> (Float, Float, Float, Float) {
        func transformPoint(_ point: CGPoint) -> CGPoint {
            switch renderMode {
            case .single:
                return point
            case .doubleWidth:
                return CGPoint(x: point.x * 2, y: point.y)
            case .doubledDown, .doubledTop:
                return CGPoint(x: point.x * 2, y: pivotY + (point.y - pivotY) * 2)
            }
        }
        let p0 = transformPoint(CGPoint(x: x0, y: y0))
        let p1 = transformPoint(CGPoint(x: x1, y: y1))
        let minX = min(p0.x, p1.x)
        let minY = min(p0.y, p1.y)
        let maxX = max(p0.x, p1.x)
        let maxY = max(p0.y, p1.y)
        return (Float(minX), Float(minY), Float(maxX), Float(maxY))
    }

    private func kittyAspectFitRect(imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, rect.width > 0, rect.height > 0 else {
            return rect
        }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: rect.origin.x + (rect.width - width) / 2,
                      y: rect.origin.y + (rect.height - height) / 2,
                      width: width,
                      height: height)
    }

    private func appendUnderlineSegments(x0: CGFloat,
                                         x1: CGFloat,
                                         yCenter: CGFloat,
                                         thickness: CGFloat,
                                         color: SIMD4<Float>,
                                         style: UnderlineStyle,
                                         patternScale: CGFloat,
                                         renderMode: BufferLine.RenderLineMode,
                                         clipRect: ClipRect?,
                                         pivotY: CGFloat,
                                         output: inout [ColorCell]) {
        let half = thickness / 2
        let baseY = yCenter
        let dashLength = max(thickness * 2, patternScale * 2)
        let dotLength = max(thickness, patternScale)

        func emitSegment(start: CGFloat, end: CGFloat, centerY: CGFloat) {
            let y0 = centerY - half
            let y1 = centerY + half
            let rects = transformUnderlineRect(x0: start, x1: end, y0: y0, y1: y1, renderMode: renderMode, pivotY: pivotY)
            if let clipped = self.clipRect(rects.0, rects.1, rects.2, rects.3, clipRect) {
                output.append(makeColorCell(x0: clipped.0,
                                            y0: clipped.1,
                                            x1: clipped.2,
                                            y1: clipped.3,
                                            color: color))
            }
        }

        switch style {
        case .curly:
            let amplitude = max(thickness, patternScale)
            let wavelength = max(thickness * 4, patternScale * 4)
            let step = max(thickness, patternScale)
            var x = x0
            while x < x1 {
                let phase = Double((x - x0) / wavelength * (CGFloat.pi * 2))
                let y = baseY + amplitude * CGFloat(sin(phase))
                let end = min(x + step, x1)
                emitSegment(start: x, end: end, centerY: y)
                x = end
            }
        case .dotted, .dashed:
            let segmentLength = style == .dotted ? dotLength : dashLength
            let gapLength = style == .dotted ? (dotLength * 2) : dashLength
            var start = x0
            while start < x1 {
                let end = min(start + segmentLength, x1)
                emitSegment(start: start, end: end, centerY: baseY)
                start += segmentLength + gapLength
            }
        case .none:
            break
        case .double, .single:
            emitSegment(start: x0, end: x1, centerY: baseY)
        }
    }

    private func resolveUnderlineStyle(_ attributes: [NSAttributedString.Key: Any]) -> UnderlineStyle {
        if let raw = attributes[SwiftTermUnderlineStyleKey] as? Int,
           let style = UnderlineStyle(rawValue: UInt8(raw)) {
            return style
        }
        let rawStyle = attributes[.underlineStyle] as? NSUnderlineStyle.RawValue ?? 0
        let underlineStyle = NSUnderlineStyle(rawValue: rawStyle)
        if underlineStyle.contains(.double) {
            return .double
        }
        if underlineStyle.contains(.patternDot) {
            return .dotted
        }
        if underlineStyle.contains(.patternDash) || underlineStyle.contains(.patternDashDot) || underlineStyle.contains(.patternDashDotDot) {
            return .dashed
        }
        return underlineStyle.isEmpty ? .none : .single
    }

    private func transformUnderlineRect(x0: CGFloat,
                                        x1: CGFloat,
                                        y0: CGFloat,
                                        y1: CGFloat,
                                        renderMode: BufferLine.RenderLineMode,
                                        pivotY: CGFloat) -> (Float, Float, Float, Float) {
        func transformPoint(_ point: CGPoint) -> CGPoint {
            switch renderMode {
            case .single:
                return point
            case .doubleWidth:
                return CGPoint(x: point.x * 2, y: point.y)
            case .doubledDown, .doubledTop:
                return CGPoint(x: point.x * 2, y: pivotY + (point.y - pivotY) * 2)
            }
        }
        let p0 = transformPoint(CGPoint(x: x0, y: y0))
        let p1 = transformPoint(CGPoint(x: x1, y: y1))
        let minX = min(p0.x, p1.x)
        let minY = min(p0.y, p1.y)
        let maxX = max(p0.x, p1.x)
        let maxY = max(p0.y, p1.y)
        return (Float(minX), Float(minY), Float(maxX), Float(maxY))
    }

    private static func makeTextPipeline(device: MTLDevice,
                                         library: MTLLibrary,
                                         view: any MetalRenderTarget,
                                         vertexName: String,
                                         fragmentName: String) -> MTLRenderPipelineState? {
        guard let vertex = library.makeFunction(name: vertexName),
              let fragment = library.makeFunction(name: fragmentName) else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = view.renderPixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makeColorPipeline(device: MTLDevice,
                                          library: MTLLibrary,
                                          view: any MetalRenderTarget,
                                          vertexName: String,
                                          fragmentName: String) -> MTLRenderPipelineState? {
        guard let vertex = library.makeFunction(name: vertexName),
              let fragment = library.makeFunction(name: fragmentName) else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = view.renderPixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func isBlinkStyle(_ style: CursorStyle) -> Bool {
        switch style {
        case .blinkBlock, .blinkUnderline, .blinkBar:
            return true
        case .steadyBlock, .steadyUnderline, .steadyBar:
            return false
        }
    }

    /// Starts or stops the cursor blink.
    ///
    /// Called from `render()`, which runs on the render loop under WO-F4. A
    /// `Timer` scheduled there would attach to a run loop that never runs, so
    /// the cursor would simply stop blinking — the timer lives on main, and
    /// `cursorBlinkOn` is shared under `redrawLock`. Only a change in the
    /// wanted state hops to main, so a steady frame costs nothing.
    private func updateCursorBlinkTimer(shouldBlink: Bool) {
        redrawLock.lock()
        let changed = cursorBlinkWanted != shouldBlink
        cursorBlinkWanted = shouldBlink
        if changed && !shouldBlink {
            cursorBlinkOn = true
        }
        redrawLock.unlock()
        guard changed else { return }

        if Thread.isMainThread {
            applyCursorBlinkTimer(shouldBlink: shouldBlink)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.applyCursorBlinkTimer(shouldBlink: shouldBlink)
            }
        }
    }

    private func applyCursorBlinkTimer(shouldBlink: Bool) {
        // Re-read: several changes can queue before main drains them, and the
        // last one written is the one that should win.
        redrawLock.lock()
        let wanted = cursorBlinkWanted
        redrawLock.unlock()
        guard wanted == shouldBlink else { return }

        if shouldBlink {
            guard cursorBlinkTimer == nil else { return }
            redrawLock.lock()
            cursorBlinkOn = true
            redrawLock.unlock()
            cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
                guard let self else {
                    return
                }
                self.redrawLock.lock()
                self.cursorBlinkOn.toggle()
                self.redrawLock.unlock()
                self.requestRedraw?()
            }
        } else if let timer = cursorBlinkTimer {
            timer.invalidate()
            cursorBlinkTimer = nil
        }
    }

    private func pruneKittyTextureCache(kitty: SnapshotKitty) {
        let liveIds = kitty.imagesById
        if kittyTextureCache.isEmpty {
            return
        }
        let staleIds = kittyTextureCache.keys.filter { liveIds[$0] == nil }
        if staleIds.isEmpty {
            return
        }
        for imageId in staleIds {
            kittyTextureCache.removeValue(forKey: imageId)
#if DEBUG
            kittyTextureFailures.remove(imageId)
#endif
        }
    }

    /// Whether a shader library can be built here at all.
    ///
    /// Exposed for tests: under `swift test` the SwiftTerm resource bundle is
    /// not next to the test binary, so Metal cannot be enabled and any test
    /// that needs it must skip rather than fail. Cheap and cached — building
    /// the library once is the only honest way to answer this.
    static let shaderLibraryIsAvailable: Bool = {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return (try? makeLibrary(device: device)) != nil
    }()

    private static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        if let library = device.makeDefaultLibrary(),
           libraryHasRequiredFunctions(library) {
            return library
        }
        if let url = findMetallibURL() {
            do {
                let library = try device.makeLibrary(URL: url)
                if libraryHasRequiredFunctions(library) {
                    return library
                }
            } catch {
                throw MetalError.shaderLibraryLoadFailed(String(describing: error))
            }
        }
        guard let source = loadShaderSource() else {
            throw MetalError.shaderSourceMissing("Apple/Metal/Shaders.metal")
        }
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            if libraryHasRequiredFunctions(library) {
                return library
            }
            throw MetalError.shaderFunctionMissing(requiredShaderFunctions().joined(separator: ", "))
        } catch let error as MetalError {
            throw error
        } catch {
            throw MetalError.shaderCompilationFailed(String(describing: error))
        }
    }

    private static func libraryHasRequiredFunctions(_ library: MTLLibrary) -> Bool {
        for name in requiredShaderFunctions() {
            if library.makeFunction(name: name) == nil {
                return false
            }
        }
        return true
    }

    private static func requiredShaderFunctions() -> [String] {
        return [
            "terminal_text_vertex",
            "terminal_cell_text_vertex",
            "terminal_text_fragment",
            "terminal_text_fragment_gray",
            "terminal_color_vertex",
            "terminal_cell_color_vertex",
            "terminal_color_fragment"
        ]
    }

    private static func loadShaderSource() -> String? {
        for bundle in candidateBundles() {
            if let url = bundle.url(forResource: "Shaders", withExtension: "metal"),
               let source = try? String(contentsOf: url, encoding: .utf8) {
                return source
            }
        }
        return nil
    }

    private static func findMetallibURL() -> URL? {
        for bundle in candidateBundles() {
            if let url = bundle.url(forResource: "default", withExtension: "metallib") {
                return url
            }
            if let resourceURL = bundle.resourceURL,
               let urls = try? FileManager.default.contentsOfDirectory(at: resourceURL,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles]) {
                if let match = urls.first(where: { $0.pathExtension == "metallib" }) {
                    return match
                }
            }
        }
        return nil
    }

    private static func candidateBundles() -> [Bundle] {
        var bundles: [Bundle] = []
        #if SWIFT_PACKAGE
        // Deliberately not `Bundle.module`: SwiftPM's generated accessor for
        // executable targets calls `fatalError` (aborting the whole process,
        // not throwing) instead of returning nil when it can't locate
        // `SwiftTerm_SwiftTerm.bundle`. Its only two candidates are
        // `Bundle.main.bundleURL` (the .app's *root*, not `Contents/Resources`
        // where a packaged .app actually puts SwiftPM resource bundles) and
        // the build machine's absolute `.build/.../SwiftTerm_SwiftTerm.bundle`
        // path baked into the binary at compile time. That means any app that
        // bundles this package and ships the resource bundle correctly still
        // crashes the instant Metal rendering is requested on a machine other
        // than the one that built it. Probe for the same bundle name
        // ourselves — mirroring the accessor's own main-bundle-relative
        // lookup, plus the `Contents/Resources` location it misses — so a
        // missing bundle falls through to the next candidate instead of
        // aborting the process.
        let bundleName = "SwiftTerm_SwiftTerm.bundle"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(bundleName),
           let resourceBundle = Bundle(url: url) {
            bundles.append(resourceBundle)
        }
        if let url = Bundle.main.bundleURL.appendingPathComponent(bundleName) as URL?,
           let resourceBundle = Bundle(url: url) {
            bundles.append(resourceBundle)
        }
        #endif
        bundles.append(Bundle(for: MetalTerminalRenderer.self))
        bundles.append(Bundle.main)
        return bundles
    }
}
#endif
