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

class MyTerminalDelegate : TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        
    }
    
    func bufferActivated(source: Terminal) {
        
    }
    
    func showCursor(source: Terminal) {
        
    }
    
    func setTerminalTitle(source: Terminal, title: String) {
        
    }
    
    func sizeChanged(source: Terminal) {
        
    }
        
    func scrolled(source: Terminal, yDisp: Int) {
        
    }
    
    func linefeed(source: Terminal) {
        
    }
    
    
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow!


    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Create the SwiftUI view that provides the window contents.
        let contentView = ContentView()
        
        // Create the window and set the content view. 
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.center()
        window.setFrameAutosaveName("Main Window")
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }


}

