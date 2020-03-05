//
//  MacTerminalView.swift
//  
//
//  Created by Miguel de Icaza on 3/4/20.
//

#if os(OSX)
import Foundation
import AppKit
import CoreText

public class TerminalView: NSView, TerminalDelegate {
    public func showCursor(source: Terminal) {
        //
    }
    
    public func setTerminalTitle(source: Terminal, title: String) {
        //
    }
    
    public func sizeChanged(source: Terminal) {
        //
    }
    
    public func send(data: ArraySlice<UInt8>) {
        //
    }
    
    public func scrolled(source: Terminal, yDisp: Int) {
        //
    }
    
    public func linefeed(source: Terminal) {
        //
    }
    
    var terminal: Terminal!
    var fontNormal: NSFont!
    var fontBold: NSFont!
    var fontItalic: NSFont!
    var fontBoldItalic: NSFont!
    var cellWidth, cellHeight, cellDelta: CGFloat!
    
    public override init (frame: CGRect)
    {
        super.init (frame: frame)
        setup (rect: frame)
    }
    
    public required init? (coder: NSCoder)
    {
        super.init (coder: coder)
        setup (rect: self.bounds)
    }
    
    func setup (rect: CGRect)
    {
        fontNormal = NSFont(name: "Lucida Sans Typewriter", size: 14) ?? NSFont(name: "Courier", size: 14)!
        fontBold = NSFont(name: "Lucida Sans Typewriter Bold", size: 14) ?? NSFont(name: "Courier Bold", size: 14)!
        fontItalic = NSFont(name: "Lucida Sans Typewriter Oblique", size: 14) ?? NSFont(name: "Courier Oblique", size: 14)!
        fontBoldItalic = NSFont(name: "Lucida Sans Typewriter Bold Oblique", size: 14) ?? NSFont(name: "Courier Bold Oblique", size: 14)!
        let textBounds = computeCellDimensions()
        
        let options = TerminalOptions ()
        options.cols = Int (rect.width / cellWidth)
        options.rows = Int (rect.height / cellHeight)
        terminal = Terminal(delegate: self, options: options)
    }
    
    func computeCellDimensions () -> CGRect
    {
        let line = CTLineCreateWithAttributedString (NSAttributedString (string: "W", attributes: [NSAttributedString.Key.font: fontNormal!]))
        
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        cellWidth = bounds.width
        cellHeight = bounds.height
        cellDelta = bounds.minY
        return bounds
    }
}
#endif
