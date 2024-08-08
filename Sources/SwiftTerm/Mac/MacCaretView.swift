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
    var ctline: CTLine?
    var bgColor: CGColor
    var tracksFocus = true
    
    public init (frame: CGRect, cursorStyle: CursorStyle, terminal: TerminalView)
    {
        self.terminal = terminal
        style = cursorStyle
        bgColor = caretColor.cgColor
        super.init(frame: frame)
        wantsLayer = true
        
        updateView()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setText (ch: CharData) {
        let res = NSAttributedString (
            string: String (ch.getCharacter()),
            attributes: terminal?.getAttributedValue(ch.attribute, usingFg: caretColor, andBg: caretTextColor ?? terminal?.nativeForegroundColor ?? NSColor.black))
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
            updateAnimation(to: true)
        case .steadyBar, .steadyBlock, .steadyUnderline:
            updateAnimation(to: false)
        }
        updateView ()
    }
    
    func updateAnimation (to: Bool) {
        layer?.removeAllAnimations()
        self.layer?.opacity = 1
        if to {
            let anim = CABasicAnimation.init(keyPath: #keyPath (CALayer.opacity))
            anim.duration = 0.7
            anim.autoreverses = true
            anim.repeatCount = Float.infinity
            anim.fromValue = NSNumber (floatLiteral: 1)
            anim.toValue = NSNumber (floatLiteral: 0)
            anim.timingFunction = CAMediaTimingFunction (name: .easeIn)
            layer?.add(anim, forKey: #keyPath (CALayer.opacity))
        }
    }
    
    func disableAnimations () {
        layer?.removeAllAnimations()
        layer?.opacity = 1
    }
    
    public var defaultCaretColor = NSColor.selectedControlColor
    
    public var caretColor: NSColor = NSColor.selectedControlColor {
        didSet {
            bgColor = caretColor.cgColor
            updateView()
        }
    }

    public var defaultCaretTextColor: NSColor? = nil
    public var caretTextColor: NSColor? = nil {
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
        setNeedsDisplay(bounds)
    }
    
    func draw(_ layer: CALayer, in context: CGContext) {
        drawCursor (in: context, hasFocus: tracksFocus ? (terminal?.hasFocus ?? true) : true)
    }
    
    override func draw(_ dirtyRect: NSRect) {
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        // we do not want to steal hits, let the terminal view take them
        return nil
    }
}
#endif
