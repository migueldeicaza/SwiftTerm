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
    
    public override init (frame: CGRect)
    {
        super.init (frame: frame)
        do {
            authenticationChallenge = .byPassword(username: "miguel", password: try String (contentsOfFile: "/Users/miguel/password"))
            shell = try? SSHShell(host: "192.168.86.78", port: 22, terminal: "xterm-256color")
            
            connect ()
        } catch {
            
        }
    }
    
    func connect()
    {
        if let s = shell {
            s.withCallback { [unowned self] (data: Data?, error: Data?) in
                if let d = data {
                    DispatchQueue.main.async {
                        let slice = Array(d) [0...]
                        self.feed(byteArray: slice)
                    }
                }
            }
            .connect()
            .authenticate(self.authenticationChallenge)
            .open { [unowned self] (error) in
                if let error = error {
                    self.feed(text: "[ERROR] \(error)\n")
                } else {
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
        //
    }
    
    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        //
    }
    

}
