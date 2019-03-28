//
//  Buffer.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/26/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation

class Buffer {
    var lines : CircularList<BufferLine>
    var XDisp, YDisp, XBase, YBase : Int
    var _x, _y : Int
    var X : Int {
        get { return _x }
        set(newValue) {
            _x = newValue
        }
    }
    var Y : Int {
        get { return _y }
        set(newValue) {
            _y = newValue
        }
    }
    
    var ScrollBottom, ScrollTop : Int
    var TabStops : [Bool]
    
    var SavedX, SavedY : Int
    var SavedAttr = CharData.defaultAttr
    var hasScrollback : Bool
    
    var terminal : Terminal
    
    var Lines : CircularList<BufferLine> {
        get { return lines }
    }
    
    init (_ terminal : Terminal, hasScrollback : Bool = true)
    {
        self.terminal = terminal
        self.hasScrollback = hasScrollback
        YDisp = 0
        XDisp = 0
        YBase = 0
        TabStops = [Bool]()
        SavedX = 0
        SavedY = 0
        XBase = 0
        ScrollTop = 0
        ScrollBottom = terminal.Rows - 1
        _x = 0
        _y = 0
        
        let len = hasScrollback ? terminal.Scrollback + terminal.Rows : terminal.Rows
        lines = CircularList<BufferLine> (maxLength: len)
        SetupTabStops ()
    }
    
    func GetBlankLine (attribute : Int32, isWrapped : Bool = false) -> BufferLine
    {
        let cd = CharData (attribute: attribute)
        
        return BufferLine(cols: terminal.Cols, fillData: cd, isWrapped: isWrapped);
    }
    
    func Clear ()
    {
        YDisp = 0
        XBase = 0
        X = 0
        Y = 0
        
        let len = hasScrollback ? terminal.Scrollback + terminal.Rows : terminal.Rows
        lines = CircularList<BufferLine> (maxLength: len)
        ScrollTop = 0
        ScrollBottom = terminal.Rows - 1
        
        // Figure out how to do this elegantly
        // SetupTabStops ()
    }
    
    var IsCursorInViewPort : Bool {
        get {
            let absoluteY = YBase + YDisp
            let relativeY = absoluteY + YDisp
            return relativeY >= 0 && relativeY < terminal.Rows
        }
    }
    
    func FillViewportRows (attribute : Int32? = nil)
    {
        // TODO: limitation in original, this does not cope with partial fills, it is either zero or nothing
        if lines.length != 0 {
            return
        }
        let attr = attribute != nil ? attribute! : CharData.defaultAttr
        for _ in 0..<terminal.Rows {
            lines.Push (GetBlankLine (attribute: attr))
        }
    }
    
    func Resize (newCols : Int, newRows : Int)
    {
        Clear ()
        FillViewportRows ()
        if TabStops.count > newCols {
            TabStops.removeSubrange (newCols..<TabStops.count-1)
        } else {
            let n = newCols - TabStops.count
            for _ in 0..<n {
                TabStops.append (false)
            }
        }
    }
    
    func SetupTabStops (index : Int = -1)
    {
        let cols = terminal.Cols
        var idx = index
        
        if (idx != -1){
            let from = min (index, cols - 1)
            if !TabStops [from] {
                idx = PreviousTabStop (from)
            }
        }
        let tabStopWidth = terminal.TabStopWidth
        for i in stride(from: 0, through: cols, by: tabStopWidth) {
            TabStops [i] = true
        }
    }
    
    func TabSet (pos : Int)
    {
        TabStops [pos] = true
    }
    
    func TabClear (pos : Int)
    {
        TabStops [pos] = false
    }
    
    func ClearTabStops ()
    {
        TabStops = Array.init (repeating: false, count: TabStops.count)
    }
    
    func PreviousTabStop (_ index : Int = -1) -> Int
    {
        var idx = index == -1 ? X : index
        while (idx > 0 && TabStops [idx-1]){
            idx = idx - 1
        }
        return idx >= terminal.Cols ? terminal.Cols - 1 : idx
    }
    
    func NextTabStop (_ index : Int = -1) -> Int
    {
        var idx = index == -1 ? X : index
        repeat {
            idx = idx + 1
            if (idx == terminal.Cols) {
                break
            }
            if (TabStops [idx]) {
                break
            }
        } while (idx < terminal.Cols)
        return idx >= terminal.Cols ? terminal.Cols - 1 : idx
    }
}
