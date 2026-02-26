//
//  MetalTerminalRenderer.swift
//
//  GPU-accelerated terminal renderer using Metal.
//  Renders terminal cells in two passes: background quads, then text glyphs.
//  Shader source is compiled at runtime for SPM compatibility.
//

#if os(macOS)
import Metal
import MetalKit
import QuartzCore
import CoreText
import AppKit

// MARK: - GPU Data Structures

/// Per-cell data sent to the GPU. Must match the CellData struct in the shader.
struct CellData {
    var glyphIndex: UInt16 = 0
    var fgR: UInt8 = 255, fgG: UInt8 = 255, fgB: UInt8 = 255, fgA: UInt8 = 255
    var bgR: UInt8 = 0, bgG: UInt8 = 0, bgB: UInt8 = 0, bgA: UInt8 = 255
    var flags: UInt16 = 0
    var padding: UInt16 = 0
}

/// Per-glyph entry in the glyph lookup buffer. Must match GlyphEntry in the shader.
struct GlyphEntryData {
    var uvRect: SIMD4<Float> = .zero   // u0, v0, u1, v1
    var bearing: SIMD2<Float> = .zero  // bearingX, bearingY
    var size: SIMD2<Float> = .zero     // glyph width, height in pixels
}

/// Uniform data for the shader. Must match Uniforms in the shader.
struct Uniforms {
    var viewportSize: SIMD2<Float> = .zero
    var cellSize: SIMD2<Float> = .zero
    var atlasSize: SIMD2<Float> = .zero
    var cols: UInt32 = 0
    var rows: UInt32 = 0
    var time: Float = 0
    var blinkOn: UInt32 = 1
    var scrollY: Float = 0          // Viewport scroll offset in pixels (for smooth scrolling)
    var backingScale: Float = 1     // Screen backing scale factor (e.g. 2.0 on Retina)
    var _pad: Float = 0             // Align to 16 bytes
}

/// Per-image-quad data sent to the GPU for image rendering.
struct ImageQuadData {
    var position: SIMD2<Float> = .zero  // top-left pixel position
    var size: SIMD2<Float> = .zero      // size in pixels
}

// MARK: - MetalTerminalRenderer

/// GPU-accelerated terminal renderer using Metal.
///
/// Renders the terminal in four instanced draw passes:
/// 1. **Background pass** — draws colored quads for each cell's background
/// 2. **Text pass** — draws glyph alpha from the atlas, tinted with foreground color
/// 3. **Decoration pass** — underline, strikethrough, cursor decorations
/// 4. **Image pass** — draws Sixel/Kitty images as textured quads
public class MetalTerminalRenderer: TerminalRenderer {

    // MARK: - Metal Core

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var bgPipelineState: MTLRenderPipelineState
    var textPipelineState: MTLRenderPipelineState
    var decoPipelineState: MTLRenderPipelineState
    var imagePipelineState: MTLRenderPipelineState

    // MARK: - Buffers

    var cellBuffer: MTLBuffer?
    var glyphEntryBuffer: MTLBuffer?
    var uniformBuffer: MTLBuffer

    // MARK: - Atlas & View

    var glyphAtlas: GlyphAtlas?
    weak var terminalView: TerminalView?
    var metalLayer: CAMetalLayer?

    // MARK: - State

    var cols: Int = 0
    var rows: Int = 0
    var cellDims: CellDimensions = CellDimensions(width: 8, height: 16, descent: 3, leading: 1)
    /// Cell dimensions used to build the current glyph atlas (in logical pixels).
    private var atlasCellWidth: CGFloat = 0
    private var atlasCellHeight: CGFloat = 0
    var viewportSize: CGSize = .zero
    /// Whether the terminal is scrolled to the bottom (auto-scroll active).
    private(set) var isScrolledToBottom: Bool = true

    /// Blink state for blinking text attribute (SGR 5) and cursor blink.
    private var blinkOn: Bool = true
    private var blinkTimer: Timer?

    /// Map from GlyphKey to glyph entry index in the GPU buffer.
    private var glyphIndexMap: [GlyphKey: UInt16] = [:]
    /// Ordered glyph entries for the GPU buffer.
    private var glyphEntries: [GlyphEntryData] = []
    /// Whether the glyph entry buffer needs updating.
    private var glyphBufferDirty = true

    // MARK: - Image Cache

    /// Cache of MTLTextures keyed by the identity of the source TerminalImage object.
    private var imageTextureCache: [ObjectIdentifier: MTLTexture] = [:]
    /// Image quads collected during cell buffer update, rendered in the image pass.
    private var pendingImageQuads: [(quad: ImageQuadData, texture: MTLTexture)] = []

