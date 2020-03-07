//
//  AppDelegate.swift
//  MacTerminal
//
//  Created by Miguel de Icaza on 3/4/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Cocoa
import SwiftUI
import SwiftTerm

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        print ("Size changed")
    }
    
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        window.title = title
    }
    
    func processTerminated(source: TerminalView) {
        print ("Process terminated")
    }
    

    var window: NSWindow!
    var terminal: LocalProcessTerminalView!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Create the SwiftUI view that provides the window contents.
        //let contentView = ContentView()
        
        // Create the window and set the content view. 
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.center()
        window.setFrameAutosaveName("Main Window")
        //window.contentView = NSHostingView(rootView: contentView)
        
        terminal = LocalProcessTerminalView(frame: window.frame)
        terminal.processDelegate = self
        terminal.feed(text: "Welcome to SwiftTerm")
        terminal.startProcess ()
        window.contentView = terminal
        window.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }


}

