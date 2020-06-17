//
//  UIKitSshTerminalView.swift
//  iOS
//
//  Created by Miguel de Icaza on 4/22/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Foundation
import UIKit
import SwiftTerm
import SwiftSH


public class SshTerminalView: TerminalView, TerminalViewDelegate {
    var shell: SSHShell?
    var authenticationChallenge: AuthenticationChallenge?
    var sshQueue: DispatchQueue
    
    public override init (frame: CGRect)
    {
        sshQueue = DispatchQueue.global(qos: .background)
        super.init (frame: frame)
        terminalDelegate = self
        do {
            
            authenticationChallenge = .byPassword(username: "miguel", password: try String (contentsOfFile: "/Users/miguel/password"))
            shell = try? SSHShell(sshLibrary: Libssh2.self,
                                  host: "192.168.86.74",
                                  port: 22,
                                  environment: [Environment(name: "LANG", variable: "en_US.UTF-8")],
                                  terminal: "xterm-256color")
            shell?.log.enabled = false
            shell?.setCallbackQueue(queue: sshQueue)
            sshQueue.async {
                self.connect ()
            }
        } catch {
            
        }
    }
  
    func connect()
    {
        if let s = shell {
            s.withCallback { [unowned self] (data: Data?, error: Data?) in
                if let d = data {
                    let sliced = Array(d) [0...]
     
                    // The first code causes problems, because the SSH library
                    // accumulates data, rather that sending it as it comes,
                    // so it can deliver blocks of 300k to 2megs of data
                    // which as far as the user is concerned, nothing happens
                    // while the terminal parsers proceses this.
                    //
                    // The solution was below, and it fed the data in chunks
                    // to the UI, but this caused the UI to not update chunks
                    // of the screen, for reasons that I do not understand yet.
                    #if true
                    DispatchQueue.main.sync {
                        self.feed(byteArray: sliced)
                    }
                    #else
                    let blocksize = 1024
                    var next = 0
                    let last = sliced.endIndex
                    
                    while next < last {
                        
                        let end = min (next+blocksize, last)
                        let chunk = sliced [next..<end]
                    
                        DispatchQueue.main.sync {
                            self.feed(byteArray: chunk)
                        }
                        next = end
                    }
                    #endif
                }
            }
            .connect()
            .authenticate(self.authenticationChallenge)
            .open { [unowned self] (error) in
                if let error = error {
                    self.feed(text: "[ERROR] \(error)\n")
                } else {
                    let t = self.getTerminal()
                    s.setTerminalSize(width: UInt (t.cols), height: UInt (t.rows))
                }
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // TerminalViewDelegate conformance
    public func scrolled(source: TerminalView, position: Double) {
        //
    }
    
    public func setTerminalTitle(source: TerminalView, title: String) {
        //
    }
    
    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        if let s = shell {
            s.setTerminalSize(width: UInt (newCols), height: UInt (newRows))
        }
    }
    
    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        
        shell?.write(Data (data)) { err in
            if let e = err {
                print ("Error sending \(e)")
            }
        }
    }
    

}
