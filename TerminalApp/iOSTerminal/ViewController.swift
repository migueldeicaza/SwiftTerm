//
//  ViewController.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/19/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import UIKit
import SwiftTerm

class ViewController: UIViewController {
    var tv: TerminalView!
    var transparent: Bool = true
    
    func makeFrame (keyboardDelta: CGFloat) -> CGRect
    {
        CGRect (x: view.safeAreaInsets.left,
                y: view.safeAreaInsets.top,
                width: view.frame.width - view.safeAreaInsets.left - view.safeAreaInsets.right,
                height: view.frame.height - view.safeAreaInsets.bottom - view.safeAreaInsets.top - keyboardDelta)
    }
    
    func setupKeyboardMonitor ()
    {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow),
            name: UIWindow.keyboardWillShowNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIWindow.keyboardWillHideNotification,
            object: nil)
    }
    
    var keyboardDelta: CGFloat = 0
    @objc private func keyboardWillShow(_ notification: NSNotification) {
        let key = UIResponder.keyboardFrameBeginUserInfoKey
        guard let frameValue = notification.userInfo?[key] as? NSValue else {
            return
        }
        let frame = frameValue.cgRectValue
        keyboardDelta = frame.height
        tv.frame = makeFrame(keyboardDelta: frame.height)
    }
    
    @objc private func keyboardWillHide(_ notification: NSNotification) {
        //let key = UIResponder.keyboardFrameBeginUserInfoKey
        keyboardDelta = 0
        tv.frame = makeFrame(keyboardDelta: 0)
    }
    
    var metal: Bool = true
    var device: MTLDevice!
    var queue: MTLCommandQueue!
    var mdesc: MTLRenderPassDescriptor!
    var myDelegate: MyLayerDelegate!
    var renderPipeline: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!
    var displayLink: CADisplayLink!
    var metalLayer: CAMetalLayer!
    
    class MyLayerDelegate: NSObject,  CALayerDelegate {
        var p: ViewController
        init (_ p: ViewController) { self.p = p }
        
    }

    struct Vertex {
        var position: SIMD4<Float>
        var color: SIMD4<Float>
    }

    func setupMetal1 ()
    {
        mdesc = MTLRenderPassDescriptor ()
        mdesc.colorAttachments [0].loadAction = .clear
        mdesc.colorAttachments [0].storeAction = .store
        mdesc.colorAttachments [0].clearColor = MTLClearColorMake(0, 1, 1, 1)
        
        let shaderLib = device.makeDefaultLibrary()!
        let vertexp = shaderLib.makeFunction(name: "vertexShader")!
        let fragmentp = shaderLib.makeFunction(name: "fragmentShader")!
    }
    
    func setupMetal ()
    {
        let library = device.makeDefaultLibrary()!
        let vertexFunc = library.makeFunction(name: "main_vertex")!
        let fragmentFunc = library.makeFunction(name: "main_fragment")!
        
        // Setup pipeline (non-transient)
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunc
        pipelineDescriptor.fragmentFunction = fragmentFunc
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            
            
        guard let pipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor) else { abort () }
        self.renderPipeline = pipelineState
        
        // Setup buffer (non-transient). Coordinates defined in clip space: [-1,+1]
        let vertices = [Vertex(position: [ 0.0,  0.5, 0, 1], color: [1,0,0,1]),
                        Vertex(position: [-0.5, -0.5, 0, 1], color: [0,1,0,1]),
                        Vertex(position: [ 0.5, -0.5, 0, 1], color: [0,0,1,1]) ]
        let size = vertices.count * MemoryLayout<Vertex>.stride
        guard let buffer = device.makeBuffer(bytes: vertices, length: size, options: .cpuCacheModeWriteCombined) else { abort() }
        buffer.label = "demo.buffer"
        vertexBuffer = buffer
        
        displayLink = CADisplayLink(target: self, selector: #selector (tickTrigger(from:)))
        displayLink.add (to: .main, forMode: .common)
    }

    func redrawLayer ()
    {
        // Setup Command Buffer (transient)
        guard let drawable = self.metalLayer.nextDrawable(),
            let commandBuffer = self.queue.makeCommandBuffer() else { return }
        
        let renderPass = MTLRenderPassDescriptor()
        
        renderPass.colorAttachments [0].texture = drawable.texture
        renderPass.colorAttachments [0].clearColor = MTLClearColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1)
        renderPass.colorAttachments [0].loadAction = .clear
        renderPass.colorAttachments [0].storeAction = .store
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return }
        encoder.setRenderPipelineState(self.renderPipeline)
        encoder.setVertexBuffer(self.vertexBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        
        // Present drawable is a convenience completion block that will get executed once your command buffer finishes, and will output the final texture to screen.
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    @objc func tickTrigger(from displayLink: CADisplayLink) {
        redrawLayer ()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Do any additional setup after loading the view, typically from a nib.
        setupKeyboardMonitor()
        tv = SshTerminalView(frame: makeFrame (keyboardDelta: 0))
        
        if transparent {
            if metal {
                device = MTLCreateSystemDefaultDevice()
                queue = device.makeCommandQueue()!

                let layer = CAMetalLayer ()
                layer.device = device
                layer.frame = tv.bounds
                metalLayer = layer
                
                myDelegate = MyLayerDelegate (self)
                layer.delegate = myDelegate
                layer.pixelFormat = .bgra8Unorm
                
                setupMetal ()
                view.layer.addSublayer(layer)
                

            } else {
                let x = UIImage (contentsOfFile: "/tmp/Lucia.png")!.cgImage
                //let x = UIImage (systemName: "star")!.cgImage
                let layer = CALayer()
                tv.isOpaque = false
                tv.backgroundColor = UIColor.clear
                tv.nativeBackgroundColor = UIColor.clear
                layer.contents = x
                layer.frame = tv.bounds
                view.layer.addSublayer(layer)
            }
        }
        
        view.addSubview(tv)
        tv.becomeFirstResponder()
        tv.feed(text: "Welcome to SwiftTerm - connecting to my localhost\n\n")
    }
    
    override func viewWillLayoutSubviews() {
        tv.frame = makeFrame (keyboardDelta: keyboardDelta)
        if transparent {
            tv.backgroundColor = UIColor.clear
        }
    }
}