    // MARK: - Availability

    /// Returns `true` if a Metal device is available on this system.
    public static var isAvailable: Bool {
        return MTLCreateSystemDefaultDevice() != nil
    }

    // MARK: - Initialization

    /// Creates a new Metal terminal renderer.
    ///
    /// - Parameter device: The Metal device to use. Defaults to the system default device.
    /// - Throws: `fatalError` if Metal is not available or pipeline creation fails.
    public init(device: MTLDevice? = nil) {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else {
            fatalError("MetalTerminalRenderer: Metal is not available on this system")
        }
        self.device = dev

        guard let queue = dev.makeCommandQueue() else {
            fatalError("MetalTerminalRenderer: failed to create command queue")
        }
        self.commandQueue = queue

        // Compile shaders from embedded source
        let library: MTLLibrary
        do {
            library = try dev.makeLibrary(source: MetalTerminalRenderer.shaderSource, options: nil)
        } catch {
            fatalError("MetalTerminalRenderer: failed to compile shaders: \(error)")
        }

        // Background pipeline
        let bgDesc = MTLRenderPipelineDescriptor()
        bgDesc.vertexFunction = library.makeFunction(name: "bgVertex")
        bgDesc.fragmentFunction = library.makeFunction(name: "bgFragment")
        bgDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            bgPipelineState = try dev.makeRenderPipelineState(descriptor: bgDesc)
        } catch {
            fatalError("MetalTerminalRenderer: failed to create bg pipeline: \(error)")
        }

