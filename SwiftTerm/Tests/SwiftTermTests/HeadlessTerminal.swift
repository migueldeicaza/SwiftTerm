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
    
    public init (queue: DispatchQueue? = nil, onEnd: @escaping (_ exitCode: Int32?) -> ())
    {
        self.onEnd = onEnd
        terminal = Terminal(delegate: self)
        process = LocalProcess(delegate: self, dispatchQueue: queue)
    }
    
    //
    // Delegate implementations
    //
    func showCursor(source: Terminal) {
        // nothing
    }
    
    func setTerminalTitle(source: Terminal, title: String) {
        // nothing
    }
    
    func setTerminalIconTitle(source: Terminal, title: String) {
        // nothing
    }
    
    func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? {
        // no special handling
        return nil
    }
    
    func sizeChanged(source: Terminal) {
    }
    
//    /**
//     * This method is invoked when input from the user needs to be sent to the client
//     */
//    public func send(source: TerminalView, data: ArraySlice<UInt8>)
//    {
//        process.send (data: data)
//    }
//
    func scrolled(source: Terminal, yDisp: Int) {
        // nothing
    }
    
    func linefeed(source: Terminal) {
        // nothing
    }
    
    func bufferActivated(source: Terminal) {
        // nothing
    }
    
    func bell(source: Terminal) {
        // nothing
    }
    
    func selectionChanged(source: Terminal) {
        // nothing
    }
    
    func isProcessTrusted(source: Terminal) -> Bool {
        true
    }
    
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

}


