//
//  TerminalRenderer.swift
//
// Protocol for terminal rendering backends (Core Graphics and Metal)
//
//

#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import CoreGraphics

#if os(iOS) || os(visionOS)
import UIKit
#endif

#if os(macOS)
import AppKit
#endif

/// Protocol defining the interface for terminal rendering backends
protocol TerminalRenderer {
    /// Initialize the renderer with the given view
    func initialize(with view: TerminalView)
    
    /// Render terminal contents to the specified dirty rectangle
    func drawTerminalContents(dirtyRect: TTRect, bufferOffset: Int)
    
    /// Update renderer when font changes
    func fontChanged()
    
    /// Update renderer when colors change
    func colorsChanged()
    
    /// Update renderer when view size changes
    func sizeChanged(newSize: CGSize)
    
    /// Cleanup resources
    func cleanup()
    
    /// Whether this renderer is available on the current platform
    static var isAvailable: Bool { get }
    
    /// Performance characteristics of this renderer
    var preferredForLargeBuffers: Bool { get }
}

/// Factory for creating terminal renderers
enum TerminalRendererFactory {
    static func createRenderer(type: TerminalRendererType, for view: TerminalView) -> TerminalRenderer {
        switch type {
        case .coreGraphics:
            return CoreGraphicsTerminalRenderer(view: view)
        case .metal:
            if MetalTerminalRenderer.isAvailable {
                return MetalTerminalRenderer(view: view)
            } else {
                // Fallback to Core Graphics if Metal is not available
                return CoreGraphicsTerminalRenderer(view: view)
            }
        case .auto:
            // Choose the best renderer for the current platform and workload
            if MetalTerminalRenderer.isAvailable {
                return MetalTerminalRenderer(view: view)
            } else {
                return CoreGraphicsTerminalRenderer(view: view)
            }
        }
    }
}

/// Available terminal renderer types
public enum TerminalRendererType {
    case coreGraphics
    case metal
    case auto
}

/// Core Graphics implementation (existing rendering code)
class CoreGraphicsTerminalRenderer: TerminalRenderer {
    weak var view: TerminalView?
    
    init(view: TerminalView) {
        self.view = view
    }
    
    func initialize(with view: TerminalView) {
        self.view = view
    }
    
    func drawTerminalContents(dirtyRect: TTRect, bufferOffset: Int) {
        guard let view = self.view else { return }
        
        #if os(macOS)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        #else
        guard let context = UIGraphicsGetCurrentContext() else { return }
        #endif
        
        // Use the existing drawTerminalContents implementation from AppleTerminalView
        view.drawTerminalContents(dirtyRect: dirtyRect, context: context, bufferOffset: bufferOffset)
    }
    
    func fontChanged() {
        // Core Graphics renderer doesn't need special font change handling
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