        // Text pipeline (alpha blending enabled)
        let textDesc = MTLRenderPipelineDescriptor()
        textDesc.vertexFunction = library.makeFunction(name: "textVertex")
        textDesc.fragmentFunction = library.makeFunction(name: "textFragment")
        textDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        textDesc.colorAttachments[0].isBlendingEnabled = true
        textDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        textDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        textDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        textDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            textPipelineState = try dev.makeRenderPipelineState(descriptor: textDesc)
        } catch {
            fatalError("MetalTerminalRenderer: failed to create text pipeline: \(error)")
        }

        // Decoration pipeline (underline, strikethrough — drawn after text)
        let decoDesc = MTLRenderPipelineDescriptor()
        decoDesc.vertexFunction = library.makeFunction(name: "decoVertex")
        decoDesc.fragmentFunction = library.makeFunction(name: "decoFragment")
        decoDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        decoDesc.colorAttachments[0].isBlendingEnabled = true
        decoDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        decoDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        decoDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        decoDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            decoPipelineState = try dev.makeRenderPipelineState(descriptor: decoDesc)
        } catch {
            fatalError("MetalTerminalRenderer: failed to create deco pipeline: \(error)")
        }

        // Image pipeline (alpha blending for Sixel/Kitty images)
        let imgDesc = MTLRenderPipelineDescriptor()
        imgDesc.vertexFunction = library.makeFunction(name: "imageVertex")
        imgDesc.fragmentFunction = library.makeFunction(name: "imageFragment")
        imgDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        imgDesc.colorAttachments[0].isBlendingEnabled = true
        imgDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        imgDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        imgDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        imgDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            imagePipelineState = try dev.makeRenderPipelineState(descriptor: imgDesc)
        } catch {
            fatalError("MetalTerminalRenderer: failed to create image pipeline: \(error)")
        }

        // Uniform buffer
        var uniforms = Uniforms()
        uniformBuffer = dev.makeBuffer(bytes: &uniforms, length: MemoryLayout<Uniforms>.stride, options: .storageModeShared)!

        // Reserve glyph index 0 as "empty / space" glyph
        glyphEntries.append(GlyphEntryData())
    }

    // MARK: - TerminalRenderer Protocol

    public func setup(view: TerminalView) {
        self.terminalView = view

        // Configure CAMetalLayer on the view's layer
        if view.layer == nil {
            view.wantsLayer = true
        }
        guard let viewLayer = view.layer else {
            fatalError("MetalTerminalRenderer: failed to get layer from view")
        }
        setupMetalLayer(on: viewLayer, size: view.bounds.size)

        // Set up glyph atlas with the view's font set
        setupGlyphAtlas()

        // Start blink timer for blinking text (SGR 5) and cursor blink
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            self?.blinkOn.toggle()
            self?.terminalView?.setNeedsDisplay(self?.terminalView?.bounds ?? .zero)
        }
    }

    deinit {
        blinkTimer?.invalidate()
    }

    public func draw(
        in context: CGContext,
        dirtyRect: CGRect,
        cellDimensions: CellDimensions,
        bufferOffset: Int
    ) {
         self.cellDims = cellDimensions

        guard let view = terminalView else { return }
        let terminal = view.terminal!

        // Update Metal layer frame and drawable size to match view
        let backingScale = view.window?.backingScaleFactor ?? 1.0
        let drawableWidth = view.bounds.width * backingScale
        let drawableHeight = view.bounds.height * backingScale
        viewportSize = CGSize(width: drawableWidth, height: drawableHeight)

        if let ml = metalLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ml.frame = view.bounds
            ml.drawableSize = CGSize(width: drawableWidth, height: drawableHeight)
            ml.contentsScale = backingScale
            CATransaction.commit()
        }

        // Rebuild glyph atlas if backing scale or cell dimensions changed
        if backingScale != atlasScale || cellDimensions.width != atlasCellWidth || cellDimensions.height != atlasCellHeight {
            glyphIndexMap.removeAll()
            glyphEntries.removeAll()
            glyphEntries.append(GlyphEntryData())
            glyphBufferDirty = true
            setupGlyphAtlas(scale: backingScale)
        }

        // Populate cell buffer from terminal state
        let displayBuffer = terminal.buffer
        let termCols = terminal.cols
        let termRows = terminal.rows
        self.cols = termCols
        self.rows = termRows

        updateCellBuffer(terminal: terminal, displayBuffer: displayBuffer, cols: termCols, rows: termRows, bufferOffset: bufferOffset)

        // Collect image quads from visible buffer lines
        collectImageQuads(displayBuffer: displayBuffer, rows: termRows, bufferOffset: bufferOffset, backingScale: backingScale)

        // Update uniforms
        updateUniforms(backingScale: Float(backingScale))

        // Update glyph entry buffer if needed
        if glyphBufferDirty {
            updateGlyphEntryBuffer()
        }

        // Render
        renderFrame()
    }

    public func resize(cols: Int, rows: Int, cellDimensions: CellDimensions) {
        self.cols = cols
        self.rows = rows
        self.cellDims = cellDimensions

        // Recreate cell buffer for new dimensions
        let cellCount = cols * rows
        let bufferSize = cellCount * MemoryLayout<CellData>.stride
        cellBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)
    }

    public func colorsChanged() {
        // Colors are read fresh each frame from the terminal buffer
    }

    public func fontChanged() {
        // Rebuild glyph atlas with new fonts
        glyphIndexMap.removeAll()
        glyphEntries.removeAll()
        glyphEntries.append(GlyphEntryData()) // re-reserve index 0
        glyphBufferDirty = true
        imageTextureCache.removeAll()

        setupGlyphAtlas()
    }

    public func invalidateAll() {
        glyphAtlas?.invalidateAll()
        glyphIndexMap.removeAll()
        glyphEntries.removeAll()
        glyphEntries.append(GlyphEntryData()) // re-reserve index 0
        glyphBufferDirty = true
        imageTextureCache.removeAll()
    }

    // MARK: - Internal Setup

    private func setupMetalLayer(on layer: CALayer, size: CGSize) {
        let metal = CAMetalLayer()
        metal.device = device
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        metal.frame = CGRect(origin: .zero, size: size)
        metal.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        metal.drawableSize = CGSize(
            width: size.width * metal.contentsScale,
            height: size.height * metal.contentsScale
        )

        layer.addSublayer(metal)
        self.metalLayer = metal
    }

    private var atlasScale: CGFloat = 1

    private func setupGlyphAtlas() {
        setupGlyphAtlas(scale: terminalView?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
    }

    private func setupGlyphAtlas(scale: CGFloat) {
        guard let view = terminalView else { return }

        let fontSet = view.fontSet
        let atlasFonts = GlyphAtlasFontSet(
            normal: fontSet.normal,
            bold: fontSet.bold,
            italic: fontSet.italic,
            boldItalic: fontSet.boldItalic
        )

        // Rasterize at backing resolution for 1:1 texel-to-pixel mapping on Retina
        atlasScale = scale
        atlasCellWidth = cellDims.width
        atlasCellHeight = cellDims.height
        let cellW = Int(ceil(cellDims.width * scale))
        let cellH = Int(ceil(cellDims.height * scale))

        glyphAtlas = GlyphAtlas(
            device: device,
            cellWidth: cellW,
            cellHeight: cellH,
            fonts: atlasFonts,
            scale: scale
        )
    }

    // MARK: - Cell Buffer Update

    private func updateCellBuffer(terminal: Terminal, displayBuffer: Buffer, cols: Int, rows: Int, bufferOffset: Int) {
        let cellCount = cols * rows
        let requiredSize = cellCount * MemoryLayout<CellData>.stride

        // Track auto-scroll state: at bottom when yDisp == yBase
        isScrolledToBottom = (displayBuffer.yDisp == displayBuffer.yBase)

        // Recreate buffer if size changed
        if cellBuffer == nil || cellBuffer!.length < requiredSize {
            cellBuffer = device.makeBuffer(length: requiredSize, options: .storageModeShared)
        }

        guard let buffer = cellBuffer else { return }
        let cells = buffer.contents().bindMemory(to: CellData.self, capacity: cellCount)

        // Selection: pre-compute selection background color
        var selR: UInt8 = 153, selG: UInt8 = 204, selB: UInt8 = 255
        if let selColor = terminalView?.selectedTextBackgroundColor.usingColorSpace(.sRGB) {
            selR = UInt8(selColor.redComponent * 255)
            selG = UInt8(selColor.greenComponent * 255)
            selB = UInt8(selColor.blueComponent * 255)
        }

        // Cursor: determine visibility and screen position
        let cursorScreenRow = displayBuffer.yBase + displayBuffer.y - bufferOffset
        let cursorCol = displayBuffer.x
        let cursorStyle = terminal.options.cursorStyle
        let isBlinkCursor: Bool
        switch cursorStyle {
        case .blinkBlock, .blinkBar, .blinkUnderline:
            isBlinkCursor = true
        default:
            isBlinkCursor = false
        }
        let cursorBlinkOn = !isBlinkCursor || blinkOn
        let showCursor = (terminalView?.hasFocus ?? false) && cursorBlinkOn
            && cursorScreenRow >= 0 && cursorScreenRow < rows

        for row in 0..<rows {
            // Use bufferOffset (yDisp) to read the correct buffer lines
            let lineIndex = row + bufferOffset
            guard lineIndex >= 0, lineIndex < displayBuffer.lines.count else {
                for col in 0..<cols {
                    cells[row * cols + col] = CellData()
                }
                continue
            }
            let line = displayBuffer.lines[lineIndex]
            let selRange = terminalView?.selectedColumnsRange(row: lineIndex, cols: cols)

            for col in 0..<cols {
                let idx = row * cols + col
                let ch = line[col]

                var cell = CellData()

                // Wide character spacer cell (second cell of a 2-wide char): skip glyph
                if ch.width == 0 {
                    cell.glyphIndex = 0
                } else {
                    // Resolve glyph
                    let codePoint = UInt32(ch.code > 0 ? ch.code : 32) // space for empty cells
                    let style = glyphStyle(from: ch.attribute.style)
                    cell.glyphIndex = getOrCreateGlyphIndex(codePoint: codePoint, style: style)
                }

                // Resolve colors
                let (fgR, fgG, fgB) = resolveColor(ch.attribute.fg, isFg: true, terminal: terminal)
                let (bgR, bgG, bgB) = resolveColor(ch.attribute.bg, isFg: false, terminal: terminal)

                // Handle inverse
                let isInverse = ch.attribute.style.contains(CharacterStyle.inverse)
                if isInverse {
                    cell.fgR = bgR; cell.fgG = bgG; cell.fgB = bgB; cell.fgA = 255
                    cell.bgR = fgR; cell.bgG = fgG; cell.bgB = fgB; cell.bgA = 255
                } else {
                    cell.fgR = fgR; cell.fgG = fgG; cell.fgB = fgB; cell.fgA = 255
                    cell.bgR = bgR; cell.bgG = bgG; cell.bgB = bgB; cell.bgA = 255
                }

                // Apply dim/faint (reduce foreground brightness to ~2/3)
                if ch.attribute.style.contains(.dim) {
                    cell.fgR = UInt8(UInt16(cell.fgR) * 2 / 3)
                    cell.fgG = UInt8(UInt16(cell.fgG) * 2 / 3)
                    cell.fgB = UInt8(UInt16(cell.fgB) * 2 / 3)
                }

                // Selection overlay: apply selection background color
                if let range = selRange, range.contains(col) {
                    cell.bgR = selR; cell.bgG = selG; cell.bgB = selB; cell.bgA = 255
                }

                // Block cursor: invert fg/bg at cursor position
                if showCursor && row == cursorScreenRow && col == cursorCol {
                    if cursorStyle == .blinkBlock || cursorStyle == .steadyBlock {
                        let tmpR = cell.fgR, tmpG = cell.fgG, tmpB = cell.fgB, tmpA = cell.fgA
                        cell.fgR = cell.bgR; cell.fgG = cell.bgG; cell.fgB = cell.bgB; cell.fgA = cell.bgA
                        cell.bgR = tmpR; cell.bgG = tmpG; cell.bgB = tmpB; cell.bgA = tmpA
                    }
                }

                // Pack style flags
                var flags: UInt16 = 0
                if ch.attribute.style.contains(CharacterStyle.bold)      { flags |= 1 << 0 }
                if ch.attribute.style.contains(CharacterStyle.italic)    { flags |= 1 << 1 }
                if ch.attribute.style.contains(CharacterStyle.underline) { flags |= 1 << 2 }
                if ch.attribute.style.contains(CharacterStyle.crossedOut){ flags |= 1 << 3 }
                if ch.attribute.style.contains(CharacterStyle.inverse)   { flags |= 1 << 4 }
                if ch.attribute.style.contains(CharacterStyle.blink)     { flags |= 1 << 5 }

                // Cursor: set bar/underline decoration flags
                if showCursor && row == cursorScreenRow && col == cursorCol {
                    switch cursorStyle {
                    case .blinkBar, .steadyBar:
                        flags |= 1 << 6
                    case .blinkUnderline, .steadyUnderline:
                        flags |= 1 << 7
                    default:
                        break
                    }
                }

                cell.flags = flags

                cells[idx] = cell
            }
        }
    }

    // MARK: - Color Resolution

    /// Resolves an `Attribute.Color` to RGB uint8 values.
    private func resolveColor(_ color: Attribute.Color, isFg: Bool, terminal: Terminal) -> (UInt8, UInt8, UInt8) {
        switch color {
        case .defaultColor:
            let c = isFg ? terminal.foregroundColor : terminal.backgroundColor
            return (UInt8(c.red >> 8), UInt8(c.green >> 8), UInt8(c.blue >> 8))
        case .defaultInvertedColor:
            let c = isFg ? terminal.backgroundColor : terminal.foregroundColor
            return (UInt8(c.red >> 8), UInt8(c.green >> 8), UInt8(c.blue >> 8))
        case .ansi256(let code):
            let c = terminal.ansiColors[Int(code)]
            return (UInt8(c.red >> 8), UInt8(c.green >> 8), UInt8(c.blue >> 8))
        case .trueColor(let r, let g, let b):
            return (r, g, b)
        }
    }

    // MARK: - Image Collection

    /// Scans visible buffer lines for attached images and builds GPU-ready image quads.
    private func collectImageQuads(displayBuffer: Buffer, rows: Int, bufferOffset: Int, backingScale: CGFloat) {
        pendingImageQuads.removeAll()
        var referencedImages = Set<ObjectIdentifier>()
        let scale = Float(backingScale)

        for row in 0..<rows {
            let lineIndex = row + bufferOffset
            guard lineIndex >= 0, lineIndex < displayBuffer.lines.count else { continue }
            let line = displayBuffer.lines[lineIndex]
            guard let images = line.images else { continue }

            for img in images {
                guard let texture = getOrCreateTexture(for: img) else { continue }
                let oid = ObjectIdentifier(img as AnyObject)
                referencedImages.insert(oid)

                let quad = ImageQuadData(
                    position: SIMD2<Float>(Float(img.col) * Float(cellDims.width) * scale,
                                           Float(row) * Float(cellDims.height) * scale),
                    size: SIMD2<Float>(Float(img.pixelWidth), Float(img.pixelHeight))
                )
                pendingImageQuads.append((quad: quad, texture: texture))
            }
        }

        // Evict textures for images no longer visible
        let cachedKeys = Array(imageTextureCache.keys)
        for key in cachedKeys where !referencedImages.contains(key) {
            imageTextureCache.removeValue(forKey: key)
        }
    }

    /// Returns a cached MTLTexture for the given image, creating one on cache miss.
    private func getOrCreateTexture(for image: TerminalImage) -> MTLTexture? {
        let oid = ObjectIdentifier(image as AnyObject)
        if let cached = imageTextureCache[oid] {
            return cached
        }

        guard let appleImage = image as? TerminalView.AppleImage else { return nil }
        guard let cgImage = appleImage.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        // Render the CGImage into RGBA8 pixel data
        let bytesPerRow = 4 * width
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixelData,
            bytesPerRow: bytesPerRow
        )

        imageTextureCache[oid] = texture
        return texture
    }

    // MARK: - Glyph Management

    /// Maps a `CharacterStyle` to a `GlyphStyle` for atlas lookup.
    private func glyphStyle(from style: CharacterStyle) -> GlyphStyle {
        let isBold = style.contains(.bold)
        let isItalic = style.contains(.italic)
        if isBold && isItalic { return .boldItalic }
        if isBold { return .bold }
        if isItalic { return .italic }
        return .normal
    }

    /// Returns the GPU glyph index for the given code point and style,
    /// rasterizing into the atlas on cache miss.
    /// Box drawing (U+2500–U+257F) and block elements (U+2580–U+259F)
    /// are rendered through the glyph atlas via CoreText like normal glyphs.
    private func getOrCreateGlyphIndex(codePoint: UInt32, style: GlyphStyle) -> UInt16 {
        // Space or control characters → index 0 (empty glyph)
        if codePoint <= 32 { return 0 }

        let key = GlyphKey(codePoint: codePoint, style: style)
        if let existing = glyphIndexMap[key] {
            return existing
        }

        guard let atlas = glyphAtlas,
              let info = atlas.getOrCreate(codePoint: codePoint, style: style) else {
            return 0
        }

        let index = UInt16(glyphEntries.count)
        let entry = GlyphEntryData(
            uvRect: SIMD4<Float>(info.u0, info.v0, info.u1, info.v1),
            bearing: SIMD2<Float>(info.bearingX, info.bearingY),
            size: SIMD2<Float>(Float(info.width), Float(info.height))
        )
        glyphEntries.append(entry)
        glyphIndexMap[key] = index
        glyphBufferDirty = true

        return index
    }

    // MARK: - Buffer Updates

    private func updateUniforms(backingScale: Float) {
        var uniforms = Uniforms()
        uniforms.viewportSize = SIMD2<Float>(Float(viewportSize.width), Float(viewportSize.height))
        uniforms.cellSize = SIMD2<Float>(Float(cellDims.width) * backingScale, Float(cellDims.height) * backingScale)
        uniforms.atlasSize = SIMD2<Float>(Float(GlyphAtlas.atlasSize), Float(GlyphAtlas.atlasSize))
        uniforms.cols = UInt32(cols)
        uniforms.rows = UInt32(rows)
        uniforms.time = Float(CACurrentMediaTime())
        uniforms.blinkOn = blinkOn ? 1 : 0
        uniforms.scrollY = 0   // Cell buffer already reads correct lines via bufferOffset (yDisp)
        uniforms.backingScale = backingScale

        let ptr = uniformBuffer.contents().bindMemory(to: Uniforms.self, capacity: 1)
        ptr.pointee = uniforms
    }

    private func updateGlyphEntryBuffer() {
        let size = glyphEntries.count * MemoryLayout<GlyphEntryData>.stride
        guard size > 0 else { return }

        glyphEntryBuffer = device.makeBuffer(
            bytes: &glyphEntries,
            length: size,
            options: .storageModeShared
        )
        glyphBufferDirty = false
    }

    // MARK: - Rendering

    private func renderFrame() {
        guard let layer = metalLayer,
              let drawable = layer.nextDrawable(),
              let cellBuf = cellBuffer,
              let glyphBuf = glyphEntryBuffer else {
            return
        }

        let cellCount = cols * rows
        guard cellCount > 0 else { return }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }

        // Background pass
        encoder.setRenderPipelineState(bgPipelineState)
        encoder.setVertexBuffer(cellBuf, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: cellCount)

        // Text pass
        encoder.setRenderPipelineState(textPipelineState)
        encoder.setVertexBuffer(cellBuf, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setVertexBuffer(glyphBuf, offset: 0, index: 2)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)
        if let atlasTexture = glyphAtlas?.atlasTexture {
            encoder.setFragmentTexture(atlasTexture, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: cellCount)

        // Decoration pass (underline, strikethrough)
        encoder.setRenderPipelineState(decoPipelineState)
        encoder.setVertexBuffer(cellBuf, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: cellCount)

        // Image pass (Sixel/Kitty images as textured quads)
        if !pendingImageQuads.isEmpty {
            encoder.setRenderPipelineState(imagePipelineState)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            for entry in pendingImageQuads {
                var quad = entry.quad
                guard let quadBuffer = device.makeBuffer(bytes: &quad, length: MemoryLayout<ImageQuadData>.stride, options: .storageModeShared) else { continue }
                encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
                encoder.setFragmentTexture(entry.texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Embedded Shader Source

    /// Metal shader source compiled at runtime for SPM compatibility.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    // Flag bits (must match Swift CellData.flags packing)
    constant uint BLINK_BIT = (1u << 5);

    struct CellData {
        uint16_t glyphIndex;
        uint8_t  fgR, fgG, fgB, fgA;
        uint8_t  bgR, bgG, bgB, bgA;
        uint16_t flags;
        uint16_t padding;
    };

    struct Uniforms {
        float2 viewportSize;
        float2 cellSize;
        float2 atlasSize;
        uint32_t cols;
        uint32_t rows;
        float time;
        uint32_t blinkOn;
        float scrollY;
        float backingScale;
        float _pad;
    };

    struct GlyphEntry {
        float4 uvRect;
        float2 bearing;
        float2 size;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
        float4 fgColor;
        float4 bgColor;
        uint flags [[flat]];
    };

    // ---- Background Pass ----

    vertex VertexOut bgVertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant CellData* cells [[buffer(0)]],
        constant Uniforms& uniforms [[buffer(1)]]
    ) {
        uint col = instanceID % uniforms.cols;
        uint row = instanceID / uniforms.cols;

        float2 positions[6] = {
            {0, 0}, {1, 0}, {0, 1},
            {1, 0}, {1, 1}, {0, 1}
        };

        float2 pos = positions[vertexID];
        float2 cellOrigin = floor(float2(col, row) * uniforms.cellSize);
        cellOrigin.y -= uniforms.scrollY;
        float2 pixelPos = cellOrigin + pos * uniforms.cellSize;

        float2 clipPos = (pixelPos / uniforms.viewportSize) * 2.0 - 1.0;
        clipPos.y = -clipPos.y;

        CellData cell = cells[instanceID];
        float4 bg = float4(cell.bgR, cell.bgG, cell.bgB, cell.bgA) / 255.0;

        VertexOut out;
        out.position = float4(clipPos, 0.0, 1.0);
        out.bgColor = bg;
        out.texCoord = float2(0);
        out.fgColor = float4(0);
        out.flags = 0;
        return out;
    }

    fragment float4 bgFragment(VertexOut in [[stage_in]]) {
        return in.bgColor;
    }

    // ---- Text Pass ----

    vertex VertexOut textVertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant CellData* cells [[buffer(0)]],
        constant Uniforms& uniforms [[buffer(1)]],
        constant GlyphEntry* glyphs [[buffer(2)]]
    ) {
        uint col = instanceID % uniforms.cols;
        uint row = instanceID / uniforms.cols;

        CellData cell = cells[instanceID];
        GlyphEntry glyph = glyphs[cell.glyphIndex];

        float2 positions[6] = {
            {0, 0}, {1, 0}, {0, 1},
            {1, 0}, {1, 1}, {0, 1}
        };
        float2 texCoords[6] = {
            {glyph.uvRect.x, glyph.uvRect.y},
            {glyph.uvRect.z, glyph.uvRect.y},
            {glyph.uvRect.x, glyph.uvRect.w},
            {glyph.uvRect.z, glyph.uvRect.y},
            {glyph.uvRect.z, glyph.uvRect.w},
            {glyph.uvRect.x, glyph.uvRect.w}
        };

        float2 pos = positions[vertexID];
        // Snap cell origin to integer pixel boundary
        float2 cellOrigin = floor(float2(col, row) * uniforms.cellSize);
        cellOrigin.y -= uniforms.scrollY;
        // Atlas is rasterized at backing resolution; glyph sizes are in backing pixels
        float2 glyphOrigin = cellOrigin;
        float2 pixelPos = glyphOrigin + pos * glyph.size;

        float2 clipPos = (pixelPos / uniforms.viewportSize) * 2.0 - 1.0;
        clipPos.y = -clipPos.y;

        float4 fg = float4(cell.fgR, cell.fgG, cell.fgB, cell.fgA) / 255.0;

        VertexOut out;
        out.position = float4(clipPos, 0.0, 1.0);
        out.texCoord = texCoords[vertexID];
        out.fgColor = fg;
        out.bgColor = float4(0);
        out.flags = cell.flags;
        return out;
    }

    fragment float4 textFragment(
        VertexOut in [[stage_in]],
        texture2d<float> atlas [[texture(0)]],
        constant Uniforms& uniforms [[buffer(1)]]
    ) {
        // Blink: hide glyph when blink flag is set and blink phase is off
        if ((in.flags & BLINK_BIT) != 0 && uniforms.blinkOn == 0) {
            discard_fragment();
        }

        constexpr sampler s(filter::nearest);
        float alpha = atlas.sample(s, in.texCoord).r;

        // Binary threshold: AA gives full glyph shape, step makes edges crisp
        alpha = step(0.35, alpha);
        if (alpha < 0.01) discard_fragment();

        return float4(in.fgColor.rgb, in.fgColor.a * alpha);
    }

    // ---- Decoration Pass (underline, strikethrough) ----

    vertex VertexOut decoVertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant CellData* cells [[buffer(0)]],
        constant Uniforms& uniforms [[buffer(1)]]
    ) {
        uint col = instanceID % uniforms.cols;
        uint row = instanceID / uniforms.cols;

        float2 positions[6] = {
            {0, 0}, {1, 0}, {0, 1},
            {1, 0}, {1, 1}, {0, 1}
        };

        float2 pos = positions[vertexID];
        float2 cellOrigin = floor(float2(col, row) * uniforms.cellSize);
        cellOrigin.y -= uniforms.scrollY;
        float2 pixelPos = cellOrigin + pos * uniforms.cellSize;

        float2 clipPos = (pixelPos / uniforms.viewportSize) * 2.0 - 1.0;
        clipPos.y = -clipPos.y;

        CellData cell = cells[instanceID];
        float4 fg = float4(cell.fgR, cell.fgG, cell.fgB, cell.fgA) / 255.0;

        VertexOut out;
        out.position = float4(clipPos, 0.0, 1.0);
        out.texCoord = pos;  // cell-local position (0..1)
        out.fgColor = fg;
        out.bgColor = float4(0);
        out.flags = cell.flags;
        return out;
    }

    fragment float4 decoFragment(
        VertexOut in [[stage_in]],
        constant Uniforms& uniforms [[buffer(0)]]
    ) {
        uint flags = in.flags;
        bool hasUnderline = (flags & (1u << 2)) != 0;
        bool hasStrikethrough = (flags & (1u << 3)) != 0;
        bool hasCursorDeco = (flags & ((1u << 6) | (1u << 7))) != 0;

        if (!hasUnderline && !hasStrikethrough && !hasCursorDeco) discard_fragment();

        float y = in.texCoord.y;
        float pixelH = 1.0 / uniforms.cellSize.y;

        bool draw = false;

        // Underline: 1px line 3 pixels from bottom of cell
        if (hasUnderline) {
            float underlineY = 1.0 - 3.0 * pixelH;
            if (y >= underlineY && y < underlineY + pixelH) draw = true;
        }

        // Strikethrough: 1px line at vertical center
        if (hasStrikethrough) {
            float strikeY = 0.5 - 0.5 * pixelH;
            if (y >= strikeY && y < strikeY + pixelH) draw = true;
        }

        // Cursor bar: 2px vertical line on left side of cell
        bool hasCursorBar = (flags & (1u << 6)) != 0;
        if (hasCursorBar) {
            float pixelW = 1.0 / uniforms.cellSize.x;
            if (in.texCoord.x < 2.0 * pixelW) draw = true;
        }

        // Cursor underline: 2px horizontal line at bottom of cell
        bool hasCursorUline = (flags & (1u << 7)) != 0;
        if (hasCursorUline) {
            if (y >= 1.0 - 2.0 * pixelH) draw = true;
        }

        if (!draw) discard_fragment();

        return in.fgColor;
    }

    // ---- Image Pass (Sixel/Kitty textured quads) ----

    struct ImageQuad {
        float2 position;  // top-left in pixels
        float2 size;      // width, height in pixels
    };

    struct ImageVertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    vertex ImageVertexOut imageVertex(
        uint vertexID [[vertex_id]],
        constant ImageQuad& quad [[buffer(0)]],
        constant Uniforms& uniforms [[buffer(1)]]
    ) {
        float2 positions[6] = {
            {0, 0}, {1, 0}, {0, 1},
            {1, 0}, {1, 1}, {0, 1}
        };
        float2 uvs[6] = {
            {0, 0}, {1, 0}, {0, 1},
            {1, 0}, {1, 1}, {0, 1}
        };

        float2 pos = positions[vertexID];
        float2 pixelPos = quad.position + pos * quad.size;

        float2 clipPos = (pixelPos / uniforms.viewportSize) * 2.0 - 1.0;
        clipPos.y = -clipPos.y;

        ImageVertexOut out;
        out.position = float4(clipPos, 0.0, 1.0);
        out.texCoord = uvs[vertexID];
        return out;
    }

    fragment float4 imageFragment(
        ImageVertexOut in [[stage_in]],
        texture2d<float> imageTexture [[texture(0)]]
    ) {
        constexpr sampler s(filter::linear);
        return imageTexture.sample(s, in.texCoord);
    }
    """
}
#endif
