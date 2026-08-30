//
//  MacCaretView.swift
//  
// Implements the caret in the Mac caret view
// TODO: looks like I can kill sub now. unless it can be used to draw a border when out of focus
//
//  Created by Miguel de Icaza on 3/20/20.
//

#if !SWIFTTERM_EMBEDDED
#if os(macOS)
import Foundation
import AppKit
import CoreText
import CoreGraphics
import CoreText

// The CaretView is used to show the cursor
class CaretView: NSView {
    weak var terminal: TerminalView?
    var ctline: CTLine?
    /// Cell width of the character currently under the caret (2 for full-width
    /// CJK). Used to center its glyph within the caret, matching the text.
    var glyphColumnWidth: Int = 1
    var powerlineCodePoint: UInt32?
    var renderCursorColor = NSColor.selectedControlColor
    var renderTextColor = NSColor.black
    var renderCustomBlockGlyphs = true
    var renderNormalFont: NSFont?
    var bgColor: CGColor
    var tracksFocus = true {
        didSet {
            updateCursorStyle()
        }
    }
    
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

    // Enable transparency support for the cursor (matches iOS behavior)
    override func makeBackingLayer() -> CALayer {
        let layer = super.makeBackingLayer()
        layer.isOpaque = false
        layer.backgroundColor = NSColor.clear.cgColor
        return layer
    }
    
    func setText (_ data: CaretRenderData) {
        glyphColumnWidth = max(1, Int(data.width))
        renderCursorColor = data.cursorColor
        renderTextColor = data.textColor
        renderCustomBlockGlyphs = data.customBlockGlyphs
        renderNormalFont = data.normalFont
        let hideBlinkingText = !data.textBlinkVisible && data.cellAttribute.style.contains(.blink)
        if hideBlinkingText {
            powerlineCodePoint = nil
        } else {
            powerlineCodePoint = PowerlineRenderer.glyph(for: UInt32(data.code)) == nil
                ? nil : UInt32(data.code)
        }
        let character = hideBlinkingText ? " " : data.character
        // A host glyph fallback carries an explicit font; appending a
        // variation selector would only fight it.
        let usesGlyphFallback = data.attributes[SwiftTermGlyphPolicyKey] != nil
        let res = NSAttributedString (
            string: usesGlyphFallback ? String (character)
                                      : UnicodeUtil.textPresentationAdjusted (character),
            attributes: data.attributes)
        ctline = CTLineCreateWithAttributedString(res)

        setNeedsDisplay(bounds)
    }
    
    var style: CursorStyle {
        didSet {
            updateCursorStyle ()
        }
    }
    
    func updateCursorStyle () {
        let canBlink = !tracksFocus || (terminal?.hasFocus ?? true)
        switch style {
        case .blinkUnderline, .blinkBlock, .blinkBar:
            updateAnimation(to: canBlink)
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
            // The CA opacity animation is self-driving: the caret blinks with
            // no frame ticks needed, so it deliberately does NOT touch the
            // FrameDriver (an idle focused terminal should pause the link).
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
            updateCursorStyle()
        }
    }

    func updateView() {
        setNeedsDisplay(bounds)
    }
    
    override func draw(_ dirtyRect: NSRect) {
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        // we do not want to steal hits, let the terminal view take them
        return nil
    }
}

extension CaretView: @MainActor CALayerDelegate {
    func draw(_ layer: CALayer, in context: CGContext) {
        drawCursor(in: context, hasFocus: tracksFocus ? (terminal?.hasFocus ?? true) : true)
    }
}
#endif

#endif // !SWIFTTERM_EMBEDDED
