//
//  MetalTerminalRenderer.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 8/10/25.
//
#if os(iOS) || os(macOS) || os(visionOS)
import CoreGraphics
import Metal

import Metal
import MetalKit
import simd
import SwiftUI

extension CGColor {
    /// Turns a CGColor into an RGBA value
    func toRGBASIMD() -> SIMD4<Float> {
        guard let components = self.components else {
            return SIMD4<Float>(0, 0, 0, 1)
        }
        
        switch components.count {
        case 2: // Grayscale + Alpha
            return SIMD4<Float>(Float(components[0]), Float(components[0]), Float(components[0]), Float(components[1]))
        case 3: // RGB (no alpha)
            return SIMD4<Float>(Float(components[0]), Float(components[1]), Float(components[2]), 1.0)
        case 4: // RGBA
            return SIMD4<Float>(Float(components[0]), Float(components[1]), Float(components[2]), Float(components[3]))
        default: // Fallback
            return SIMD4<Float>(0, 0, 0, 1)
        }
    }
}
@objc
class MetalTerminalRenderer: NSObject, MTKViewDelegate, TerminalRenderer {
    var view: TerminalView?
    let mtkView = MTKView()
    var device: MTLDevice?
    var commandQueue: MTLCommandQueue?
    var pipelineState: MTLRenderPipelineState?
    var instanceBuffer: MTLBuffer?
    var instanceCount: Int = 0
    var textureAtlas: TextureAtlas?
    var charWidth: Float = 0.03
    var charHeight: Float = 0.05
    var lineHeight: Float = 1.2
    var currentViewSize: CGSize = .zero
    var currentFontName: String = "Menlo"

    init?(view: TerminalView) {
        self.view = view
        mtkView.bounds = view.bounds
        super.init()
        
        guard setupMetal() else {
            return nil
        }
        mtkView.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        mtkView.delegate = self
        mtkView.isPaused = false
        mtkView.preferredFramesPerSecond = 60
        view.addSubview(mtkView)
    }
    
    func setupMetal() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return false
        }
        self.device = device
        mtkView.device = device
        guard let commandQueue = device.makeCommandQueue() else {
            print("MetalTerminalRenderer: Failed to create command queue")
            return false
        }
        self.commandQueue = commandQueue

        textureAtlas = TextureAtlas(device: device, fontSize: 15, fontName: currentFontName)

        charWidth = Float(textureAtlas?.charSizeInPoints.width ?? 0)
        charHeight = Float(textureAtlas?.charSizeInPoints.height ?? 0)

        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.module) else {
            print("MetalTerminalRenderer: Failed to create library")
            return false
        }

        guard let vertexFunction = library.makeFunction(name: "textVertexShader"),
            let fragmentFunction = library.makeFunction(name: "textFragmentShader") else {
            print("MetalTerminalRenderer: Failed to create shader functions")
            return false
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("MetalTerminalRenderer: Failed to create pipeline state: \(error)")
            return false
        }

        currentViewSize = CGSize(width: 800, height: 600)
        createTextMesh()
        return true
    }
    
    func createTextMesh() {
        var instanceData: [MetalTerminalRenderer.InstanceData] = []

        let scaleFactor = Float(NSScreen.main?.backingScaleFactor ?? 2.0)

        let scaledCharWidth = charWidth * scaleFactor
        let scaledCharHeight = charHeight * scaleFactor


        guard let terminalView = view,
              let terminal = terminalView.terminal
        else { return }

        //        let ndcCharWidth = (scaledCharWidth / Float(currentViewSize.width)) * 2.0
        //        let ndcCharHeight = (scaledCharHeight / Float(currentViewSize.height)) * 2.0
        //        let ndcLineHeight = ndcCharHeight * lineHeight
        let ndcCharWidth = Float(terminalView.cellDimension.width)
        let ndcCharHeight = Float(terminalView.cellDimension.height)
        let ndcLineHeight = ndcCharHeight * lineHeight
        
        // TODO: this is a proof of concept using cells, needs to be changed to use CoreText runs,
        // TODO: needs iOS support, this is hardcoding the region for what is suitable on the Mac
        //       TODO/2 (Mac does row-based rendering iOS can be smooth scrolled)
        
        // On Mac, we are drawing the terminal buffer
        let cellHeight = terminalView.cellDimension.height
        let boundsMaxY = terminalView.bounds.maxY
        let firstRow = terminal.buffer.yDisp+Int (terminalView.bounds.minY/cellHeight)
        let lastRow = terminal.buffer.yDisp+Int(boundsMaxY/cellHeight)
        
        for row in firstRow...lastRow {
            if row < 0 {
                continue
            }
            if row >= terminal.buffer.lines.count {
                continue
            }
            // TODO: handle render mode (double width/double height)
            let line = terminal.buffer.lines [row]
            
            for col in 0..<line.count {
                let ndcX = -1.0 + Float(col) * ndcCharWidth
                let ndcY = Float(row) * ndcLineHeight - ndcCharHeight
                
                // Quick hack
                let charData = line[col]
                let character = charData.getCharacter()
                let isEmoji = character.unicodeScalars.first.map { $0.value > 127 && $0.properties.isEmoji } ?? false
                
                // TODO: this is a quick hack to get the color, the reality is more complicated, see terminalView.getAttributes
                let colors = terminalView.getColors(charData.attribute)
                let colorFg = terminalView.mapColor(color: colors.fg, isFg: true, isBold: false)
                let colorBg = terminalView.mapColor(color: colors.bg, isFg: false, isBold: false)
                
                let texCoords = textureAtlas?.getTexCoords(for: character) ?? (0, 0, 0, 0)
                
                print("Instance \(row):\(col) at \(ndcX),\(ndcY)")
                let instance = InstanceData(
                    position: SIMD2<Float>(ndcX, ndcY),
                    _padding0: 0,
                    useDirectColor: isEmoji ? 1 : 0,
                    texCoords: SIMD4<Float>(texCoords.0, texCoords.1, texCoords.2, texCoords.3),
                    //                    foregroundColor: colorFg.cgColor.toRGBASIMD(),
                    //                    backgroundColor: colorBg.cgColor.toRGBASIMD())
                    foregroundColor: SIMD4<Float>(0, 0, 1, 1),
                    backgroundColor: SIMD4<Float>(0, 0, 0, 1))
                instanceData.append(instance)
                
            }
        }
        
        instanceCount = instanceData.count
        guard instanceCount > 0 else {
            print("Nothing to draw")
            return
        }
        instanceBuffer = device?.makeBuffer(bytes: instanceData, length: instanceData.count * MemoryLayout<MetalTerminalRenderer.InstanceData>.size, options: [])
    }

    
    func drawTerminalContents(dirtyRect: TTRect, bufferOffset: Int) {
        //fatalError()
    }
    
    func fontChanged() {
        guard let view else { return }
        // TODO, we already have the various fonts we need, we should use those, instead of loading new ones
        // and we should wire up here the fonts so we can use the bold italic, etc:
        // OLD: updateFont(fontName: view.font, fontSize: CGFloat(fontSize))
    }
    
    func sizeChanged(newSize: CGSize) {
        mtkView.frame = CGRect(origin: mtkView.frame.origin, size: newSize)
    }
    
    func cleanup() {
        fatalError()
    }
    
    func setBackgroundColor(_ color: CGColor) {
        // TODO: turn that into the clearColor:
        mtkView.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
    }
    
    // periphery:ignore
    struct InstanceData {
        var position: SIMD2<Float>
        var _padding0: UInt32 = 0
        var useDirectColor: UInt32 = 0
        var texCoords: SIMD4<Float>
        var foregroundColor: SIMD4<Float>
        var backgroundColor: SIMD4<Float>
    }

