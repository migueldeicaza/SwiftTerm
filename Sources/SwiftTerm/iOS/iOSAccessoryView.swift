//
//  iOSAccessoryView.swift
//  
//  Implements an inputAccessoryView for the iOS terminal for common operations
//
//  Created by Miguel de Icaza on 5/9/20.
//
#if os(iOS)

import Foundation
import UIKit

class TerminalAccessory: UIInputView {
    public var terminal: TerminalView?
    
    public override init (frame: CGRect, inputViewStyle: UIInputView.Style)
    {
        super.init (frame: frame, inputViewStyle: inputViewStyle)
        self.reloadInputViews()
        allowsSelfSizing = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc
    func esc (_ sender: AnyObject)
    {
        print ("here")
    }
    
    func setupButtons ()
    {
        let b = UIButton(type: .infoDark)
        b.frame = CGRect (x: 0, y: 10, width: 20, height: 20)
        b.addTarget(self, action: #selector(esc(_:)), for: .touchDown)
        addSubview (b)

        let c = UIButton(type: .detailDisclosure)
        c.frame = CGRect (x: 30, y: 10, width: 20, height: 20)
        addSubview(c)
    }

}
#endif
