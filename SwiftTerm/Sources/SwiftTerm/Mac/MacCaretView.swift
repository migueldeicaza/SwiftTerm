//
//  MacCaretView.swift
//  
// Implements the caret in the Mac terminal view
//
//  Created by Miguel de Icaza on 3/20/20.
//

#if os(OSX)
import Foundation
import AppKit
import CoreText
import CoreGraphics

// The CaretView is used to show the cursor
class CaretView: NSView {
    public override init (frame: CGRect)
    {
        super.init(frame: frame)
        wantsLayer = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public var caretColor: NSColor! {
        didSet (newValue) {
            if let val = newValue {
                layer?.borderColor = val.cgColor
                if focused {
                    layer?.backgroundColor = val.cgColor
                    layer?.borderWidth = 0
                } else {
                    layer?.borderWidth = 1
                }
            }
        }
    }
    
    public var focused: Bool = false {
        didSet (newValue) {
            if focused {
                layer?.backgroundColor = caretColor.cgColor
                layer?.borderWidth = 0
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
                layer?.borderWidth = 2
            }
        }
    }
}
#endif
