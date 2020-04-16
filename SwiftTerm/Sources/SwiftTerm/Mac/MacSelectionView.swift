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

@available(*, deprecated, message: "Don't use selection view any more")
class SelectionView: NSView {

    private let maskLayer: CAShapeLayer
    private let terminalView: TerminalView

    private var selection: SelectionService {
      terminalView.selection
    }
    private var defaultLineHeight: CGFloat {
      terminalView.lineHeight
    }
    
    public init(terminalView: TerminalView, frame: CGRect)
    {
        self.terminalView = terminalView
        self.maskLayer = CAShapeLayer()

        super.init(frame: frame)
        wantsLayer = true
        
        layer?.mask = maskLayer
        layer?.backgroundColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.8).cgColor
    }
    
    public required init? (coder: NSCoder)
    {
        abort()
    }

    func notifyScrolled (source terminal: Terminal)
    {
        update(with: terminal)
    }
    
    func update (with terminal: Terminal)
    {
        updateMask(with: terminal)
    }
    
    func updateMask (with terminal: Terminal)
    {
        // remove the prior mask
        maskLayer.path = nil
        
        maskLayer.frame = bounds
        let path = CGMutablePath ()
        guard let terminal = terminalView.terminal else {
          return
        }
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
        
        maskPartialRow (path: path, row: screenRowStart, colStart: start.col, colEnd: col, terminal: terminal)

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
        maskPartialRow (path: path, row: screenRowEnd, colStart: col, colEnd: end.col, terminal: terminal)
        
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
    
    func maskFullRows(path: CGMutablePath, rowStart: Int, rowCount: Int)
    {
        let startY = frame.height  - (CGFloat (rowStart + rowCount) * defaultLineHeight)
        let pathRect = CGRect (x: 0, y: startY, width: frame.width, height: defaultLineHeight * CGFloat (rowCount))

        path.addRect (pathRect)
    }
    
    func maskPartialRow(path: CGMutablePath, row: Int, colStart: Int, colEnd: Int, terminal: Terminal)
    {
        let startY = frame.height - (CGFloat(row + 1) * defaultLineHeight)
        var pathRect: CGRect
        let startOffset = self.terminalView.characterOffset (atRow: row + terminal.buffer.yDisp, col: colStart)
        let endOffset = self.terminalView.characterOffset (atRow: row + terminal.buffer.yDisp, col: colEnd)

        let width: CGFloat
        if colEnd == terminal.cols {
          width = frame.width - startOffset
        } else {
          width = endOffset - startOffset
        }

        if (colStart < colEnd) {
            // start before the beginning of the start column and end just before the start of the next column
            pathRect = CGRect (x: startOffset, y: startY, width: width, height: defaultLineHeight)
        } else {
            // start before the beginning of the _end_ column and end just before the start of the _start_ column
            // note this creates a rect with negative width
            pathRect = CGRect (x: startOffset, y: startY, width: width, height: defaultLineHeight)
        }
        path.addRect(pathRect)
    }
    
    override func hitTest (_ point: NSPoint) -> NSView? 
    {
        // we do not want to steal hits, let the terminal view take them
        return nil
    }
}
#endif
