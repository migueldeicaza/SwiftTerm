//
//  BufferLine.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/26/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation

public class BufferLine: CustomDebugStringConvertible {
    var isWrapped: Bool
    var data: [CharData]
    var images: [TerminalImage]?
    
    public init (cols: Int, fillData: CharData? = nil, isWrapped: Bool = false)
    {
        let fill = (fillData == nil) ? CharData.Null : fillData!
        data = Array.init(repeating: fill, count: cols)
        self.isWrapped = isWrapped
    }
    
    public init (from other: BufferLine)
    {
        data = other.data
        isWrapped = other.isWrapped
    }
    
    public var count: Int {
        get {
            return data.count
        }
    }
    
    public subscript (index : Int /*, callingMethod: String = #function */) -> CharData {
        get {
            // The x value in a buffer can point beyond the column, due to the way that we allow
            // buffer.x to grow (this is to support some wrapmodes and write on the edge)
            if index >= data.count {
                /* print ("Warning: the method \(callingMethod) has not been audited to clamp buffer.x to cols-1; fixing") */
                return data [data.count-1]
            }
            return data [index]
        }
        set(value) {
            if index >= data.count {
                /* print ("Warning: the method \(callingMethod) has not been audited to clamp buffer.x to cols-1; fixing") */
                data [data.count-1] = value
            } else {
                data [index] = value
            }
        }
    }
    
    public func getWidth (index: Int) -> Int {
        return Int (data [index].width)
    }
    
    /// Test whether contains any chars.
    public func hasContent (index: Int) -> Bool {
        data [index].code != 0 || data [index].attribute != CharData.defaultAttr;
    }
    
    public func hasAnyContent () -> Bool {
        for i in 0..<data.count {
            if hasContent(index: i) {
                return true
            }
        }
        return false
    }
    
    public func insertCells (pos: Int, n: Int, rightMargin: Int, fillData: CharData)
    {
        let len = rightMargin + 1
        //let len = data.count
        let pos = pos % len
        if n < len - pos {
            for i in (0..<len-pos-n).reversed() {
                data [pos+n+i] = data [pos+i]
            }
            for i in 0..<n {
                data [pos+i] = fillData
            }
        } else {
            for i in pos..<len {
                data [i] = fillData
            }
        }
    }
    
    public func deleteCells (pos: Int, n: Int, rightMargin: Int, fillData: CharData)
    {
        // let len = data.count
        let len = rightMargin + 1 
        let p = pos % len
        if n < len - p {
            for i in 0..<len-pos-n {
                data [pos+i] = self [pos+n+i]
            }
            for i in len-n..<len {
                data [i] = fillData
            }
        } else {
            for i in pos..<len {
                data [i] = fillData
            }
        }
    }
    
    public func replaceCells (start : Int, end : Int, fillData : CharData)
    {
        let length = data.count
        var idx = start
        while idx < end && idx < length {
            data [idx] = fillData
            idx += 1
        }
    }
    
    public func resize (cols : Int, fillData : CharData)
    {
        let len = data.count
        if len == cols {
            return
        }
        
        if cols > len {
            var newData = Array.init(repeating: fillData, count: cols)
            if len > 0 {
                for i in 0..<len {
                    newData [i] = data [i]
                }
            }
            data = newData
        } else {
            if cols > 0 {
                data = Array.init (data [0..<cols])
            } else {
                data = [CharData]()
            }
        }
    }
    
    public func fill (with: CharData)
    {
        for i in 0..<data.count {
            data [i] = with
        }
    }
    
    public func fill (with: CharData, atCol: Int, len: Int)
    {
        for i in 0..<len {
            data [i+atCol] = with
        }
    }
    
    public func copyFrom (line: BufferLine)
    {
        data = line.data
        isWrapped = line.isWrapped
    }
    
    /// Returns the trimmed length in terms of cells used from the BufferLine
    ///
    public func getTrimmedLength () -> Int
    {
        for i in (0..<data.count).reversed() {
            if data [i].code != 0 {
                return i + 1
            }
        }
        return 0
    }
    
    public func copyFrom (_ src: BufferLine, srcCol: Int, dstCol: Int, len: Int)
    {
        data.replaceSubrange(dstCol..<(dstCol+len), with: src.data [srcCol..<(srcCol+len)])
    }
    
    /// Returns the contents of the line as a string in the specified range
    /// - Parameter trimRight: if `true`, then this will trim any empty space from the right side
    /// of the terminal, otherwise, blanks will be included
    /// - Parameter startCol: the starting column to copy the data from, defaults toe zero if not provided
    /// - Parameter endCol: the end column (not included) to consume.  If the value -1, this copies all the way to the end
    /// - Returns: a string containing the contents of the BufferLine from [startCol..<endCol]
    public func translateToString (trimRight: Bool = false, startCol: Int = 0, endCol: Int = -1) -> String
    {
        var ec = endCol == -1 ? data.count : endCol
        if trimRight {
            ec = max (startCol, min (ec, getTrimmedLength()))
        }
        var result = ""
        for i in startCol..<max(ec,startCol) {
            result.append (data [i].getCharacter ())
        }
        return result
    }
    
    public func attach (image: TerminalImage) {
        if var imageArray = self.images {
            imageArray.append (image)
        } else {
            images = [image]
        }
    }
    
    public var debugDescription: String {
        get {
            translateToString()
        }
    }
}

