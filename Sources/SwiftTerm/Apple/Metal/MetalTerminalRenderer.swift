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

struct ImageDraw {
    let texture: MTLTexture
    let vertices: [GlyphVertex]
}

struct KittyImageSignature: Hashable {
    let kind: UInt8
    let width: Int
    let height: Int
    let byteCount: Int
    let headHash: UInt32
}

final class MetalTerminalRenderer: NSObject, MTKViewDelegate {
    private weak var terminalView: TerminalView?
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textPipeline: MTLRenderPipelineState
    private let colorPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let textureLoader: MTKTextureLoader
    private let atlas: GlyphAtlas
    private let rasterizer = CoreTextGlyphRasterizer()
    private var glyphCache: [GlyphKey: GlyphEntry] = [:]
    private var scaledFontCache: [GlyphKey: CTFont] = [:]
    private let imageTextureCache = NSMapTable<AnyObject, MTLTexture>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var kittyTextureCache: [UInt32: (signature: KittyImageSignature, texture: MTLTexture)] = [:]
#if DEBUG
    private var imageTextureFailures: Set<ObjectIdentifier> = []
    private var kittyTextureFailures: Set<UInt32> = []
#endif

    init(view: MTKView, terminalView: TerminalView) throws {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else {
            throw MetalError.deviceUnavailable
        }
        self.device = device
        view.device = device
        self.textureLoader = MTKTextureLoader(device: device)
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

        drawImageBatches(drawData.underImageDraws, encoder: encoder, viewport: viewport)

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

        if !drawData.decorationVertices.isEmpty {
            if let buffer = makeBuffer(drawData.decorationVertices) {
                encoder.setRenderPipelineState(colorPipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                var viewportVar = viewport
                encoder.setVertexBytes(&viewportVar, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: drawData.decorationVertices.count)
            }
        }

        drawImageBatches(drawData.placeholderImageDraws, encoder: encoder, viewport: viewport)
        drawImageBatches(drawData.overImageDraws, encoder: encoder, viewport: viewport)
        drawImageBatches(drawData.otherImageDraws, encoder: encoder, viewport: viewport)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func buildDrawData(scale: CGFloat) -> (backgroundVertices: [ColorVertex],
                                                  underImageDraws: [ImageDraw],
                                                  glyphVertices: [GlyphVertex],
                                                  decorationVertices: [ColorVertex],
                                                  placeholderImageDraws: [ImageDraw],
                                                  overImageDraws: [ImageDraw],
                                                  otherImageDraws: [ImageDraw]) {
        guard let terminalView = terminalView else {
            return ([], [], [], [], [], [], [])
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
            return ([], [], [], [], [], [], [])
        }
        var backgroundVertices: [ColorVertex] = []
        var glyphVertices: [GlyphVertex] = []
        var decorationVertices: [ColorVertex] = []
        var underImageDraws: [ImageDraw] = []
        var placeholderImageDraws: [ImageDraw] = []
        var overImageDraws: [ImageDraw] = []
        var otherImageDraws: [ImageDraw] = []
        let isAltBuffer = terminalView.terminal.isCurrentBufferAlternate
        var virtualPlacementsByImageId: [UInt32: [KittyPlacementRecord]] = [:]
        if !terminalView.terminal.kittyGraphicsState.placementsByKey.isEmpty {
            for record in terminalView.terminal.kittyGraphicsState.placementsByKey.values
            where record.isVirtual && record.isAlternateBuffer == isAltBuffer {
                virtualPlacementsByImageId[record.imageId, default: []].append(record)
            }
        }

        for row in firstRow...lastRow {
            if row < 0 || row >= buffer.lines.count {
                continue
            }
            let line = buffer.lines[row]
            let renderMode = line.renderMode
            let lineOffset = cellHeight * CGFloat(row - buffer.yDisp + 1)
            let lineOrigin = CGPoint(x: 0, y: terminalView.frame.height - lineOffset)
            let rowBase = lineOrigin.y + cellHeight
            let lineInfo = terminalView.buildAttributedString(row: row, line: line, cols: buffer.cols)
            let lineOriginPx = CGPoint(x: lineOrigin.x * scale, y: lineOrigin.y * scale)
            let cellWidthPx = cellWidth * scale
            let cellHeightPx = cellHeight * scale
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
            let underlinePosition = terminalView.fontSet.underlinePosition()
            let underlineThickness = max(round(scale * terminalView.fontSet.underlineThickness()) / scale, 0.5)

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
                            let x0 = lineOriginPx.x + (CGFloat(startColumn) * cellWidthPx)
                            let y0 = lineOriginPx.y
                            let x1 = lineOriginPx.x + (CGFloat(startColumn + columnSpan) * cellWidthPx)
                            let y1 = lineOriginPx.y + cellHeightPx
                            let (tx0, ty0, tx1, ty1) = transformRect(x0: x0, y0: y0, x1: x1, y1: y1)
                            let color = colorToSIMD(backgroundColor)
                            backgroundVertices.append(contentsOf: quadVertices(x0: CGFloat(tx0), y0: CGFloat(ty0),
                                                                               x1: CGFloat(tx1), y1: CGFloat(ty1),
                                                                               color: color))
                        }
                    }
                    processedGlyphs += runGlyphsCount
                }
            }

