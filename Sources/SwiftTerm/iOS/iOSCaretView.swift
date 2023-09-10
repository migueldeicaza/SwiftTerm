//
//  iOSCaretView.swift
//
// Implements the caret in the iOS caret view
//
//  Created by Miguel de Icaza on 3/20/20.
//

#if os(iOS) || os(visionOS)
import Foundation
import UIKit
import CoreText
import CoreGraphics

// The CaretView is used to show the cursor
class CaretView: UIView {
    weak var terminal: TerminalView?
    var ctline: CTLine?
    var bgColor: CGColor
    var tracksFocus = true
    
    public init (frame: CGRect, cursorStyle: CursorStyle, terminal: TerminalView)
    {
        style = cursorStyle
        bgColor = caretColor.cgColor
        self.terminal = terminal
        super.init(frame: frame)
        layer.isOpaque = false
        isUserInteractionEnabled = false
        updateView()
    }
    
    @objc func foreground () {
        updateCursorStyle()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    var style: CursorStyle {
        didSet {
            updateCursorStyle ()
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow != nil {
            updateCursorStyle()
        }
    }
    
    override func didMoveToWindow() {
        if window != nil {
            NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: NSNotification.Name(rawValue: UIApplication.willEnterForegroundNotification.rawValue), object: nil)
        } else {
            NotificationCenter.default.removeObserver(self,  name: NSNotification.Name(rawValue: UIApplication.willEnterForegroundNotification.rawValue), object: nil)
        }
        updateCursorStyle ();
    }
    
    func updateAnimation (to: Bool) {
        layer.removeAllAnimations()
        self.layer.opacity = 1
        if window == nil {
            return
        }
        if to {
            UIView.animate(withDuration: 0.7, delay: 0, options: [.autoreverse, .repeat, .curveEaseIn], animations: {
                self.layer.opacity = 0.0
            }, completion: { [weak self] done in
                // Attempt again, could be the window transitioning
                if done {
                    self?.updateAnimation(to: to)
                }
            })
        }
    }
    
    func setText (ch: CharData) {
        let res = NSAttributedString (
            string: String (ch.getCharacter()),
            attributes: terminal?.getAttributedValue(ch.attribute, usingFg: caretColor, andBg: caretTextColor ?? terminal?.nativeForegroundColor ?? TTColor.black))
        ctline = CTLineCreateWithAttributedString(res)
        setNeedsDisplay(bounds)
    }
    
    func updateCursorStyle () {
        switch style {
        case .blinkUnderline, .blinkBlock, .blinkBar:
            updateAnimation(to: true)
        case .steadyBar, .steadyBlock, .steadyUnderline:
            updateAnimation(to: false)
        }
        updateView()
    }
    
    func disableAnimations() {
        layer.removeAllAnimations()
        layer.opacity = 1
    }
    
    public var defaultCaretColor = UIColor.gray
    
    public var caretColor: UIColor = UIColor.gray {
        didSet {
            updateView()
        }
    }

    public var defaultCaretTextColor: UIColor? = nil
    public var caretTextColor: UIColor? = nil {
        didSet {
            updateView()
        }
    }

    func updateView() {
        setNeedsDisplay()
    }

    override public func draw (_ dirtyRect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext () else {
            return
        }
        context.scaleBy (x: 1, y: -1)
        context.translateBy(x: 0, y: -frame.height)

        drawCursor(in: context, hasFocus: tracksFocus ? (superview?.isFirstResponder ?? true) : true)
    }

}
#endif
