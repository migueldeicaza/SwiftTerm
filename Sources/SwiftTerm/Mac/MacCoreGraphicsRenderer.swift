//
//  CoreGraphicsRenderer.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 8/10/25.
//
#if os(macOS) || os(iOS) || os(visionOS) || os(tvOS)
import CoreGraphics
import AppKit

/// Core Graphics implementation for MacOS
class CoreGraphicsTerminalRenderer: TerminalRenderer {
    weak var view: TerminalView?
    
    init(view: TerminalView) {
        self.view = view
    }
    
    func drawTerminalContents(dirtyRect: TTRect, bufferOffset: Int) {
        guard let view = self.view else { return }
        
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        
        // Use the existing drawTerminalContents implementation from AppleTerminalView
        view.drawTerminalContents(dirtyRect: dirtyRect, context: context, bufferOffset: bufferOffset)
    }
    
    func fontChanged() {
        // Core Graphics renderer doesn't need special font change handling
    }

    func setBackgroundColor(_ color: CGColor) {
        view?.layer?.backgroundColor = color
    }
    
    func colorsChanged() {
        // Core Graphics renderer doesn't need special color change handling
    }
    
    func sizeChanged(newSize: CGSize) {
        // Core Graphics renderer doesn't need special size change handling
    }
    
    func cleanup() {
        view = nil
    }
    
    static var isAvailable: Bool {
        return true
    }
    
    var preferredForLargeBuffers: Bool {
        return false
    }
}
#endif

