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
    
    @objc @IBAction
    func set80x25 (_ source: AnyObject)
    {
        terminal.resize(cols: 80, rows: 25)
    }

    var lowerCol = 80
    var lowerRow = 25
    var higherCol = 160
    var higherRow = 60
    
    func queueNextSize (_ delta: Int)
    {
        var next = terminal.getTerminal().getDims ()
        if delta > 0 {
            if next.cols < higherCol {
                next.cols += 1
            }
            if next.rows < higherRow {
                next.rows += 1
            }
        } else {
            if next.cols > lowerCol {
                next.cols -= 1
            }
            if next.rows > lowerRow {
                next.rows -= 1
            }
        }
        terminal.resize (cols: next.cols, rows: next.rows)
        var direction = delta
        
        if next.rows == higherRow && next.cols == higherCol {
            direction = -1
        }
        if next.rows == lowerRow && next.cols == lowerCol {
            direction = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            self.queueNextSize(direction)
        }
    }
    
    @objc @IBAction
    func resizificator (_ source: AnyObject)
    {
        queueNextSize (1)
    }

    @objc @IBAction
    func resizificatorDown (_ source: AnyObject)
    {
        queueNextSize (-1)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        if changingSize {
            return
        }
        changingSize = true
        //var border = view.window!.frame - view.frame
        var newFrame = terminal.getOptimalFrameSize ()
        let windowFrame = view.window!.frame
        
        newFrame = CGRect (x: windowFrame.minX, y: windowFrame.minY, width: newFrame.width, height: windowFrame.height - view.frame.height + newFrame.height)

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

    static var lastTerminal: LocalProcessTerminalView!
    
    override func viewDidLoad() {
        super.viewDidLoad()


        terminal = LocalProcessTerminalView(frame: view.frame)
        ViewController.lastTerminal = terminal
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

