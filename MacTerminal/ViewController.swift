//
//  ViewController.swift
//  MacTerminal
//
//  Created by Miguel de Icaza on 3/11/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Cocoa
import SwiftTerm

class ViewController: NSViewController, LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        print ("Size changed")
    }
    
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        view.window?.title = title
    }
    
    func processTerminated(source: TerminalView) {
        view.window?.close()
        print ("Process terminated")
    }
    var terminal: LocalProcessTerminalView!

    override func viewDidLoad() {
        super.viewDidLoad()

        terminal = LocalProcessTerminalView(frame: view.frame)
        terminal.processDelegate = self
        terminal.feed(text: "Welcome to SwiftTerm")
        terminal.startProcess ()
        view.addSubview(terminal)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        terminal.frame = view.frame
        terminal.needsLayout = true
    }
    
    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }

}

