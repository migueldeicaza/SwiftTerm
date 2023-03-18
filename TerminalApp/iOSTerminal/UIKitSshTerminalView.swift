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
        sshQueue = DispatchQueue (label: "SSH Queue")
        
        super.init (frame: frame)
        terminalDelegate = self
        do {
            
            authenticationChallenge = .byPassword(username: "miguel", password: try String (contentsOfFile: "/Users/miguel/password"))
            shell = try? SSHShell(sshLibrary: Libssh2.self,
                                  host: "10.10.11.195",
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
                    
                    // We chunk the processing of data, as the SSH library might have
                    // received a lot of data, and we do not want the terminal to
                    // parse it all, and then render, we want to parse in chunks to
                    // give the terminal the chance to update the display as it goes.
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
    
    public func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String (bytes: content, encoding: .utf8) {
            UIPasteboard.general.string = str
        }
    }
    
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        
    }

    public func requestOpenLink (source: TerminalView, link: String, params: [String:String])
    {
        if let fixedup = link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            if let url = NSURLComponents(string: fixedup) {
                if let nested = url.url {
                    UIApplication.shared.open (nested)
                }
            }
        }
    }
    
    public func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {
        // nothing
    }
    

}
