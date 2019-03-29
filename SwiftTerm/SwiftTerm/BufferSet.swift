//
//  BufferSet.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/28/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation

class BufferSet {
    public var Normal : Buffer
    public var Alt : Buffer
    public private(set) var Active : Buffer
    var terminal : Terminal
    
    init (_ terminal : Terminal)
    {
        self.terminal = terminal
        Normal = Buffer (terminal, hasScrollback: true)
        Normal.FillViewportRows()
        
        // The alt buffer should never have scrollback.
        // See http://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h2-The-Alternate-Screen-Buffer
        Alt = Buffer (terminal, hasScrollback: false)
        Active = Normal
        SetupTabStops ()
    }
    
    public func ActivateNormalBuffer ()
    {
        if (Active === Normal) {
            return
        }
        Normal.X = Alt.X
        Normal.Y = Alt.Y
        
        // The alt buffer should always be cleared when we switch to the normal
        // buffer. This frees up memory since the alt buffer should always be new
        // when activated.
        
        Alt.Clear ()
        Active = Normal
    }
    
    public func ActivateAltBuffer (fillAttr : Int32?)
    {
        if (Active === Alt) {
            return
        }
        
        Alt.X = Normal.X
        Alt.Y = Normal.Y
        // Since the alt buffer is always cleared when the normal buffer is
        // activated, we want to fill it when switching to it.
        
        Alt.FillViewportRows(attribute: fillAttr)
        Active = Alt
    }
    
    func Resize (newColumns : Int, newRows : Int )
    {
        Normal.Resize (newCols: newColumns, newRows: newRows)
        Alt.Resize (newCols: newColumns, newRows: newRows)
    }
    
    func SetupTabStops (index : Int = -1)
    {
        Normal.SetupTabStops(index: index)
        Alt.SetupTabStops(index: index)
    }
}
