//
//  DebugWindowController.swift
//  MacTerminal
//
//  Created by Miguel de Icaza on 3/22/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Cocoa
import SwiftTerm


@objc
class DebugViewController: NSViewController {
    var debug: TerminalDebugView!
    static var lastDebug: TerminalDebugView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        debug = TerminalDebugView (frame: view.frame, terminal: ViewController.lastTerminal)
        
        view.addSubview(debug)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        debug.frame = view.frame
    }
    
    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }

}