//    func updateFont(fontName: String, fontSize: CGFloat) {
//        currentFontName = fontName
//        textureAtlas?.regenerate(with: fontSize, fontName: fontName)
//
//        charWidth = Float(textureAtlas?.charSizeInPoints.width ?? 0)
//        charHeight = Float(textureAtlas?.charSizeInPoints.height ?? 0)
//
//        if currentViewSize.width > 0 && currentViewSize.height > 0 {
//            let pixelLineHeight = charHeight * lineHeight
//            let termWidth = Int(Float(currentViewSize.width) / charWidth)
//            let termHeight = Int(Float(currentViewSize.height) / pixelLineHeight)
//
//            if termWidth != terminal.width || termHeight != terminal.height {
//                terminal.resize(width: termWidth, height: termHeight)
//            }
//
//            createTextMesh()
//        }
//    }
  
    func mtkView(_: MTKView, drawableSizeWillChange size: CGSize) {
        // TODO: I am already handling this in SwiftTerm's view, but maybe we need to do it here to meet the metal protocol requirements?
        
//        guard size.width > 0 && size.height > 0 else {
//            return
//        }
//
//        currentViewSize = size
//
//        let charWidthInPoints = Float(textureAtlas?.charSizeInPoints.width ?? 0)
//        let charHeightInPoints = Float(textureAtlas?.charSizeInPoints.height ?? 0)
//        let lineHeightInPoints = charHeightInPoints * lineHeight
//
//        charWidth = charWidthInPoints
//        charHeight = charHeightInPoints
//
//        let termWidth = Int(Float(size.width) / charWidthInPoints)
//        let termHeight = Int(Float(size.height) / lineHeightInPoints)
//
//        guard let terminalView = view as? TerminalView, let terminal = terminalView.getTerminal() else {
//            return
//        }
//        if termWidth != terminal.cols || termHeight != terminal.rows {
//            terminal.resize(width: termWidth, height: termHeight)
//            createTextMesh()
//        }
    }

    func draw(in view: MTKView) {
        createTextMesh()

        guard let drawable = view.currentDrawable,
            let renderPassDescriptor = view.currentRenderPassDescriptor,
            let commandQueue,
            let pipelineState else {
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        if let instanceBuffer {
            renderEncoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        }

        let ndcCharWidth = (charWidth * Float(NSScreen.main?.backingScaleFactor ?? 2.0) / Float(currentViewSize.width)) * 2.0
        let ndcCharHeight = (charHeight * Float(NSScreen.main?.backingScaleFactor ?? 2.0) / Float(currentViewSize.height)) * 2.0
        var charSize = SIMD2<Float>(ndcCharWidth, ndcCharHeight)
        renderEncoder.setVertexBytes(&charSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)

        var screenSize = SIMD2<Float>(Float(currentViewSize.width), Float(currentViewSize.height))
        renderEncoder.setVertexBytes(&screenSize, length: MemoryLayout<SIMD2<Float>>.size, index: 2)

        if let texture = textureAtlas?.texture {
            renderEncoder.setFragmentTexture(texture, index: 0)
        }

        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instanceCount)

        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

#endif
