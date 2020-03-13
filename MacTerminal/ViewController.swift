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
    var changingSize = false
    
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        print ("Size changed: view frame: \(view.frame)")
        if changingSize {
            return
        }
        changingSize = true
        //var border = view.window!.frame - view.frame
        var newFrame = terminal.getOptimalFrameSize ()
        let windowFrame = view.window!.frame
        
        newFrame = CGRect (x: windowFrame.minX, y: windowFrame.minY, width: newFrame.width, height: windowFrame.height - view.frame.height + newFrame.height)
        print ("Delta \(String(describing: view.window?.frame)) \(newFrame)")
        view.window?.setFrame(newFrame, display: true, animate: true)
        changingSize = false
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
        changingSize = true
        terminal.frame = view.frame
        changingSize = false
        terminal.needsLayout = true
    }
    
    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }

}

