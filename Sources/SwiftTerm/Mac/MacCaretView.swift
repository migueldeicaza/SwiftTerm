//
//  MacCaretView.swift
//  
// Implements the caret in the Mac caret view
//
//  Created by Miguel de Icaza on 3/20/20.
//

#if os(macOS)
import Foundation
import AppKit
import CoreText
import CoreGraphics

// The CaretView is used to show the cursor
class CaretView: NSView {
    var sub: CALayer
    
    public init (frame: CGRect, cursorStyle: CursorStyle)
    {
        style = cursorStyle
        sub = CALayer ()
        super.init(frame: frame)
        wantsLayer = true
        setupView()
        updateCursorStyle(style: style)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    var style: CursorStyle {
        didSet {
            updateCursorStyle (style: style)
        }
    }
    
    func updateCursorStyle (style: CursorStyle) {
        switch style {
        case .blinkUnderline, .blinkBlock, .blinkBar:
            let anim = CABasicAnimation.init(keyPath: #keyPath (CALayer.opacity))
            anim.duration = 0.7
            anim.autoreverses = true
            anim.repeatCount = Float.infinity
            anim.fromValue = NSNumber (floatLiteral: 1)
            anim.toValue = NSNumber (floatLiteral: 0.3)
            anim.timingFunction = CAMediaTimingFunction (name: .easeInEaseOut)
            sub.add(anim, forKey: #keyPath (CALayer.opacity))
        case .steadyBar, .steadyBlock, .steadyUnderline:
            sub.removeAllAnimations()
            sub.opacity = 1
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
    
    public var defaultCaretColor = NSColor.selectedControlColor
    
    public var caretColor: NSColor = NSColor.selectedControlColor {
        didSet {
            setupView()
        }
    }
    
    public var focused: Bool = false {
        didSet {
            setupView()
        }
    }

    func setupView() {
        guard let layer = layer else { return }
        sub.frame = CGRect (origin: CGPoint.zero, size: layer.frame.size)
        layer.addSublayer(sub)
        sub.borderWidth = focused ? 0 : 2
        sub.borderColor = caretColor.cgColor
        sub.backgroundColor = focused ? caretColor.cgColor : NSColor.clear.cgColor
        //layer.opacity = 0.7
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        // we do not want to steal hits, let the terminal view take them
        return nil
    }
}
#endif
