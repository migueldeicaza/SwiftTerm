//
//  BufferSet.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/28/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation

class BufferSet {
    public var normal : Buffer
    public var alt : Buffer
    public private(set) var active : Buffer
    var terminal : Terminal
    
    init (_ terminal : Terminal)
    {
        self.terminal = terminal
        normal = Buffer (terminal, hasScrollback: true)
        normal.fillViewportRows()
        
        // The alt buffer should never have scrollback.
        // See http://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h2-The-Alternate-Screen-Buffer
        alt = Buffer (terminal, hasScrollback: false)
        active = normal
        setupTabStops ()
    }
    
    public var isAlternateBuffer: Bool { active === normal }

    public func activateNormalBuffer ()
    {
        if active === normal {
            return
        }
        normal.x = alt.x
        normal.y = alt.y
        
        // The alt buffer should always be cleared when we switch to the normal
        // buffer. This frees up memory since the alt buffer should always be new
        // when activated.
        
        alt.clear ()
        active = normal
    }
    
    public func activateAltBuffer (fillAttr : Int32?)
    {
        if active === alt {
            return
        }
        
        alt.x = normal.x
        alt.y = normal.y
        // Since the alt buffer is always cleared when the normal buffer is
        // activated, we want to fill it when switching to it.
        
        alt.fillViewportRows(attribute: fillAttr)
        active = alt
    }
    
    public func resize (newColumns : Int, newRows : Int )
    {
        normal.resize (newCols: newColumns, newRows: newRows)
        alt.resize (newCols: newColumns, newRows: newRows)
    }
    
    public func setupTabStops (index : Int = -1)
    {
        normal.setupTabStops(index: index)
        alt.setupTabStops(index: index)
    }
}
