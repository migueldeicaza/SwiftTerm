//
//  MacSelectionView.swift
//  
//
//  Created by Miguel de Icaza on 3/20/20.
//

#if os(OSX)
import Foundation
import AppKit
import CoreGraphics

/**
 * This view renders the selection as a CAShapeMask
 */
class SelectionView: NSView {
    var terminalView: TerminalView!
    var selection: SelectionService!
    var maskLayer: CAShapeLayer!
    var cellDim: CellDimensions
    
    public init (terminalView: TerminalView, frame: CGRect)
    {
        self.terminalView = terminalView
        cellDim = terminalView.cellDim
        selection = terminalView.selection
        
        super.init (frame: frame)
        
        wantsLayer = true
        
        maskLayer = CAShapeLayer ()
        layer?.mask = maskLayer
        layer?.backgroundColor = NSColor (calibratedRed: 0.4, green: 0.2, blue: 0.9, alpha: 0.8).cgColor
    }
    
    public required init? (coder: NSCoder)
    {
        abort ()
    }

    func notifyScrolled ()
    {
        update ()
    }
    
    func update ()
    {
        updateMask ()
    }
    
    func updateMask ()
    {
        // remove the prior mask
        maskLayer.path = nil
        
        maskLayer.frame = bounds
        let path = CGMutablePath()
        let terminal = terminalView.terminal!
        var start, end: Position
        
        if Position.compare (selection.start, selection.end) == .after {
            start = selection.end
            end = selection.start
        } else {
            start = selection.start
            end = selection.end
        }
        let screenRowStart = start.row - terminal.buffer.yDisp;
        let screenRowEnd = end.row - terminal.buffer.yDisp;
        
        // mask the row that contains the start position
        // snap to either the first or last column depending on
        // where the end position is in relation to the start
        var col = end.col
        if screenRowEnd > screenRowStart {
            col = terminal.cols
        }
        if screenRowEnd < screenRowStart {
            col = 0
        }
        
        maskPartialRow (path: path, row: screenRowStart, colStart: start.col,  colEnd: col)
        
        if screenRowStart == screenRowEnd {
            // we're done, only one row to mask
            maskLayer.path = path
            return
        }
        
        // now mask the row with the end position
        col = start.col
        if screenRowEnd > screenRowStart {
            col = 0
            if (screenRowEnd < screenRowStart) {
                col = terminal.cols
            }
        }
        maskPartialRow (path: path, row: screenRowEnd, colStart: col, colEnd: end.col)
        
        // now mask any full rows in between
        let fullRowCount = screenRowEnd - screenRowStart
        if fullRowCount > 1 {
            // Mask full rows up to the last row
            maskFullRows (path: path, rowStart: screenRowStart + 1, rowCount: fullRowCount-1)
        } else if fullRowCount < -1 {
            // Mask full rows up to the last row
            maskFullRows (path: path, rowStart: screenRowStart - 0, rowCount: fullRowCount+1)
        }
        
        maskLayer.path = path
    }
    
    func maskFullRows (path: CGMutablePath, rowStart: Int, rowCount: Int)
    {
        let cursorYOffset: CGFloat = 4
        let startY = frame.height  - (CGFloat (rowStart + rowCount) * cellDim.height - cellDim.delta - cursorYOffset)
        let pathRect = CGRect (x: 0, y: startY, width: frame.width, height: cellDim.height * CGFloat (rowCount))

        path.addRect (pathRect)
    }
    
    func maskPartialRow (path: CGMutablePath, row: Int, colStart: Int, colEnd: Int)
    {
        // -2 to get the top of the selection to fit over the top of the text properly
        // and to align with the cursor
        let cursorXPadding: CGFloat = 1
        let cursorYOffset: CGFloat = 4
        let startY = frame.height - cellDim.height - (CGFloat (row) * cellDim.height - cellDim.delta - cursorYOffset)
        let startX = CGFloat (colStart) * cellDim.width
        var pathRect: CGRect
        
        if colStart == colEnd {
            // basically the same as the cursor
            pathRect = CGRect (x: startX - cursorXPadding, y: startY, width: cellDim.width + (2 * cursorXPadding), height: cellDim.height)
        } else if (colStart < colEnd) {
            // start before the beginning of the start column and end just before the start of the next column
            pathRect =  CGRect (x: startX - cursorXPadding, y: startY, width: (CGFloat (colEnd - colStart) * cellDim.width) + (2 * cursorXPadding), height: cellDim.height);
        } else {
            // start before the beginning of the _end_ column and end just before the start of the _start_ column
            // note this creates a rect with negative width
            pathRect = CGRect (x: startX + cursorXPadding, y: startY, width: (CGFloat(colEnd - colStart) * cellDim.width) - (2 * cursorXPadding), height: cellDim.height)
        }
        path.addRect(pathRect)
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        // we do not want to steal hits, let the terminal view take them
        return nil
    }
}
#endif
