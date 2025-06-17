//
//  MetalTerminalRenderer.swift
//
// Metal-based terminal renderer for high-performance text rendering
// Based on concepts from the Microsoft's Terminal AtlasEngine optimized renderer
//
//

#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import Metal
import MetalKit
import CoreGraphics
import CoreText

#if os(iOS) || os(visionOS)
import UIKit
#endif

#if os(macOS)
import AppKit
#endif

/// Metal-based terminal renderer for high-performance rendering
/// Ported from AtlasEngine's optimized D3D11 approach
class MetalTerminalRenderer: TerminalRenderer {
    weak var view: TerminalView?
    
    // Metal resources
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var metalLayer: CAMetalLayer?
    
    // Render pipelines
    private var instancedPipelineState: MTLRenderPipelineState?
    private var backgroundPipelineState: MTLRenderPipelineState?
    private var selectionPipelineState: MTLRenderPipelineState?
    
    // Buffers
    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var instanceBuffer: MTLBuffer?
    private var vsConstantBuffer: MTLBuffer?
    private var psConstantBuffer: MTLBuffer?
    
    // Glyph atlas (optimized implementation)
    private var glyphAtlas: MTLTexture?
    private var glyphAtlasSize: CGSize = CGSize(width: 2048, height: 2048)
    private var glyphAtlasMap: [GlyphKey: AtlasGlyphEntry] = [:]
    private var glyphAtlasRects: [CGRect] = []
    private var glyphAtlasAllocator: SimpleRectPacker?
    
    // Background color bitmap for efficient background rendering
    private var backgroundBitmap: MTLTexture?
    private var backgroundBitmapGeneration: UInt32 = 0
    
    // Optimized instance data structure (Metal-compatible)
    struct QuadInstance {
        var shadingType: Float
        var renditionScale: SIMD2<Float>
        var position: SIMD2<Float>
        var size: SIMD2<Float>
        var texcoord: SIMD2<Float>
        var color: SIMD4<Float>
    }
    
    // Glyph cache entry (based on AtlasEngine's AtlasGlyphEntry)
    struct AtlasGlyphEntry {
        var glyphIndex: UInt32
        var shadingType: UInt8
        var occupied: Bool
        var offset: SIMD2<Int16>
        var size: SIMD2<UInt16>
        var texcoord: SIMD2<UInt16>
    }
    
