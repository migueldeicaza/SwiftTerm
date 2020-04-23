//
//  ViewController.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/19/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import UIKit
import SwiftTerm

class ViewController: UIViewController {
    var tv: TerminalView!
    
    func makeFrame () -> CGRect
    {
        CGRect (x: view.safeAreaInsets.left,
                y: view.safeAreaInsets.top,
                width: view.frame.width - view.safeAreaInsets.left - view.safeAreaInsets.right,
                height: view.frame.height - view.safeAreaInsets.bottom - view.safeAreaInsets.top)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        
        tv = TerminalView(frame: makeFrame ())
        view.addSubview(tv)
        
        
        for n in 0..<20 {
            tv.feed(text: "\(n) Welcome to SwiftTerm\n")
        }
    }

    override func viewWillLayoutSubviews() {
        tv.frame = makeFrame ()
    }
}

