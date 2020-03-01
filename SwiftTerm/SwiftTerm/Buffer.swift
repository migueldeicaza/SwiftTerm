//
//  Buffer.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/26/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation

class Buffer {
    var _lines : CircularList<BufferLine>
    var xDisp, yDisp, xBase, yBase : Int
    var _x, _y : Int
    
    public var x : Int {
        get { return _x }
        set(newValue) {
            _x = newValue
        }
    }
    
    public var y : Int {
        get { return _y }
        set(newValue) {
            _y = newValue
        }
    }
    
    public var scrollBotton: Int
    
    var _scrollTop: Int
    public var scrollTop : Int {
        set(newValue) {
            if newValue >= 0 {
                _scrollTop = newValue
            }
        }
        get {
            return _scrollTop
        }
    }
    var tabStops : [Bool]
    
    public var savedX, savedY: Int
    public var savedAttr = CharData.defaultAttr
    var hasScrollback : Bool
    
    var terminal: Terminal
    
    var lines : CircularList<BufferLine> {
        get { return _lines }
    }
    
    public init (_ terminal : Terminal, hasScrollback : Bool = true)
    {
        self.terminal = terminal
        self.hasScrollback = hasScrollback
        yDisp = 0
        xDisp = 0
        yBase = 0
        tabStops = [Bool]()
        savedX = 0
        savedY = 0
        xBase = 0
        _scrollTop = 0
        scrollBotton = terminal.rows - 1
        _x = 0
        _y = 0
        
        let len = hasScrollback ? terminal.scrollback + terminal.rows : terminal.rows
        _lines = CircularList<BufferLine> (maxLength: len)
        setupTabStops ()
    }
    
    public func getCorrectBufferLength (_ rows: Int) -> Int
    {
        if hasScrollback {
            let correct = rows + (terminal.options.scrollback ?? 0)
            return correct > Int32.max ? Int (Int32.max) : correct
        } else {
            return rows
        }
    }
    
    public func getBlankLine (attribute : Int32, isWrapped : Bool = false) -> BufferLine
    {
        let cd = CharData (attribute: attribute)
        
        return BufferLine(cols: terminal.cols, fillData: cd, isWrapped: isWrapped);
    }
    
    public func clear ()
    {
        yDisp = 0
        xBase = 0
        x = 0
        y = 0
        
        _lines = CircularList<BufferLine> (maxLength: getCorrectBufferLength(terminal.rows))
        scrollTop = 0
        scrollBotton = terminal.rows - 1
        
        // Figure out how to do this elegantly
        // SetupTabStops ()
    }
    
    public var isCursorInViewPort : Bool {
        get {
            let absoluteY = yBase + yDisp
            let relativeY = absoluteY + yDisp
            return relativeY >= 0 && relativeY < terminal.rows
        }
    }
    
    public func fillViewportRows (attribute : Int32? = nil)
    {
        // TODO: limitation in original, this does not cope with partial fills, it is either zero or nothing
        if _lines.length != 0 {
            return
        }
        let attr = attribute != nil ? attribute! : CharData.defaultAttr
        for _ in 0..<terminal.rows {
            _lines.push (getBlankLine (attribute: attr))
        }
    }
    
    public var isReflowEnabled: Bool {
        return hasScrollback
    }
    
