//
//  TerminalRenderer.swift
//
// Protocol for terminal rendering backends (Core Graphics and Metal)
//
//

#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import CoreGraphics

/// Available terminal renderer types
public enum TerminalRendererType {
    case coreGraphics
    case metal
    case auto
}

/// Protocol defining the interface for terminal rendering backends
protocol TerminalRenderer {
    /// Render terminal contents to the specified dirty rectangle
    func drawTerminalContents(dirtyRect: TTRect, bufferOffset: Int)
    
    /// Update renderer when font changes
    func fontChanged()
    
    /// Update renderer when view size changes
    func sizeChanged(newSize: CGSize)

    /// Used on MacOS/CoreGraphics only
    func setBackgroundColor(_ color: CGColor)
    
    /// Cleanup resources
    func cleanup()
}
#endif
