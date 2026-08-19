//
//  AppDelegate.swift
//  MacTerminal
//
//  Created by Miguel de Icaza on 3/11/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Cocoa
import SwiftTerm
@main
class AppDelegate: NSObject, NSApplicationDelegate {
    @IBOutlet var loggingMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        ResizeTrace.reset()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        if let terminal = ViewController.lastTerminal {
            ViewController.closeTerminalUIWhenMetalIsIdle(terminal)
        }
    }


}