    // Glyph key for hashing
    struct GlyphKey: Hashable {
        let fontFace: UnsafeRawPointer
        let glyphIndex: UInt32
        let rendition: BufferLine.RenderLineMode
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(Int(bitPattern: fontFace))
            hasher.combine(glyphIndex)
            hasher.combine(rendition)
        }
    }
    
    // Shading types (based on AtlasEngine's ShadingType)
    enum ShadingType: UInt16 {
        case background = 0
        case textGrayscale = 1
        case textClearType = 2
        case textBuiltinGlyph = 3
        case textPassthrough = 4
        case cursor = 5
        case filledRect = 6
    }
    
    // Uniforms structure for vertex shader
    struct VSConstBuffer {
        var positionScale: SIMD2<Float>
        var padding: SIMD2<Float> = SIMD2<Float>(0, 0)  // Ensure 16-byte alignment
    }
    
    // Uniforms structure for pixel shader
    struct PSConstBuffer {
        var backgroundColor: SIMD4<Float>
        var backgroundCellSize: SIMD2<Float>
        var backgroundCellCount: SIMD2<Float>
        var enhancedContrast: Float
        var underlineWidth: Float
        var padding: SIMD2<Float> = SIMD2<Float>(0, 0)  // Ensure 16-byte alignment
    }
    
    // Instance buffer for batched rendering
    private var instances: [QuadInstance] = []
    private var instancesCount = 0
    private let maxInstances = 8192 * 6  // Support large terminals
    
    // Debug flag to clear cache once for CoreText testing
    private var didClearCacheForCoreText = false
    
    // Simple rect packer for glyph atlas allocation
    class SimpleRectPacker {
        private var width: Int
        private var height: Int
        private var currentY: Int = 0
        private var currentRowHeight: Int = 0
        private var currentX: Int = 0
        
        init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
        
        func allocate(width w: Int, height h: Int) -> CGRect? {
            // Simple row-based allocation
            if currentX + w > width {
                // Move to next row
                currentY += currentRowHeight
                currentX = 0
                currentRowHeight = h
                
                if currentY + h > height {
                    return nil  // Out of space
                }
            }
            
            let rect = CGRect(x: currentX, y: currentY, width: w, height: h)
            currentX += w
            currentRowHeight = max(currentRowHeight, h)
            
            return rect
        }
        
        func reset() {
            currentY = 0
            currentRowHeight = 0
            currentX = 0
        }
    }
    
    init(view: TerminalView) {
        self.view = view
        setupMetal()
    }
    
    static var isAvailable: Bool {
        return MTLCreateSystemDefaultDevice() != nil
    }
    
    var preferredForLargeBuffers: Bool {
        return true
    }
    
    func initialize(with view: TerminalView) {
        self.view = view
        setupMetal()
    }
    
    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("Metal is not available on this device")
            return
        }
        
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        
        setupMetalLayer()
        setupRenderPipelines()
        setupOptimizedBuffers()
        setupOptimizedGlyphAtlas()
        setupBackgroundBitmap()
    }
    
    private func setupMetalLayer() {
        guard let view = self.view, let device = self.device else { 
            return 
        }
        
        if let existingLayer = self.metalLayer {
            updateMetalLayerSize()
            return
        }
        
        let metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.contentsScale = view.backingScaleFactor()
        
        #if os(macOS)
        metalLayer.displaySyncEnabled = true
        view.wantsLayer = true
        view.layer = metalLayer
        #else
        view.layer.addSublayer(metalLayer)
        #endif
        
        self.metalLayer = metalLayer
        updateMetalLayerSize()
    }
    
    
    private func updateMetalLayerSize() {
        guard let view = self.view,
                let metalLayer = self.metalLayer
        else { return }
        
        let scale = view.backingScaleFactor()
        metalLayer.drawableSize = CGSize(
            width: view.bounds.width * scale,
            height: view.bounds.height * scale
        )
        metalLayer.frame = view.bounds
    }
    
    private func setupRenderPipelines() {
        guard let device = self.device else { return }
        
        guard let library = createOptimizedLibraryFromSource(device: device)
        else {
            print("Failed to create optimized Metal library")
            return
        }
        
        createInstancedPipeline(device: device, library: library)
        createBackgroundPipeline(device: device, library: library)
        createSelectionPipeline(device: device, library: library)
    }
    
    private func createInstancedPipeline(device: MTLDevice, library: MTLLibrary) {
        guard let vertexFunction = library.makeFunction(name: "instancedVertexShader"),
              let fragmentFunction = library.makeFunction(name: "instancedFragmentShader")
        else {
            print("Failed to find instanced shader functions")
            return
        }
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        
        // Create vertex descriptor for instanced rendering
        let vertexDescriptor = MTLVertexDescriptor()
        
        // Vertex buffer (buffer 0) - per-vertex data
        vertexDescriptor.attributes[0].format = .float2  // position
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        
        // Instance buffer (buffer 1) - per-instance data using Float types
        var offset = 0
        
        // shadingType (attribute 1)
        vertexDescriptor.attributes[1].format = .float
        vertexDescriptor.attributes[1].offset = offset
        vertexDescriptor.attributes[1].bufferIndex = 1
        offset += MemoryLayout<Float>.stride
        
        // renditionScale (attribute 2)
        vertexDescriptor.attributes[2].format = .float2
        vertexDescriptor.attributes[2].offset = offset
        vertexDescriptor.attributes[2].bufferIndex = 1
        offset += MemoryLayout<SIMD2<Float>>.stride
        
        // position (attribute 3)
        vertexDescriptor.attributes[3].format = .float2
        vertexDescriptor.attributes[3].offset = offset
        vertexDescriptor.attributes[3].bufferIndex = 1
        offset += MemoryLayout<SIMD2<Float>>.stride
        
        // size (attribute 4)
        vertexDescriptor.attributes[4].format = .float2
        vertexDescriptor.attributes[4].offset = offset
        vertexDescriptor.attributes[4].bufferIndex = 1
        offset += MemoryLayout<SIMD2<Float>>.stride
        
        // texcoord (attribute 5)
        vertexDescriptor.attributes[5].format = .float2
        vertexDescriptor.attributes[5].offset = offset
        vertexDescriptor.attributes[5].bufferIndex = 1
        offset += MemoryLayout<SIMD2<Float>>.stride
        
        // color (attribute 6)
        vertexDescriptor.attributes[6].format = .float4
        vertexDescriptor.attributes[6].offset = offset
        vertexDescriptor.attributes[6].bufferIndex = 1
        
        vertexDescriptor.layouts[1].stride = MemoryLayout<QuadInstance>.stride
        vertexDescriptor.layouts[1].stepFunction = .perInstance
        vertexDescriptor.layouts[1].stepRate = 1
        
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        
        do {
            instancedPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Failed to create instanced pipeline state: \(error)")
        }
    }
    
    private func createBackgroundPipeline(device: MTLDevice, library: MTLLibrary) {
        guard let vertexFunction = library.makeFunction(name: "backgroundVertexShader"),
              let fragmentFunction = library.makeFunction(name: "backgroundFragmentShader")
        else {
            return
        }
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        // Simple vertex descriptor for background
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        
        do {
            backgroundPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Failed to create background pipeline state: \(error)")
        }
    }
    
    private func createSelectionPipeline(device: MTLDevice, library: MTLLibrary) {
        guard let vertexFunction = library.makeFunction(name: "backgroundVertexShader"),
              let fragmentFunction = library.makeFunction(name: "selectionFragmentShader")
        else {
            return
        }
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        
        // Add vertex descriptor for selection pipeline (same as background)
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        
        do {
            selectionPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Failed to create selection pipeline state: \(error)")
        }
    }
    
    private func setupOptimizedBuffers() {
        guard let device = self.device else { return }
        
        // Create quad vertex buffer (4 vertices for a unit quad)
        let vertices: [SIMD2<Float>] = [
            SIMD2<Float>(0, 0),
            SIMD2<Float>(1, 0),
            SIMD2<Float>(1, 1),
            SIMD2<Float>(0, 1)
        ]
        vertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)
        
        // Create index buffer for quad (2 triangles)
        let indices: [UInt16] = [0, 1, 2, 2, 3, 0]
        indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt16>.stride, options: .storageModeShared)
        
        // Create instance buffer for instanced rendering
        instanceBuffer = device.makeBuffer(length: maxInstances * MemoryLayout<QuadInstance>.stride, options: .storageModeShared)
        
        // Create constant buffers
        vsConstantBuffer = device.makeBuffer(length: MemoryLayout<VSConstBuffer>.stride, options: .storageModeShared)
        psConstantBuffer = device.makeBuffer(length: MemoryLayout<PSConstBuffer>.stride, options: .storageModeShared)
        
        // Initialize instance array
        instances.reserveCapacity(maxInstances)
    }
    
    private func setupOptimizedGlyphAtlas() {
        guard let device = self.device else { return }
        
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(glyphAtlasSize.width),
            height: Int(glyphAtlasSize.height),
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .renderTarget]
        
        glyphAtlas = device.makeTexture(descriptor: textureDescriptor)
        glyphAtlasAllocator = SimpleRectPacker(width: Int(glyphAtlasSize.width), height: Int(glyphAtlasSize.height))
        
        // Clear the atlas
        clearGlyphAtlas()
    }
    
    private func setupBackgroundBitmap() {
        guard let device = self.device, let view = self.view
        else { return }
        
        let width = Int(view.terminal.cols)
        let height = Int(view.terminal.rows)
        
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        
        backgroundBitmap = device.makeTexture(descriptor: textureDescriptor)
    }
    
    private func clearGlyphAtlas() {
        guard let glyphAtlas = self.glyphAtlas,
              let commandQueue = self.commandQueue
        else { return }
        
        let commandBuffer = commandQueue.makeCommandBuffer()!
        
        // Create a render pass to clear the texture
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = glyphAtlas
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        
        renderEncoder.endEncoding()
        commandBuffer.commit()
    }
    
    private func createOptimizedLibraryFromSource(device: MTLDevice) -> MTLLibrary? {
        let metalSource = """
        #include <metal_stdlib>
        #include <simd/simd.h>
        
        using namespace metal;
        
        // Vertex shader constants
        struct VSConstBuffer {
            float2 positionScale;
            float2 padding;
        };
        
        // Pixel shader constants
        struct PSConstBuffer {
            float4 backgroundColor;
            float2 backgroundCellSize;
            float2 backgroundCellCount;
            float enhancedContrast;
            float underlineWidth;
            float2 padding;
        };
        
        // Instance data structure
        struct QuadInstance {
            float shadingType;
            float2 renditionScale;
            float2 position;
            float2 size;
            float2 texcoord;
            float4 color;
        };
        
        struct VertexIn {
            float2 position [[attribute(0)]];
        };
        
        struct VertexOut {
            float4 position [[position]];
            float4 color;
            float2 texcoord;
            float shadingType;
        };
        
        // Instanced vertex shader using buffer for instance data
        vertex VertexOut instancedVertexShader(
            VertexIn in [[stage_in]],
            uint instanceID [[instance_id]],
            constant VSConstBuffer& vsConstants [[buffer(2)]],
            constant QuadInstance* instances [[buffer(1)]]
        ) {
            VertexOut out;
            
            QuadInstance instance = instances[instanceID];
            
            // Calculate world position
            float2 worldPos = instance.position + in.position * instance.size;
            
            // Transform to NDC
            out.position.xy = worldPos * vsConstants.positionScale + float2(-1.0, 1.0);
            out.position.zw = float2(0, 1);
            
            // Pass through other attributes
            out.color = instance.color;
            // Calculate final texture coordinates within the glyph using renditionScale (normalized glyph size)
            out.texcoord = instance.texcoord + in.position * instance.renditionScale;
            out.shadingType = instance.shadingType;
            
            return out;
        }
        
        // Instanced fragment shader
        fragment float4 instancedFragmentShader(
            VertexOut in [[stage_in]],
            constant PSConstBuffer& psConstants [[buffer(0)]],
            texture2d<float> backgroundTexture [[texture(0)]],
            texture2d<float> glyphAtlas [[texture(1)]],
            sampler textureSampler [[sampler(0)]]
        ) {
            uint shadingType = uint(in.shadingType);
            
            switch (shadingType) {
                case 0: // Background
                {
                    float2 cell = in.position.xy / psConstants.backgroundCellSize;
                    if (all(cell < psConstants.backgroundCellCount)) {
                        return backgroundTexture.sample(textureSampler, cell / psConstants.backgroundCellCount);
                    } else {
                        return psConstants.backgroundColor;
                    }
                }
                
                case 1: // Text grayscale
                case 2: // Text ClearType
                {
                    float4 glyph = glyphAtlas.sample(textureSampler, in.texcoord);
                    
                    return float4(in.color.rgb * glyph.a, in.color.a * glyph.a);
                }
                
                case 6: // Filled rectangle (for backgrounds)
                {
                    return in.color;
                }
                
                default:
                    return in.color;
            }
        }
        
        // Simple background vertex shader
        struct BackgroundVertexIn {
            float2 position [[attribute(0)]];
        };
        
        vertex float4 backgroundVertexShader(
            BackgroundVertexIn in [[stage_in]],
            constant VSConstBuffer& vsConstants [[buffer(2)]]
        ) {
            float4 out_position;
            out_position.xy = in.position * vsConstants.positionScale + float2(-1.0, 1.0);
            out_position.zw = float2(0, 1);
            return out_position;
        }
        
        fragment float4 backgroundFragmentShader() {
            return float4(0, 0, 0, 1); // Default black background
        }
        
        fragment float4 selectionFragmentShader() {
            return float4(0.5, 0.5, 1.0, 0.3); // Semi-transparent blue selection
        }
        """
        
        do {
            let library = try device.makeLibrary(source: metalSource, options: nil)
            return library
        } catch {
            print("Failed to create optimized Metal library: \(error)")
            return nil
        }
    }
    
    // MARK: - Main rendering method
    
    func drawTerminalContents(dirtyRect: TTRect, bufferOffset: Int) {
        guard let view = self.view,
              let device = self.device,
              let commandQueue = self.commandQueue,
              let metalLayer = self.metalLayer,
              let drawable = metalLayer.nextDrawable(),
              let instancedPipelineState = self.instancedPipelineState
        else {
            return
        }
        
        updateConstantBuffers()
        buildInstances(dirtyRect: dirtyRect, bufferOffset: bufferOffset)
        
        let commandBuffer = commandQueue.makeCommandBuffer()!
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        
        // Render background first
        renderBackground(encoder: renderEncoder)
        
        // Render text using instanced drawing
        renderInstancedText(encoder: renderEncoder)
        
        // Render selection if active
        if view.selection.active {
            renderSelection(encoder: renderEncoder, dirtyRect: dirtyRect, bufferOffset: bufferOffset)
        }
        
        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    private func updateConstantBuffers() {
        guard let view = self.view,
              let vsConstantBuffer = self.vsConstantBuffer,
              let psConstantBuffer = self.psConstantBuffer
        else { return }
        
        let scale = view.backingScaleFactor()
        let width = Float(view.bounds.width * scale)
        let height = Float(view.bounds.height * scale)
        
        // Update vertex shader constants
        let vsConstants = VSConstBuffer(
            positionScale: SIMD2<Float>(2.0 / width, -2.0 / height)
        )
        
        let vsPointer = vsConstantBuffer.contents().bindMemory(to: VSConstBuffer.self, capacity: 1)
        vsPointer.pointee = vsConstants
        
        // Update pixel shader constants
        let bgColor = colorToSIMD4(view.nativeBackgroundColor)
        let cellSize = SIMD2<Float>(Float(view.cellDimension.width * scale), Float(view.cellDimension.height * scale))
        let cellCount = SIMD2<Float>(Float(view.terminal.cols), Float(view.terminal.rows))
        
        let psConstants = PSConstBuffer(
            backgroundColor: bgColor,
            backgroundCellSize: cellSize,
            backgroundCellCount: cellCount,
            enhancedContrast: 0.0,
            underlineWidth: 1.0
        )
        
        let psPointer = psConstantBuffer.contents().bindMemory(to: PSConstBuffer.self, capacity: 1)
        psPointer.pointee = psConstants
    }
    
    private func buildInstances(dirtyRect: TTRect, bufferOffset: Int) {
        guard let view = self.view else { return }
        
        instances.removeAll(keepingCapacity: true)
        instancesCount = 0
        
        let cellWidth = view.cellDimension.width
        let cellHeight = view.cellDimension.height
        let scale = view.backingScaleFactor()
        
        // Calculate row range - similar to CoreGraphics implementation
        let firstRow = max(0, Int(dirtyRect.minY / cellHeight))
        let lastRow = min(view.terminal.rows - 1, Int(dirtyRect.maxY / cellHeight))
        
        for row in firstRow...lastRow {
            // Use bufferOffset to get the correct line from the terminal buffer
            let bufferRow = row + bufferOffset
            guard bufferRow >= 0 && bufferRow < view.terminal.buffer.lines.count else { continue }
            
            let line = view.terminal.buffer.lines[bufferRow]
            let y = Float(row) * Float(cellHeight * scale)
            
            for col in 0..<view.terminal.cols {
                let ch = line[col]
                let x = Float(col) * Float(cellWidth * scale)
                
                // Always render background for every cell
                let bgColor = mapColorToSIMD4(ch.attribute.bg, isFg: false, view: view)
                let bgInstance = QuadInstance(
                    shadingType: Float(ShadingType.filledRect.rawValue),
                    renditionScale: SIMD2<Float>(1.0, 1.0),
                    position: SIMD2<Float>(x, y),
                    size: SIMD2<Float>(Float(cellWidth * scale), Float(cellHeight * scale)),
                    texcoord: SIMD2<Float>(0, 0),
                    color: bgColor
                )
                instances.append(bgInstance)
                instancesCount += 1
                
                // Only render text if there's a character to display
                if ch.code == 0 { continue }
                
                let character = ch.getCharacter()
                if character == " " { continue }
                
                // Calculate actual cell size including scale factor for atlas allocation
                let actualCellSize = CGSize(
                    width: cellWidth * scale,
                    height: cellHeight * scale
                )
                
                // But use base cell size for font rendering (font is already sized correctly)
                let baseCellSize = CGSize(width: cellWidth, height: cellHeight)
                
                let glyphEntry = getOrCreateGlyph(
                    character: String(character),
                    fontFace: view.fontSet.normal,
                    atlasCellSize: actualCellSize,
                    fontCellSize: baseCellSize
                )
                
                let fgColor = mapColorToSIMD4(ch.attribute.fg, isFg: true, view: view)
                
                // Clear cache once to test CoreText rendering
                if !didClearCacheForCoreText {
                    didClearCacheForCoreText = true
                    glyphAtlasMap.removeAll()
                    glyphAtlasAllocator?.reset()
                }
                
                let normalizedTexcoord = SIMD2<Float>(
                    Float(glyphEntry?.texcoord.x ?? 0) / Float(glyphAtlasSize.width),
                    Float(glyphEntry?.texcoord.y ?? 0) / Float(glyphAtlasSize.height)
                )
                
                // Store normalized glyph size in the renditionScale field for the shader
                let normalizedGlyphSize = SIMD2<Float>(
                    Float(glyphEntry?.size.x ?? UInt16(actualCellSize.width)) / Float(glyphAtlasSize.width),
                    Float(glyphEntry?.size.y ?? UInt16(actualCellSize.height)) / Float(glyphAtlasSize.height)
                )
                
                // Create text instance
                let instance = QuadInstance(
                    shadingType: Float(ShadingType.textGrayscale.rawValue),
                    renditionScale: normalizedGlyphSize, // Store glyph atlas size here
                    position: SIMD2<Float>(x, y),
                    size: SIMD2<Float>(Float(cellWidth * scale), Float(cellHeight * scale)),
                    texcoord: normalizedTexcoord,
                    color: fgColor
                )
                
                instances.append(instance)
                instancesCount += 1
                
                if instancesCount >= maxInstances {
                    break
                }
            }
            
            if instancesCount >= maxInstances {
                break
            }
        }
    }
    
    private func renderInstancedText(encoder: MTLRenderCommandEncoder) {
        guard let instancedPipelineState = self.instancedPipelineState,
              let vertexBuffer = self.vertexBuffer,
              let indexBuffer = self.indexBuffer,
              let instanceBuffer = self.instanceBuffer,
              let vsConstantBuffer = self.vsConstantBuffer,
              let psConstantBuffer = self.psConstantBuffer,
              let glyphAtlas = self.glyphAtlas,
              instancesCount > 0 else { return }
        
        // Upload instances to GPU
        let instancePointer = instanceBuffer.contents().bindMemory(to: QuadInstance.self, capacity: instancesCount)
        for (index, instance) in instances.enumerated() {
            instancePointer[index] = instance
        }
        
        encoder.setRenderPipelineState(instancedPipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
        encoder.setVertexBuffer(vsConstantBuffer, offset: 0, index: 2)
        encoder.setFragmentBuffer(psConstantBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(glyphAtlas, index: 1)
        
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        if let sampler = device?.makeSamplerState(descriptor: samplerDescriptor) {
            encoder.setFragmentSamplerState(sampler, index: 0)
        }
        
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: 6,
            indexType: .uint16,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0,
            instanceCount: instancesCount
        )
    }
    
    private func renderBackground(encoder: MTLRenderCommandEncoder) {
        // Background rendering implementation would go here
        // For now, we rely on the clear color
    }
    
    private func renderSelection(encoder: MTLRenderCommandEncoder, dirtyRect: TTRect, bufferOffset: Int) {
        // Selection rendering implementation would go here
    }
    
    private func getOrCreateGlyph(character: String, fontFace: TTFont, atlasCellSize: CGSize, fontCellSize: CGSize) -> AtlasGlyphEntry? {
        let glyphIndex = UInt32(character.unicodeScalars.first?.value ?? 0)
        let key = GlyphKey(
            fontFace: Unmanaged.passUnretained(fontFace).toOpaque(),
            glyphIndex: glyphIndex,
            rendition: .single
        )
        
        if let existingEntry = glyphAtlasMap[key] {
            return existingEntry
        }
        
        // Use scaled cell size for atlas allocation
        let glyphWidth = Int(atlasCellSize.width)
        let glyphHeight = Int(atlasCellSize.height)
        
        // Create new glyph entry
        guard let rect = glyphAtlasAllocator?.allocate(
            width: glyphWidth,
            height: glyphHeight
        ) else {
            print("Failed to allocate space in glyph atlas for character '\(character)'")
            return nil
        }
        
        let entry = AtlasGlyphEntry(
            glyphIndex: glyphIndex,
            shadingType: UInt8(ShadingType.textGrayscale.rawValue),
            occupied: true,
            offset: SIMD2<Int16>(0, 0),
            size: SIMD2<UInt16>(UInt16(glyphWidth), UInt16(glyphHeight)),
            texcoord: SIMD2<UInt16>(UInt16(rect.minX), UInt16(rect.minY))
        )
        
        glyphAtlasMap[key] = entry
        
        // Render glyph to atlas using the base font size, but scaled up to fill the atlas rect
        renderGlyphToAtlas(character: character, font: fontFace, rect: rect, fontCellSize: fontCellSize)
        
        return entry
    }
    
    private func renderGlyphToAtlas(character: String, font: TTFont, rect: CGRect, fontCellSize: CGSize) {
        guard let glyphAtlas = self.glyphAtlas else { return }
        
        let width = Int(rect.width)
        let height = Int(rect.height)
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let dataSize = height * bytesPerRow
        
        // Create pixel buffer
        var pixelData = [UInt8](repeating: 0, count: dataSize)
        
        // Create Core Graphics context for glyph rendering
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            print("Failed to create CGContext for glyph rendering")
            return
        }
        
        // Set up the context for text rendering
        context.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0) // White text
        context.textMatrix = CGAffineTransform.identity
        
        // Use the base font size for rendering, which is already correctly sized for the cell
        // The font is sized for the base cell dimensions, not the scaled atlas rect
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        ]
        let attributedString = NSAttributedString(string: character, attributes: attributes)
        
        // Create CTLine
        let line = CTLineCreateWithAttributedString(attributedString)
        
        // Calculate scale factor to fit the base font into the atlas rect
        let scaleX = CGFloat(width) / fontCellSize.width
        let scaleY = CGFloat(height) / fontCellSize.height
        let scale = min(scaleX, scaleY)
        
        // Apply scaling transform to fill the atlas rect
        context.scaleBy(x: scale, y: scale)
        
        // Get glyph bounds to center it properly (in the scaled coordinate system)
        let lineBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        
        // Calculate position to center the glyph in the scaled rect
        let scaledWidth = CGFloat(width) / scale
        let scaledHeight = CGFloat(height) / scale
        let x = (scaledWidth - lineBounds.width) / 2.0 - lineBounds.minX
        let y = (scaledHeight - lineBounds.height) / 2.0 - lineBounds.minY
        
        // Set text position and draw
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
        
        // Convert from BGRA premultiplied to BGRA with alpha in the alpha channel
        for i in stride(from: 0, to: dataSize, by: 4) {
            let b = pixelData[i]
            let g = pixelData[i + 1] 
            let r = pixelData[i + 2]
            let a = pixelData[i + 3]
            
            // For text rendering, we want the alpha to represent the glyph shape
            // Convert from premultiplied alpha to straight alpha
            if a > 0 {
                let alpha = Float(a) / 255.0
                pixelData[i] = 255     // B - always white
                pixelData[i + 1] = 255 // G - always white  
                pixelData[i + 2] = 255 // R - always white
                pixelData[i + 3] = a   // A - keep original alpha (glyph shape)
            } else {
                pixelData[i] = 0       // B
                pixelData[i + 1] = 0   // G
                pixelData[i + 2] = 0   // R  
                pixelData[i + 3] = 0   // A - transparent background
            }
        }
        
        // Upload to atlas texture
        let region = MTLRegionMake2D(Int(rect.minX), Int(rect.minY), width, height)
        glyphAtlas.replace(region: region, mipmapLevel: 0, withBytes: pixelData, bytesPerRow: bytesPerRow)
    }
    
    private func dumpAtlasToPNG() {
        guard let glyphAtlas = self.glyphAtlas else { return }
        
        let width = glyphAtlas.width
        let height = glyphAtlas.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let dataSize = height * bytesPerRow
        
        var pixelData = [UInt8](repeating: 0, count: dataSize)
        
        // Read the texture data
        glyphAtlas.getBytes(
            &pixelData,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        
        // Create CGImage from the pixel data
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo),
              let cgImage = context.makeImage() else {
            print("Failed to create CGImage from atlas data")
            return
        }
        
        // Save to PNG
        let timestamp = Int(Date().timeIntervalSince1970)
        let url = URL(fileURLWithPath: "/tmp/glyph_atlas_\(timestamp).png")
        
        #if os(macOS)
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        if let tiffData = nsImage.tiffRepresentation,
           let bitmapRep = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: url)
            print("Saved glyph atlas to: \(url.path)")
        }
        #else
        let uiImage = UIImage(cgImage: cgImage)
        if let pngData = uiImage.pngData() {
            try? pngData.write(to: url)
            print("Saved glyph atlas to: \(url.path)")
        }
        #endif
    }
    
    // MARK: - Utility methods
    
    private func mapColorToSIMD4(_ color: Attribute.Color, isFg: Bool, view: TerminalView) -> SIMD4<Float> {
        let ttColor = view.mapColor(color: color, isFg: isFg, isBold: false)
        return SIMD4<Float>(
            Float(ttColor.redComponent),
            Float(ttColor.greenComponent),
            Float(ttColor.blueComponent),
            Float(ttColor.alphaComponent)
        )
    }
    
    private func colorToSIMD4(_ color: TTColor) -> SIMD4<Float> {
        return SIMD4<Float>(
            Float(color.redComponent),
            Float(color.greenComponent),
            Float(color.blueComponent),
            Float(color.alphaComponent)
        )
    }
    
    // MARK: - TerminalRenderer conformance
    
    func fontChanged() {
        glyphAtlasMap.removeAll()
        glyphAtlasAllocator?.reset()
        clearGlyphAtlas()
    }
    
    // Debug helper to force regeneration of all glyphs
    func clearGlyphCache() {
        glyphAtlasMap.removeAll()
        glyphAtlasAllocator?.reset()
        clearGlyphAtlas()
    }
    
    func colorsChanged() {
        // No special handling needed for optimized renderer
    }
    
    func sizeChanged(newSize: CGSize) {
        updateMetalLayerSize()
        setupBackgroundBitmap()
    }
    
    func cleanup() {
        metalLayer?.removeFromSuperlayer()
        view = nil
        device = nil
        commandQueue = nil
        metalLayer = nil
        instancedPipelineState = nil
        backgroundPipelineState = nil
        selectionPipelineState = nil
        vertexBuffer = nil
        indexBuffer = nil
        instanceBuffer = nil
        vsConstantBuffer = nil
        psConstantBuffer = nil
        glyphAtlas = nil
        backgroundBitmap = nil
        glyphAtlasMap.removeAll()
        instances.removeAll()
    }
}

// Extension for float4x4 matrix operations
extension float4x4 {
    init(_ m00: Float, _ m01: Float, _ m02: Float, _ m03: Float,
         _ m10: Float, _ m11: Float, _ m12: Float, _ m13: Float,
         _ m20: Float, _ m21: Float, _ m22: Float, _ m23: Float,
         _ m30: Float, _ m31: Float, _ m32: Float, _ m33: Float) {
        self.init()
        columns = (
            SIMD4<Float>(m00, m10, m20, m30),
            SIMD4<Float>(m01, m11, m21, m31),
            SIMD4<Float>(m02, m12, m22, m32),
            SIMD4<Float>(m03, m13, m23, m33)
        )
    }
}
#endif
