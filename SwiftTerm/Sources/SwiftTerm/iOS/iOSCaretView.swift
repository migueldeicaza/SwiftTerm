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
    public override init (frame: CGRect)
    {
        super.init(frame: frame)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public var caretColor: UIColor = UIColor.gray {
        didSet {
            setupView()
        }
    }
    
    public var caretFocused: Bool = false {
        didSet {
            setupView()
        }
    }

    func setupView() {
        layer.borderWidth = caretFocused ? 0 : 2
        layer.borderColor = caretColor.cgColor
        layer.backgroundColor = caretFocused ? caretColor.cgColor : UIColor.clear.cgColor
    }
}
#endif
