//
//  Terminal.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/27/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation

protocol TerminalDelegate {
    func ShowCursor (source : Terminal)
    func SetTerminalTitle (source : Terminal, title : String)
    func SizeChanged (source : Terminal)
    func Send (data : ArraySlice<UInt8>)
}

class Terminal {
    // Options
    var Scrollback : Int = 200
    var Cols : Int = 80
    var Rows : Int = 25
    var TabStopWidth : Int = 8

    var buffers : BufferSet? = nil
    var applicationKeypad : Bool
    var applicationCursor : Bool
    var cursorHidden : Bool
    var originMode : Bool
    var insertMode : Bool
    var bracketedPasteMode : Bool
    var charset : [UInt8:String]
    var gcharset : Int
    var wraparound : Bool
    var tdel : TerminalDelegate
    var curAttr : Int32
    var gLevel = 0
    
    var parser : EscapeSequenceParser
    
    init (delegate : TerminalDelegate)
    {
        tdel = delegate
        
        
        // Modes
        cursorHidden = false
        applicationCursor = false
        applicationKeypad = false
        originMode = false
        insertMode = false
        wraparound = true
        bracketedPasteMode = false
        
        // Charset
        charset = [:]
        gcharset = 0
        gLevel = 0
        
        //
        curAttr = CharData.defaultAttr
        
        
        parser = EscapeSequenceParser ()
        buffers = BufferSet (self)
    }
}