    public func resize (newCols : Int, newRows : Int)
    {
        let newMaxLength = getCorrectBufferLength(newRows)
        if newMaxLength > lines.maxLength {
            lines.maxLength = newMaxLength
        }
        if lines.length > 0 {
            // Deal with columns increasing (reducing needs to happen after reflow)
            if terminal.cols < newCols {
                for i in 0..<lines.length {
                    lines [i].resize (cols: newCols, fillData: CharData.Null)
                }
            }

            // Resize rows in both directions as needed
            var addToY = 0
            if terminal.rows < newRows {
                for y in terminal.rows..<newRows {
                    if lines.length < newRows + yBase {
                        if yBase > 0 && lines.length <= yBase + y + addToY + 1 {
                            // There is room above the buffer and there are no empty elements below the line,
                            // scroll up
                            yBase -= 1
                            addToY += 1
                            if yDisp > 0 {
                                // Viewport is at the top of the buffer, must increase downwards
                                yDisp -= 1
                            }
                        } else {
                            // Add a blank line if there is no buffer left at the top to scroll to, or if there
                            // are blank lines after the cursor
                            lines.push (BufferLine (cols: newCols, fillData: CharData.Null))
                        }
                    }
                }
            } else { // (this._rows >= newRows)
                for _ in (newRows..<terminal.rows).reversed () {
                    if lines.length > newRows + yBase {
                        if lines.length > yBase + self.y + 1 {
                            // The line is a blank line below the cursor, remove it
                            lines.pop ()
                        } else {
                            // The line is the cursor, scroll down
                            yBase += 1
                            yDisp += 1
                        }
                    }
                }
            }

            // Reduce max length if needed after adjustments, this is done after as it
            // would otherwise cut data from the bottom of the buffer.
            if newMaxLength < lines.maxLength {
                // Trim from the top of the buffer and adjust ybase and ydisp.
                let amountToTrim = lines.length - newMaxLength
                if amountToTrim > 0 {
                    lines.trimStart(count: amountToTrim)
                    yBase = max (yBase - amountToTrim, 0)
                    yDisp = max (yDisp - amountToTrim, 0)
                    savedY = max (savedY - amountToTrim, 0)
                }

                lines.maxLength = newMaxLength
            }

            // Make sure that the cursor stays on screen
            x = min (x, newCols - 1);
            y = min (y, newRows - 1);
            if addToY != 0 {
                y += addToY
            }

            savedX = min (savedX, newCols - 1)

            scrollTop = 0
        }
        scrollBotton = newRows - 1
        if tabStops.count > newCols {
            tabStops.removeSubrange (newCols..<tabStops.count-1)
        } else {
            let n = newCols - tabStops.count
            for _ in 0..<n {
                tabStops.append (false)
            }
        }
        
        if isReflowEnabled {
            reflow (newCols, newRows)
            // Trim the end of the line off if cols shrunk
            if terminal.cols > newCols {
                for i in 0..<lines.length {
                    lines [i].resize (cols: newCols, fillData: CharData.Null)
                }
            }
        }
        terminal.rows = newRows
        terminal.cols = newCols
    }
    
    func translateBufferLineToString (lineIndex: Int, trimRight: Bool, startCol: Int = 0, endCol: Int = -1) -> String
    {
        let line = _lines [lineIndex]
        return line.translateToString(trimRight: trimRight, startCol: startCol, endCol: endCol)
    }
    
    func setupTabStops (index: Int = -1)
    {
        let cols = terminal.cols
        var idx = index
        
        if (idx != -1){
            if tabStops.count > cols {
                tabStops.removeSubrange(cols...)
            } else {
                for _ in cols..<tabStops.count {
                    tabStops.append(false)
                }
            }
            let from = min (index, cols - 1)
            if !tabStops [from] {
                idx = previousTabStop (from)
            }
        } else {
            tabStops = Array.init (repeating: false, count: cols)
            idx = 0
        }
        let tabStopWidth = terminal.TabStopWidth
        for i in stride(from: idx, through: cols, by: tabStopWidth) {
            tabStops [i] = true
        }
    }
    
    func tabSet (pos : Int)
    {
        if pos < tabStops.count {
            tabStops [pos] = true
        }
    }
    
    func tabClear (pos : Int)
    {
        if pos < tabStops.count {
            tabStops [pos] = false
        }
    }
    
    func clearTabStops ()
    {
        tabStops = Array.init (repeating: false, count: tabStops.count)
    }
    
    func previousTabStop (_ index : Int = -1) -> Int
    {
        var idx = index == -1 ? x : index
        while (idx > 0 && tabStops [idx-1]){
            idx = idx - 1
        }
        return idx >= terminal.cols ? terminal.cols - 1 : idx
    }
    
    func nextTabStop (_ index : Int = -1) -> Int
    {
        var idx = index == -1 ? x : index
        repeat {
            idx = idx + 1
            if (idx >= terminal.cols) {
                break
            }
            if (tabStops [idx]) {
                break
            }
        } while (idx < terminal.cols)
        return idx >= terminal.cols ? terminal.cols - 1 : idx
    }
    
    func reflow (_ newCols: Int, _ newRows: Int)
    {
        if terminal.cols == newCols {
            return
        }
        // iterate through rows, ignore the last one as it cannot be wrapped

        abort ()
        // I do not like an abstract class to swich on such a simple thing.
        // let strategy = newCols > terminal.cols ? ReflowWider (self) : ReflowNarrower (self)
        // strategy.reflow (newCols, newRows, terminal.cols, terminal.rows)
    }
}
