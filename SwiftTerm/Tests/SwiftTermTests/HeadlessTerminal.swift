//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 4/5/20.
//

import Foundation
import SwiftTerm

//
// Just a class that implements a very barebones and useless terminal and local process handler
// intended to be used by the test suite in headless mode, where we can run a battery of tests
// and then just look at the output
// 
class HeadlessTerminal : TerminalDelegate, LocalProcessDelegate {
    var terminal: Terminal!
    var process: LocalProcess!
    var onEnd: (_ exitCode: Int32?) -> ()
    var dir: String?
    
    public init (queue: DispatchQueue? = nil, options: TerminalOptions? = nil, onEnd: @escaping (_ exitCode: Int32?) -> ())
    {
        self.onEnd = onEnd
        terminal = Terminal(delegate: self, options: options)
        process = LocalProcess(delegate: self, dispatchQueue: queue)
    }
    
//    /**
//     * This method is invoked when input from the user needs to be sent to the client
//     */
//    public func send(source: TerminalView, data: ArraySlice<UInt8>)
//    {
//        process.send (data: data)
//    }
//
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        onEnd (exitCode)
    }
    
    func dataReceived(slice: ArraySlice<UInt8>) {
        //print (String (bytes: slice, encoding: .utf8))
        terminal.feed(buffer: slice)
    }
    
    func send(data: ArraySlice<UInt8>) {
        process.send (data: data)
    }

    func send(_ text: String) {
        send (data: ([UInt8] (text.utf8))[...])
        
    }

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        send (data: data)
    }
    

    func getWindowSize() -> winsize {
        return winsize(ws_row: UInt16(terminal.rows), ws_col: UInt16(terminal.cols), ws_xpixel: UInt16 (16), ws_ypixel: UInt16 (16))
    }
    
    func mouseModeChanged(source: Terminal) {
    }

    func hostCurrentDirectoryUpdated(source: Terminal) {
        dir = source.hostCurrentDirectory
    }
}


