//
//  iOSCoreGraphicsRenderer.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 8/10/25.
//
#if os(iOS)
import UIKit

/// Core Graphics implementation (existing rendering code)
class CoreGraphicsTerminalRenderer: TerminalRenderer {
    weak var view: TerminalView?
    
    init(view: TerminalView) {
        self.view = view
    }
    
    func drawTerminalContents(dirtyRect: TTRect, bufferOffset: Int) {
        guard let view = self.view else { return }
        
        guard let context = UIGraphicsGetCurrentContext() else { return }
        // Without these two lines, on font changes, some junk is being displayed
        // Once we test the font change, we could disable these two lines, and
        // enable the #if false in drawterminalContents that should be coping with this now
        nativeBackgroundColor.set ()
        context.fill ([dirtyRect])

        // drawTerminalContents and CoreText expect the AppKit coordinate system
        context.scaleBy (x: 1, y: -1)
        context.translateBy(x: 0, y: -frame.height)

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
    
    func setBackgroundColor(_ color: CGColor) {
        // Not needed on iOS
    }
}
#endif
