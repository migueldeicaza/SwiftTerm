#if os(macOS)
import AppKit
import Foundation
import CoreText
import Metal
import MetalKit

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

final class MetalTerminalRenderer: NSObject, MTKViewDelegate {
    private weak var terminalView: TerminalView?
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textPipeline: MTLRenderPipelineState
    private let colorPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let atlas: GlyphAtlas
    private let rasterizer = CoreTextGlyphRasterizer()
    private var glyphCache: [GlyphKey: GlyphEntry] = [:]
    private var scaledFontCache: [GlyphKey: CTFont] = [:]

    init(view: MTKView, terminalView: TerminalView) throws {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else {
            throw MetalError.deviceUnavailable
        }
        self.device = device
        view.device = device
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalError.commandQueueUnavailable
        }
        self.commandQueue = commandQueue
        guard let atlas = GlyphAtlas(device: device) else {
            throw MetalError.atlasUnavailable
        }
        self.atlas = atlas
        let library = try MetalTerminalRenderer.makeLibrary(device: device)
        guard let textPipeline = MetalTerminalRenderer.makeTextPipeline(device: device, library: library, view: view),
              let colorPipeline = MetalTerminalRenderer.makeColorPipeline(device: device, library: library, view: view) else {
            throw MetalError.pipelineCreationFailed("text/color")
        }
        self.textPipeline = textPipeline
        self.colorPipeline = colorPipeline
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

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // The view already updates drawableSize; avoid feedback loops.
    }

    func draw(in view: MTKView) {
        guard let terminalView = terminalView else {
            return
        }
        let scale = terminalView.backingScaleFactor()
        view.drawableSize = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)

        let drawData = buildDrawData(scale: scale)
        guard let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor else {
            return
        }
        let bgColor = colorToSIMD(terminalView.nativeBackgroundColor)
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(Double(bgColor.x),
                                                                         Double(bgColor.y),
                                                                         Double(bgColor.z),
                                                                         Double(bgColor.w))
        passDescriptor.colorAttachments[0].loadAction = .clear

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }
        let viewport = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))

        if !drawData.backgroundVertices.isEmpty {
            if let buffer = makeBuffer(drawData.backgroundVertices) {
                encoder.setRenderPipelineState(colorPipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                var viewportVar = viewport
                encoder.setVertexBytes(&viewportVar, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: drawData.backgroundVertices.count)
            }
        }

        if !drawData.glyphVertices.isEmpty {
            if let buffer = makeBuffer(drawData.glyphVertices) {
                encoder.setRenderPipelineState(textPipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                var viewportVar = viewport
                encoder.setVertexBytes(&viewportVar, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                encoder.setFragmentTexture(atlas.texture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: drawData.glyphVertices.count)
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func buildDrawData(scale: CGFloat) -> (backgroundVertices: [ColorVertex], glyphVertices: [GlyphVertex]) {
        guard let terminalView = terminalView else {
            return ([], [])
        }
        let buffer = terminalView.terminal.displayBuffer
        let cellWidth = terminalView.cellDimension.width
        let cellHeight = terminalView.cellDimension.height
        let lineDescent = CTFontGetDescent(terminalView.fontSet.normal)
        let lineLeading = CTFontGetLeading(terminalView.fontSet.normal)
        let yOffset = ceil(lineDescent + lineLeading)

        let firstRow = buffer.yDisp
        let lastRow = min(buffer.lines.count - 1, buffer.yDisp + buffer.rows - 1)
        if buffer.lines.count == 0 || firstRow > lastRow {
            return ([], [])
        }
        var backgroundVertices: [ColorVertex] = []
        var glyphVertices: [GlyphVertex] = []

        for row in firstRow...lastRow {
            if row < 0 || row >= buffer.lines.count {
                continue
            }
            let line = buffer.lines[row]
            let lineOffset = cellHeight * CGFloat(row - buffer.yDisp + 1)
            let lineOrigin = CGPoint(x: 0, y: terminalView.frame.height - lineOffset)
            let lineInfo = terminalView.buildAttributedString(row: row, line: line, cols: buffer.cols)

            for segment in lineInfo.segments {
                guard segment.attributedString.length > 0 else {
                    continue
                }
                let ctline = CTLineCreateWithAttributedString(segment.attributedString)
                guard let runs = CTLineGetGlyphRuns(ctline) as? [CTRun] else {
                    continue
                }
                var processedGlyphs = 0
                for run in runs {
                    let runGlyphsCount = CTRunGetGlyphCount(run)
                    if runGlyphsCount == 0 {
                        continue
                    }
                    let runAttributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
                    let startColumn = segment.column + (processedGlyphs * segment.columnWidth)
                    let endColumn = startColumn + (runGlyphsCount * segment.columnWidth)
                    var backgroundColor: NSColor?
                    if runAttributes.keys.contains(.selectionBackgroundColor) {
                        backgroundColor = runAttributes[.selectionBackgroundColor] as? NSColor
                    } else if runAttributes.keys.contains(.backgroundColor) {
                        backgroundColor = runAttributes[.backgroundColor] as? NSColor
                    }
                    if let backgroundColor = backgroundColor {
                        let columnSpan = max(0, endColumn - startColumn)
                        if columnSpan > 0 {
                            let x0 = (lineOrigin.x + (CGFloat(startColumn) * cellWidth)) * scale
                            let y0 = lineOrigin.y * scale
                            let x1 = (lineOrigin.x + (CGFloat(startColumn + columnSpan) * cellWidth)) * scale
                            let y1 = (lineOrigin.y + cellHeight) * scale
                            let color = colorToSIMD(backgroundColor)
                            backgroundVertices.append(contentsOf: quadVertices(x0: x0, y0: y0, x1: x1, y1: y1, color: color))
                        }
                    }
                    processedGlyphs += runGlyphsCount
                }
            }

            for segment in lineInfo.segments {
                guard segment.attributedString.length > 0 else {
                    continue
                }
                let ctline = CTLineCreateWithAttributedString(segment.attributedString)
                guard let runs = CTLineGetGlyphRuns(ctline) as? [CTRun] else {
                    continue
                }
                var processedGlyphs = 0
                for run in runs {
                    let runGlyphsCount = CTRunGetGlyphCount(run)
                    if runGlyphsCount == 0 {
                        continue
                    }
                    let runAttributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
                    let runFont = runAttributes[.font] as? NSFont ?? terminalView.fontSet.normal
                    let ctFont = runFont as CTFont
                    let scaledFont = scaledFontFor(font: ctFont, scale: scale)
                    let startColumn = segment.column + (processedGlyphs * segment.columnWidth)

                    let runGlyphs = [CGGlyph](unsafeUninitializedCapacity: runGlyphsCount) { bufferPointer, count in
                        CTRunGetGlyphs(run, CFRange(), bufferPointer.baseAddress!)
                        count = runGlyphsCount
                    }
                    var coreTextPositions = [CGPoint](repeating: .zero, count: runGlyphsCount)
                    CTRunGetPositions(run, CFRange(), &coreTextPositions)

                    let firstCoreTextX = coreTextPositions.first?.x ?? 0
                    let baseX = lineOrigin.x + (cellWidth * CGFloat(startColumn))
                    let xOffset = baseX - firstCoreTextX

                    let textColor = runAttributes[.foregroundColor] as? NSColor ?? terminalView.nativeForegroundColor
                    let textColorSIMD = colorToSIMD(textColor)

                    for i in 0..<runGlyphsCount {
                        let glyph = runGlyphs[i]
                        guard let entry = glyphEntry(for: scaledFont, glyph: glyph) else {
                            continue
                        }
                        if entry.size.width <= 0 || entry.size.height <= 0 {
                            continue
                        }
                        let ctPos = coreTextPositions[i]
                        let basePos = CGPoint(x: ctPos.x + xOffset,
                                              y: lineOrigin.y + yOffset + ctPos.y)
                        let pxX = basePos.x * scale + entry.bearing.x
                        let pxY = basePos.y * scale + entry.bearing.y

                        let x0 = Float(pxX)
                        let y0 = Float(pxY)
                        let x1 = Float(pxX + entry.size.width)
                        let y1 = Float(pxY + entry.size.height)

                        let u0 = Float(entry.region.x) / Float(atlas.size)
                        let v0 = Float(entry.region.y) / Float(atlas.size)
                        let u1 = Float(entry.region.x + entry.region.width) / Float(atlas.size)
                        let v1 = Float(entry.region.y + entry.region.height) / Float(atlas.size)

                        let color = entry.isColor ? SIMD4<Float>(1, 1, 1, 1) : textColorSIMD
                        glyphVertices.append(contentsOf: glyphQuadVertices(x0: x0, y0: y0, x1: x1, y1: y1,
                                                                           u0: u0, v0: v0, u1: u1, v1: v1,
                                                                           color: color))
                    }
                    processedGlyphs += runGlyphsCount
                }
            }
        }

        return (backgroundVertices, glyphVertices)
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
        guard let region = atlas.ensureRegion(width: bitmap.width, height: bitmap.height) else {
            return nil
        }
        atlas.write(region: region, pixels: bitmap.pixels, width: bitmap.width, height: bitmap.height)
        let entry = GlyphEntry(region: region,
                               size: CGSize(width: bitmap.width, height: bitmap.height),
                               bearing: bitmap.bearing,
                               isColor: bitmap.isColor)
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

    private func colorToSIMD(_ color: NSColor) -> SIMD4<Float> {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
    }

    private func makeBuffer<T>(_ vertices: [T]) -> MTLBuffer? {
        guard !vertices.isEmpty else {
            return nil
        }
        return vertices.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
        }
    }

    private static func makeTextPipeline(device: MTLDevice, library: MTLLibrary, view: MTKView) -> MTLRenderPipelineState? {
        guard let vertex = library.makeFunction(name: "terminal_text_vertex"),
              let fragment = library.makeFunction(name: "terminal_text_fragment") else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = view.colorPixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makeColorPipeline(device: MTLDevice, library: MTLLibrary, view: MTKView) -> MTLRenderPipelineState? {
        guard let vertex = library.makeFunction(name: "terminal_color_vertex"),
              let fragment = library.makeFunction(name: "terminal_color_fragment") else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        if let library = device.makeDefaultLibrary() {
            return library
        }
        if let url = findMetallibURL() {
            do {
                return try device.makeLibrary(URL: url)
            } catch {
                throw MetalError.shaderLibraryLoadFailed(String(describing: error))
            }
        }
        guard let source = loadShaderSource() else {
            throw MetalError.shaderSourceMissing("Apple/Metal/Shaders.metal")
        }
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw MetalError.shaderCompilationFailed(String(describing: error))
        }
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
        bundles.append(Bundle.module)
        #endif
        bundles.append(Bundle(for: MetalTerminalRenderer.self))
        bundles.append(Bundle.main)
        return bundles
    }
}
#endif
