//
//  iOSCaretView.swift
//
// Implements the caret in the iOS caret view
//
//  Created by Miguel de Icaza on 3/20/20.
//
#if os(iOS)
import Foundation
import UIKit
import CoreText
import CoreGraphics

// The CaretView is used to show the cursor
class CaretView: UIView {
    var sub: CALayer
    
    public init (frame: CGRect, cursorStyle: CursorStyle)
    {
        style = cursorStyle
        sub = CALayer ()
        super.init(frame: frame)
        layer.addSublayer(sub)
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
            UIView.animate(withDuration: 0.7, delay: 0, options: [.autoreverse, .repeat, .curveEaseInOut], animations: {
                self.layer.opacity = 0.3
            }, completion: { [weak self] done in
                // Attempt again, could be the window transitioning
                if done {
                    self?.updateAnimation(to: to)
                }
            })
        }
    }
    
    func updateCursorStyle () {
        switch style {
        case .blinkUnderline, .blinkBlock, .blinkBar:
            updateAnimation(to: true)
        case .steadyBar, .steadyBlock, .steadyUnderline:
            updateAnimation(to: false)
        }
        
        switch style {
        case .steadyBlock, .blinkBlock:
            sub.frame = CGRect (x: 0, y: 0, width: layer.bounds.width, height: layer.bounds.height)
        case .steadyUnderline, .blinkUnderline:
            sub.frame = CGRect (x: 0, y: layer.bounds.height-2, width: layer.bounds.width, height: 2)
        case .steadyBar, .blinkBar:
            sub.frame = CGRect (x: 0, y: 0, width: 2, height: layer.bounds.height)
        }
    }
    
    func disableAnimations() {
        layer.removeAllAnimations()
    }
    
    public var defaultCaretColor = UIColor.gray
    
    public var caretColor: UIColor = UIColor.gray {
        didSet {
            updateView()
        }
    }

    func updateView() {
        let isFirst = self.superview?.isFirstResponder ?? true || true
        sub.frame = CGRect (origin: CGPoint.zero, size: layer.frame.size)

        sub.borderWidth = isFirst ? 0 : 2
        sub.borderColor = caretColor.cgColor
        sub.backgroundColor = isFirst ? caretColor.cgColor : UIColor.clear.cgColor
    }
}
#endif
