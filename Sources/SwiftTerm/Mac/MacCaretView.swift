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
import CoreText

// The CaretView is used to show the cursor
class CaretView: NSView, CALayerDelegate {
    weak var terminal: TerminalView?
    var sub: CALayer
    var ctline: CTLine?
    var backgroundColor: CGColor?
    
    func getAttributes (_ attribute: Attribute) -> [NSAttributedString.Key:Any]?
    {
        guard let terminal else {
            return nil
        }
        let flags = attribute.style
        var bg = attribute.bg
        var fg = attribute.fg
        
        if flags.contains (.inverse) {
            swap (&bg, &fg)
            
            if fg == .defaultColor {
                fg = .defaultInvertedColor
            }
            if bg == .defaultColor {
                bg = .defaultInvertedColor
            }
        }
        
        var tf: TTFont
        let isBold = flags.contains(.bold)
        if isBold {
            if flags.contains (.italic) {
                tf = terminal.fontSet.boldItalic
            } else {
                tf = terminal.fontSet.bold
            }
        } else if flags.contains (.italic) {
            tf = terminal.fontSet.italic
        } else {
            tf = terminal.fontSet.normal
        }
        
        // TODO: let fgColor = mapColor (color: fg, isFg: true, isBold: isBold)
        let nsattr: [NSAttributedString.Key:Any] = [
            .font: tf,
            .foregroundColor: NSColor.black,
            .backgroundColor: TTColor.make(color: terminal.terminal.cursorColor ?? Color (red: 0xffff, green: 0xffff, blue: 0xffff))
        ]
//        if flags.contains (.underline) {
//            nsattr [.underlineColor] = fgColor
//            nsattr [.underlineStyle] = NSUnderlineStyle.single.rawValue
//        }
//        if flags.contains (.crossedOut) {
//            nsattr [.strikethroughColor] = fgColor
//            nsattr [.strikethroughStyle] = NSUnderlineStyle.single.rawValue
//        }
//        if withUrl {
//            nsattr [.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDash.rawValue
//            nsattr [.underlineColor] = fgColor
//
//            // Add to cache
//            urlAttributes [attribute] = nsattr
//        } else {
//            // Just add to cache
//            attributes [attribute] = nsattr
//        }
        return nsattr
    }
    
    public init (frame: CGRect, cursorStyle: CursorStyle, terminal: TerminalView)
    {
        self.terminal = terminal
        style = cursorStyle
        //style = .steadyBlock
        sub = CALayer ()
        super.init(frame: frame)
        //sub.delegate = self
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
            attributes: getAttributes(ch.attribute))
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
            anim.duration = 1
            anim.autoreverses = true
            anim.repeatCount = Float.infinity
            anim.fromValue = NSNumber (floatLiteral: 1)
            anim.toValue = NSNumber (floatLiteral: 0)
            anim.timingFunction = CAMediaTimingFunction (name: .easeInEaseOut)
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
        //sub.backgroundColor = isFirst ? caretColor.cgColor : NSColor.clear.cgColor
        //sub.backgroundColor = NSColor.red.cgColor
        backgroundColor = isFirst ? caretColor.cgColor : NSColor.clear.cgColor
    }
    
    func draw(_ layer: CALayer, in context: CGContext) {
        drawCursor (in: context)
    }
    
    func drawCursor (in context: CGContext) {
        guard let ctline else {
            return
        }
        guard let terminal else {
            return
        }
        let lineDescent = CTFontGetDescent(terminal.fontSet.normal)
        let lineLeading = CTFontGetLeading(terminal.fontSet.normal)
        let yOffset = ceil(lineDescent+lineLeading)

        if let backgroundColor {
            context.setFillColor(backgroundColor)
            context.fill([bounds])
        }
        context.setFillColor(NSColor.black.cgColor)
        for run in CTLineGetGlyphRuns(ctline) as? [CTRun] ?? [] {
            let runGlyphsCount = CTRunGetGlyphCount(run)
            let runAttributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
            let runFont = runAttributes[.font] as! TTFont

            let runGlyphs = [CGGlyph](unsafeUninitializedCapacity: runGlyphsCount) { (bufferPointer, count) in
                CTRunGetGlyphs(run, CFRange(), bufferPointer.baseAddress!)
                count = runGlyphsCount
            }

            var positions = runGlyphs.enumerated().map { (i: Int, glyph: CGGlyph) -> CGPoint in
                CGPoint(x: 0, y: yOffset)
            }
            CTFontDrawGlyphs(runFont, runGlyphs, &positions, positions.count, context)

        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        //drawCursor(in: dirtyRect)
        
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        // we do not want to steal hits, let the terminal view take them
        return nil
    }
}
#endif