            if let images = lineInfo.images {
                var underTextImages: [TerminalView.AppleImage] = []
                var overTextKittyImages: [TerminalView.AppleImage] = []
                var otherImages: [TerminalView.AppleImage] = []
                for basicImage in images {
                    guard let image = basicImage as? TerminalView.AppleImage else {
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
                let sortKitty: (TerminalView.AppleImage, TerminalView.AppleImage) -> Bool = { lhs, rhs in
                    if lhs.kittyZIndex != rhs.kittyZIndex {
                        return lhs.kittyZIndex < rhs.kittyZIndex
                    }
                    let leftId = lhs.kittyImageId ?? 0
                    let rightId = rhs.kittyImageId ?? 0
                    return leftId < rightId
                }
                underTextImages.sort(by: sortKitty)
                overTextKittyImages.sort(by: sortKitty)

                let offsetScale = terminalView.getImageScale()
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
                                            pivotY: pivotY,
                                            scale: scale) {
                        otherImageDraws.append(draw)
                    }
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

                        let x0 = pxX
                        let y0 = pxY
                        let x1 = pxX + entry.size.width
                        let y1 = pxY + entry.size.height
                        let (tx0, ty0, tx1, ty1) = transformRect(x0: x0, y0: y0, x1: x1, y1: y1)

                        let u0 = Float(entry.region.x) / Float(atlas.size)
                        let v0 = Float(entry.region.y) / Float(atlas.size)
                        let u1 = Float(entry.region.x + entry.region.width) / Float(atlas.size)
                        let v1 = Float(entry.region.y + entry.region.height) / Float(atlas.size)

                        let color = entry.isColor ? SIMD4<Float>(1, 1, 1, 1) : textColorSIMD
                        glyphVertices.append(contentsOf: glyphQuadVertices(x0: tx0, y0: ty0, x1: tx1, y1: ty1,
                                                                           u0: u0, v0: v0, u1: u1, v1: v1,
                                                                           color: color))
                    }

                    if let rawStyle = runAttributes[.underlineStyle] as? Int,
                       rawStyle != 0 {
                        let style = NSUnderlineStyle(rawValue: rawStyle)
                        let underlineColor = (runAttributes[.underlineColor] as? NSColor) ?? terminalView.nativeForegroundColor
                        let underlineColorSIMD = colorToSIMD(underlineColor)
                        let isDouble = style.contains(.double)
                        let isDash = style.contains(.patternDash)
                        let dashLength = 2.0 * scale

                        for i in 0..<runGlyphsCount {
                            let ctPos = coreTextPositions[i]
                            let basePos = CGPoint(x: ctPos.x + xOffset,
                                                  y: lineOrigin.y + yOffset + ctPos.y)
                            let x0 = basePos.x * scale
                            let x1 = (basePos.x + cellWidth) * scale
                            let yCenter = (basePos.y + underlinePosition) * scale
                            let thickness = underlineThickness * scale
                            appendUnderlineSegments(x0: x0,
                                                    x1: x1,
                                                    yCenter: yCenter,
                                                    thickness: thickness,
                                                    color: underlineColorSIMD,
                                                    dash: isDash,
                                                    dashLength: dashLength,
                                                    renderMode: renderMode,
                                                    pivotY: pivotY,
                                                    output: &decorationVertices)
                            if isDouble {
                                let yDouble = (basePos.y + underlinePosition - underlineThickness - 1) * scale
                                appendUnderlineSegments(x0: x0,
                                                        x1: x1,
                                                        yCenter: yDouble,
                                                        thickness: thickness,
                                                        color: underlineColorSIMD,
                                                        dash: isDash,
                                                        dashLength: dashLength,
                                                        renderMode: renderMode,
                                                        pivotY: pivotY,
                                                        output: &decorationVertices)
                            }
                        }
                    }

                    processedGlyphs += runGlyphsCount
                }
            }

            if !lineInfo.kittyPlaceholders.isEmpty {
                for placeholder in lineInfo.kittyPlaceholders {
                    guard let records = virtualPlacementsByImageId[placeholder.imageId] else {
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
                    guard let texture = kittyTexture(imageId: placeholder.imageId) else {
                        continue
                    }

                    let offsetScale = terminalView.getImageScale()
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
                                            pivotY: pivotY,
                                            scale: scale) {
                        placeholderImageDraws.append(draw)
                    }
                }
            }
        }

        return (backgroundVertices,
                underImageDraws,
                glyphVertices,
                decorationVertices,
                placeholderImageDraws,
                overImageDraws,
                otherImageDraws)
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

    private func texture(for image: TerminalView.AppleImage) -> MTLTexture? {
        if let cached = imageTextureCache.object(forKey: image) {
            return cached
        }
        var texture: MTLTexture?
        if let cgImage = cgImage(from: image.image) {
            texture = try? textureLoader.newTexture(cgImage: cgImage, options: textureOptions())
        }
        if texture == nil, let data = image.image.tiffRepresentation {
            texture = try? textureLoader.newTexture(data: data, options: textureOptions())
        }
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

    private func kittyTexture(imageId: UInt32) -> MTLTexture? {
        guard let terminalView = terminalView,
              let kittyImage = terminalView.terminal.kittyGraphicsState.imagesById[imageId] else {
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

    private func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return cgImage
        }
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else {
            return nil
        }
        return bitmap.cgImage
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
        let vertices = glyphQuadVertices(x0: tx0, y0: ty0, x1: tx1, y1: ty1,
                                         u0: u0, v0: v0, u1: u1, v1: v1,
                                         color: SIMD4<Float>(1, 1, 1, 1))
        return ImageDraw(texture: texture, vertices: vertices)
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
                                         dash: Bool,
                                         dashLength: CGFloat,
                                         renderMode: BufferLine.RenderLineMode,
                                         pivotY: CGFloat,
                                         output: inout [ColorVertex]) {
        let half = thickness / 2
        let y0 = yCenter - half
        let y1 = yCenter + half
        let segmentLength = dash ? max(dashLength, 1) : (x1 - x0)
        var start = x0
        while start < x1 {
            let end = dash ? min(start + segmentLength, x1) : x1
            let rects = transformUnderlineRect(x0: start, x1: end, y0: y0, y1: y1, renderMode: renderMode, pivotY: pivotY)
            output.append(contentsOf: quadVertices(x0: CGFloat(rects.0),
                                                   y0: CGFloat(rects.1),
                                                   x1: CGFloat(rects.2),
                                                   y1: CGFloat(rects.3),
                                                   color: color))
            if !dash {
                break
            }
            start += segmentLength * 2
        }
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
