//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 3/22/20.
//
#if os(macOS)
import Foundation
import AppKit

public class TerminalDebugView: NSView {
    var terminalView: TerminalView
    var font = NSFont(name: "Lucida Sans Typewriter", size: 8) ?? NSFont(name: "Courier", size: 8)!
    var height: CGFloat
    var dbg: NSTextField

    private struct DebugRow {
        let logicalIndex: Int
        let cyclicIndex: Int
        let isDisplayRow: Bool
        let isBaseRow: Bool
        let physicalText: String
        let logicalText: String
    }

    private struct DebugSnapshot {
        let status: String
        let rows: [DebugRow]
    }

    private var latestSnapshot: DebugSnapshot?
    
    func computeCellDimensions () -> CGRect
    {
        let line = CTLineCreateWithAttributedString (NSAttributedString (string: "W", attributes: [NSAttributedString.Key.font: font]))
        
        return CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    }

    public func update ()
    {
        latestSnapshot = copyDebugSnapshot()
        setNeedsDisplay(frame)
        dbg.stringValue = latestSnapshot?.status ?? "WAITING"
    }
    
    public init (frame: CGRect, terminal: TerminalView)
    {
        self.terminalView = terminal
        dbg = NSTextField(frame: NSRect (x: 0, y: 8, width: frame.width, height: 14))
        
        dbg.font = font
        dbg.stringValue = "WAITING"
        height = 0
        super.init (frame: frame)
        terminalView.debug = self
        height = computeCellDimensions ().height
        addSubview(dbg)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func copyLine(_ line: BufferLine?, cols: Int) -> String
    {
        guard let line else { return "<empty>" }
        var result = ""
        result.reserveCapacity(cols)
        for col in 0..<min(cols, line.count) {
            let cell = line.packedView(at: col)
            result.append(cell.code == 0 ? " " : cell.getCharacter())
        }
        return result
    }

    private func copyDebugSnapshot() -> DebugSnapshot
    {
        terminalView.withTerminal { terminal in
            let buffer = terminal.buffer
            let physicalLines = buffer.lines.getArray()
            let rows = (0..<buffer.lines.maxLength).map { row in
                DebugRow(
                    logicalIndex: row,
                    cyclicIndex: buffer.lines.debugGetCyclicIndex(row),
                    isDisplayRow: row == buffer.yDisp,
                    isBaseRow: row == buffer.yBase,
                    physicalText: copyLine(
                        physicalLines.indices.contains(row) ? physicalLines[row] : nil,
                        cols: terminal.cols),
                    logicalText: copyLine(buffer.lines[row], cols: terminal.cols))
            }
            let status = "x: \(buffer.x) y: \(buffer.y) yDisp: \(buffer.yDisp) " +
                "yBase: \(buffer.yBase) clc: \(physicalLines.count) " +
                "startIndex: \(buffer.lines.getStartIndex())"
            return DebugSnapshot(status: status, rows: rows)
        }
    }

    func getDebugString (text: String, prefix: String = "", hilight: Bool) -> NSAttributedString
    {
        let res = NSMutableAttributedString ()
        
        let nsattr: [NSAttributedString.Key:Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .backgroundColor: NSColor.white
        ]

        let selLineAttr: [NSAttributedString.Key:Any] = [
            .font: font,
            .foregroundColor: NSColor.red,
            .backgroundColor: NSColor.black
        ]
        
        if hilight {
            print ("here")
        }
        res.append (NSAttributedString (string: prefix, attributes: (hilight ? selLineAttr : nsattr)))
        res.append (NSAttributedString(string: text, attributes: nsattr))
        return res
    }
    
    public override func draw(_ dirtyRect: NSRect) {
        NSColor.white.set ()
        bounds.fill()
        
        //print ("Dirty rect is: \(dirtyRect)")
        NSColor.black.set ()
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        context.saveGState()
        
        let baseLine = frame.height - height
        let snapshot = latestSnapshot ?? copyDebugSnapshot()
        latestSnapshot = snapshot
        for row in snapshot.rows {
            let y = row.logicalIndex
            context.textPosition = CGPoint (x: 0, y: baseLine - (height + CGFloat (y) * height))
            let flag = row.isDisplayRow ? "D" : " "
            let yb = row.isBaseRow ? "B" : " "
            let istr = String (format: "%03d", y)
            let cstr = String(format: "%03d", row.cyclicIndex)
            
            let attrLine = getDebugString(
                text: row.physicalText,
                prefix: "[\(istr):\(cstr)]\(flag)\(yb)", hilight: false)
            let ctline = CTLineCreateWithAttributedString(attrLine)
            CTLineDraw(ctline, context)
            context.drawPath(using: .fillStroke)

            let attrLine2 = getDebugString(
                text: row.logicalText,
                prefix: "[\(istr)]\(flag)\(yb)", hilight: false)
            let ctline2 = CTLineCreateWithAttributedString(attrLine2)
            CTLineDraw(ctline2, context)
            context.drawPath(using: .fillStroke)

        }
        context.restoreGState()
    }
}
#endif
