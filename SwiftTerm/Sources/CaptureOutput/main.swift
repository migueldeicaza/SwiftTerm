//
//  main.swift
//
// Capture output is used to capture the output of assorted commands that
// are fed to the application.   Used to augment the fuzzing tests
//
//  Created by Miguel de Icaza on 4/24/20.
//

import Foundation
import SwiftTerm

public class CaptureTerminal : TerminalDelegate, LocalProcessDelegate {
    var data: [UInt8] = []
    public private(set) var terminal: Terminal!
    var process: LocalProcess!
    var onEnd: (_ exitCode: Int32?) -> ()
    var dir: String?
    
    public init (queue: DispatchQueue? = nil, options: TerminalOptions = TerminalOptions.default, onEnd: @escaping (_ exitCode: Int32?) -> ())
    {
        self.onEnd = onEnd
        terminal = Terminal(delegate: self, options: options)
        process = LocalProcess(delegate: self, dispatchQueue: queue)
    }
    
    public func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        onEnd (exitCode)
    }
    
    public func dataReceived(slice: ArraySlice<UInt8>) {
        //print (String (bytes: slice, encoding: .utf8))
        terminal.feed(buffer: slice)
        data.append(contentsOf: slice)
    }
    
    func send(data: ArraySlice<UInt8>) {
        process.send (data: data)
    }

    func send(_ text: String) {
        send (data: ([UInt8] (text.utf8))[...])
        
    }

    public func send(source: Terminal, data: ArraySlice<UInt8>) {
        send (data: data)
    }
    

    public func getWindowSize() -> winsize {
        return winsize(ws_row: UInt16(terminal.rows), ws_col: UInt16(terminal.cols), ws_xpixel: UInt16 (16), ws_ypixel: UInt16 (16))
    }
    
    public func mouseModeChanged(source: Terminal) {
    }

    public func hostCurrentDirectoryUpdated(source: Terminal) {
        dir = source.hostCurrentDirectory
    }
}


func runAndCapture (strings: [String], name: String, delay: Int = 1)
{
    let queue = DispatchQueue(label: "Runner", qos: .userInteractive, attributes: .concurrent, autoreleaseFrequency: .inherit, target: nil)

    let h = CaptureTerminal (queue: queue) { exitCode in }
    h.process.startProcess(executable: "/bin/bash", args: [], environment: nil)
    
    for line in strings {
        h.send (line)
        // 2 seconds
        Thread.sleep(forTimeInterval: Double (delay))
    }
    let data = Data (h.data)
    FileManager.default.createFile(atPath: name, contents: data, attributes:nil)
}

runAndCapture (strings: ["mc\n", "\u{1b}0"], name: "/tmp/mc.output")
runAndCapture (strings: ["emacs /Users/miguel/cvs/SwiftTermFuzzerCorpus/UTF-8-demo.txt\n",
                         "\u{16}\u{16}\u{16}\u{16}\u{16}",
                         "\u{16}\u{16}\u{16}\u{16}\u{16}",
                         "\u{18}\u{3}"], name: "/tmp/emacs.output")
runAndCapture(strings: ["vim  -u /tmp/scroll.vim -c ':call AutoScroll(100)'  /Users/miguel/cvs/SwiftTermFuzzerCorpus/UTF-8-demo.txt\n",
                        "",
                        ""],
              
              name: "/tmp/vim.autoscroll.output")
runAndCapture(strings: ["vim -u /tmp/scroll.vim -c ':call AutoWindowScroll(10)'  /Users/miguel/cvs/SwiftTermFuzzerCorpus/UTF-8-demo.txt\n",
                        "",
                        ""],
              
              name: "/tmp/vim2.autoscroll.output")
runAndCapture (strings: ["~/bin/esb\n"], name: "/tmp/esctest.output", delay: 20)

