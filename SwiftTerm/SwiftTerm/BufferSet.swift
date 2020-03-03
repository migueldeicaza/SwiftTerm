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
        Normal.fillViewportRows()
        
        // The alt buffer should never have scrollback.
        // See http://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h2-The-Alternate-Screen-Buffer
        Alt = Buffer (terminal, hasScrollback: false)
        Active = Normal
        setupTabStops ()
    }
    
    public var isAlternateBuffer: Bool { Active === Normal }

    public func activateNormalBuffer ()
    {
        if Active === Normal {
            return
        }
        Normal.x = Alt.x
        Normal.y = Alt.y
        
        // The alt buffer should always be cleared when we switch to the normal
        // buffer. This frees up memory since the alt buffer should always be new
        // when activated.
        
        Alt.clear ()
        Active = Normal
    }
    
    public func activateAltBuffer (fillAttr : Int32?)
    {
        if Active === Alt {
            return
        }
        
        Alt.x = Normal.x
        Alt.y = Normal.y
        // Since the alt buffer is always cleared when the normal buffer is
        // activated, we want to fill it when switching to it.
        
        Alt.fillViewportRows(attribute: fillAttr)
        Active = Alt
    }
    
    public func resize (newColumns : Int, newRows : Int )
    {
        Normal.resize (newCols: newColumns, newRows: newRows)
        Alt.resize (newCols: newColumns, newRows: newRows)
    }
    
    public func setupTabStops (index : Int = -1)
    {
        Normal.setupTabStops(index: index)
        Alt.setupTabStops(index: index)
    }
}
