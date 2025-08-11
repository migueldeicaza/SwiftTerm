//
//  MetalTerminalRenderer.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 8/10/25.
//
#if os(iOS) || os(macOS) || os(visionOS)
import CoreGraphics
import Metal

class MetalTerminalRenderer: TerminalRenderer {
    var view: TerminalView?
    
    init(view: TerminalView) {
        self.view = view
    }
    
    func drawTerminalContents(dirtyRect: TTRect, bufferOffset: Int) {
        fatalError()
    }
    
    func fontChanged() {
        fatalError()
    }
    
    func sizeChanged(newSize: CGSize) {
        fatalError()
    }
    
    func cleanup() {
        fatalError()
    }
    
    func setBackgroundColor(_ color: CGColor) {
        // Not needed for Metal
    }
    
    static var isAvailable: Bool {
        print("HEADS UP: THIS IS CURRENTLY DISABLED")
        return false && MTLCreateSystemDefaultDevice() != nil
    }
}
#endif
