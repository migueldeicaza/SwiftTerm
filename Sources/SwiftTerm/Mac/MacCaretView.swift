//
//  MacCaretView.swift
//  
// Implements the caret in the Mac caret view
// TODO: looks like I can kill sub now. unless it can be used to draw a border when out of focus
//
//  Created by Miguel de Icaza on 3/20/20.
//

#if os(macOS)
import Foundation
import AppKit
import CoreText
import CoreGraphics
import CoreText

// The CaretView is used to show the cursor
class CaretView: NSView, CALayerDelegate {
    weak var terminal: TerminalView?
    var sub: CALayer
    var ctline: CTLine?
    var bgColor: CGColor
    
    public init (frame: CGRect, cursorStyle: CursorStyle, terminal: TerminalView)
    {
        self.terminal = terminal
        style = cursorStyle
        sub = CALayer ()
        bgColor = caretColor.cgColor
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(sub)
        
        updateView()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setText (ch: CharData) {
        var res = NSAttributedString (
            string: String (ch.getCharacter()),
            attributes: terminal?.getAttributedValue(ch.attribute, usingFg: caretColor, andBg: caretTextColor))
        ctline = CTLineCreateWithAttributedString(res)

        setNeedsDisplay(bounds)
    }
    
    var style: CursorStyle {
        didSet {
            updateCursorStyle ()
        }
    }
    
    func updateCursorStyle () {
        switch style {
        case .blinkUnderline, .blinkBlock, .blinkBar:
            let anim = CABasicAnimation.init(keyPath: #keyPath (CALayer.opacity))
            anim.duration = 0.7
            anim.autoreverses = true
            anim.repeatCount = Float.infinity
            anim.fromValue = NSNumber (floatLiteral: 1)
            anim.toValue = NSNumber (floatLiteral: 0)
            anim.timingFunction = CAMediaTimingFunction (name: .easeIn)
            layer?.add(anim, forKey: #keyPath (CALayer.opacity))
        case .steadyBar, .steadyBlock, .steadyUnderline:
            layer?.removeAllAnimations()
            layer?.opacity = 1
        }
        
        guard let layer = self.layer else {
            return
        }
        switch style {
        case .steadyBlock, .blinkBlock:
            sub.frame = CGRect (x: 0, y: 0, width: layer.bounds.width, height: layer.bounds.height)
        case .steadyUnderline, .blinkUnderline:
            sub.frame = CGRect (x: 0, y: 0, width: layer.bounds.width, height: 2)
        case .steadyBar, .blinkBar:
            sub.frame = CGRect (x: 0, y: 0, width: 2, height: layer.bounds.height)
        }

    }
    
    func disableAnimations () {
        sub.removeAllAnimations()
    }
    
    public var defaultCaretColor = NSColor.selectedControlColor
    
    public var caretColor: NSColor = NSColor.selectedControlColor {
        didSet {
            updateView()
        }
    }

    public var defaultCaretTextColor = NSColor.black
    public var caretTextColor: NSColor = NSColor.black {
        didSet {
            updateView()
        }
    }

    public var focused: Bool = false {
        didSet {
            updateView()
        }
    }

    func updateView() {
        let isFirst = focused
        guard let layer = layer else { return }
        sub.frame = CGRect (origin: CGPoint.zero, size: layer.frame.size)
        sub.borderWidth = isFirst ? 0 : 1
        sub.borderColor = caretColor.cgColor
        setNeedsDisplay(bounds)
        backgroundColor = isFirst ? caretColor.cgColor : NSColor.clear.cgColor
    }
    
    func draw(_ layer: CALayer, in context: CGContext) {
        drawCursor (in: context)
    }
    
    override func draw(_ dirtyRect: NSRect) {
        drawCursor(in: dirtyRect)        
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        // we do not want to steal hits, let the terminal view take them
        return nil
    }
}
#endif
