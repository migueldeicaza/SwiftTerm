//
//  BufferLine.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/26/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation

/// BufferLines represents a single line of text displayed on the terminal

public final class BufferLine: CustomDebugStringConvertible {
    public enum RenderLineMode {
        /// Render each character using a single cell
        case single
        /// Render character using two cells
        case doubleWidth
        /// Render the top of a character using two cells
        case doubledTop
        /// Renders the bottom of a character, using two cells
        case doubledDown
    }
    var isWrapped: Bool
    var renderMode: RenderLineMode = .single
    private var data: UnsafeMutableBufferPointer<CharData>
    private var dataSize: Int

    private var fillCharacter: CharData //used to initialise data

    var images: [TerminalImage]?

    public init (cols: Int, fillData: CharData? = nil, isWrapped: Bool = false)
    {
        self.fillCharacter = (fillData == nil) ? CharData.Null : fillData!
        let buf = UnsafeMutableBufferPointer<CharData>.allocate(capacity: cols)
        buf.initialize(repeating: fillCharacter)
        data = buf
        dataSize = cols
        self.isWrapped = isWrapped
    }

    public init (from other: BufferLine)
    {
        fillCharacter = other.fillCharacter
        isWrapped = other.isWrapped
        renderMode = other.renderMode
        images = other.images
        let otherSize = other.dataSize
        let buf = UnsafeMutableBufferPointer<CharData>.allocate(capacity: otherSize)
        #if os(Linux) || os(Windows)
        for i in 0..<otherSize {
            buf.initializeElement(at: i, to: other.data[i])
        }
        #else
        _ = buf.initialize(fromContentsOf: other.data[0..<otherSize])
        #endif
        
        data = buf
        dataSize = otherSize
    }

    deinit {
        data.deinitialize()
        data.deallocate()
    }

    /// Returns the number of CharData cells in this row
    public var count: Int {
        get {
            return dataSize
        }
    }

    public func getData() -> [CharData] {
        Array(data[0..<dataSize])
    }

    /// Accesses the CharIndex at the specified position
    public subscript (index : Int /*, callingMethod: String = #function */) -> CharData {
        get {
            // The x value in a buffer can point beyond the column, due to the way that we allow
            // buffer.x to grow (this is to support some wrapmodes and write on the edge)
            let dataSize = self.dataSize
            if index >= dataSize {
                /* print ("Warning: the method \(callingMethod) has not been audited to clamp buffer.x to cols-1; fixing") */
                return data [dataSize-1]
            }
            return data [index]
        }
        set(value) {
            if index >= dataSize {
                // All bugs I was aware of have been handled, but keep this message here to
                // help future refactorings.
                print("BufferLine: You passed an index out of range, adjusting to prevent crash, but you should debug")
                data[dataSize-1] = value
            } else {
                data[index] = value
            }
        }
    }

    /// Returns the number of character cells the element at this position occupies.
    public func getWidth (index: Int) -> Int {
        return Int (data [index].width)
    }

    func clear(with attribute: Attribute) {
        let empty = CharData(attribute: attribute)
        data.update(repeating: empty)
        images = nil
    }
    /// Test whether contains any chars.
    public func hasContent (index: Int) -> Bool {
        data [index].code != 0 || data [index].attribute != CharData.defaultAttr;
    }

    /// True if the buffer line has any values stored in it, false otherwise
    public func hasAnyContent () -> Bool {
        for i in 0..<dataSize {
            if hasContent(index: i) {
                return true
            }
        }
        return false
    }

    /// Repeatedly inserts a CharData elements into the buffer line.
    /// - Parameters:
    ///  - pos: position where to insert the data
    ///  - n: the number of times the data is inserted
    ///  - fillData: the data that will be filled into the line
    public func insertCells (pos: Int, n: Int, rightMargin: Int, fillData: CharData)
    {
        let len = rightMargin + 1
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

    /// Removes the cells at the specified position, shifting data leftwards
    public func deleteCells (pos: Int, n: Int, rightMargin: Int, fillData: CharData)
    {
        let len = rightMargin + 1
        let p = pos % len
        if n < len - p {
            for i in 0..<len-pos-n {
                data [pos+i] = data [pos+n+i]
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

    /// Replaces the cells in the start to end range with the specified fill data
    public func replaceCells (start: Int, end: Int, fillData : CharData)
    {
        let length = dataSize
        var idx = start
        while idx < end && idx < length {
            data [idx] = fillData
            idx += 1
        }
    }

    /// Resizes the buffer line, if the new size is larger, the empty region is filled with
    /// `fillData` values, if it is smaller, the data is trimmed
    public func resize (cols: Int, fillData: CharData)
    {
        let len = dataSize
        if len == cols {
            return
        }

        if cols > len {
            let newBuf = UnsafeMutableBufferPointer<CharData>.allocate(capacity: cols)
            
            // Copy existing data
#if os(Linux) || os(Windows)
            if len > 0 {
                for i in 0..<len {
                    newBuf.initializeElement(at: i, to: data[i])
                }
            }
#else
            if len > 0 {
                _ = newBuf.initialize(fromContentsOf: data[0..<len])
            }
#endif
            
            // Fill remainder with fillData
            for i in len..<cols {
                newBuf.initializeElement(at: i, to: fillData)
            }
            data.deallocate()
            data = newBuf
            dataSize = cols
        } else {
            if cols > 0 {
                let newBuf = UnsafeMutableBufferPointer<CharData>.allocate(capacity: cols)
#if os(Linux) || os(Windows)
                for i in 0..<cols {
                    newBuf.initializeElement(at: i, to: data[i])
                }
#else
                _ = newBuf.initialize(fromContentsOf: data[0..<cols])
#endif
                data.deinitialize()
                data.deallocate()
                data = newBuf
                dataSize = cols
            } else {
                data.deinitialize()
                data.deallocate()
                data = UnsafeMutableBufferPointer<CharData>.allocate(capacity: 0)
                dataSize = 0
            }
        }
    }

    /// Fills the entire bufferline with the specified ``CharData``
    public func fill (with: CharData)
    {
        data.update(repeating: with)
    }

    /// Fills the specified region of the bufferline with the specified ``CharData``
    /// - Parameters:
    ///  - with: the ``CharData`` to fill the region with
    ///  - atCol: starting column to fill at
    ///  - len: number of columns to fill
    public func fill (with: CharData, atCol: Int, len: Int)
    {
        for i in 0..<len {
            data [i+atCol] = with
        }
    }

    /// Fills the current BufferLine with the contents of another BufferLine.
    public func copyFrom (line: BufferLine)
    {
        let srcSize = line.dataSize
        if data.count < srcSize {
            data.deinitialize()
            data.deallocate()
            let newBuf = UnsafeMutableBufferPointer<CharData>.allocate(capacity: srcSize)
#if os(Linux) || os(Windows)
            for i in 0..<srcSize {
                newBuf.initializeElement(at: i, to: line.data[i])
            }
#else
            _ = newBuf.initialize(fromContentsOf: line.data[0..<srcSize])
#endif
            data = newBuf
        } else {
            for i in 0..<srcSize {
                data[i] = line.data[i]
            }
        }
        dataSize = srcSize
        isWrapped = line.isWrapped
    }

    /// Returns the trimmed length in terms of cells used from the BufferLine
    ///
    public func getTrimmedLength () -> Int
    {
        for i in (0..<dataSize).reversed() {
            if data [i].code != 0 {
                return i + Int(data[i].width)
            }
        }
        return 0
    }

    /// Copies a range of CharData elements from another bufferline into this one
    /// - Parameters:
    ///  - src: the buffer line to copy from
    ///  - srcCol: the column index in the other buffer line
    ///  - dstCol: the destination in this buffer line
    ///  - len: the number of elements to copy
    public func copyFrom (_ src: BufferLine, srcCol: Int, dstCol: Int, len: Int)
    {
        if src === self && srcCol > dstCol {
            // Overlapping forward copy: go left-to-right (already safe)
            for i in 0..<len {
                data[dstCol + i] = data[srcCol + i]
            }
        } else if src === self && srcCol < dstCol {
            // Overlapping backward copy: go right-to-left to avoid clobbering
            for i in stride(from: len - 1, through: 0, by: -1) {
                data[dstCol + i] = data[srcCol + i]
            }
        } else {
            for i in 0..<len {
                data[dstCol + i] = src.data[srcCol + i]
            }
        }
    }

    /// Returns the contents of the line as a string in the specified range
    /// - Parameter trimRight: if `true`, then this will trim any empty space from the right side
    /// of the terminal, otherwise, blanks will be included
    /// - Parameter startCol: the starting column to copy the data from, defaults toe zero if not provided
    /// - Parameter endCol: the end column (not included) to consume.  If the value -1, this copies all the way to the end
    /// - Returns: a string containing the contents of the BufferLine from [startCol..<endCol]
    public func translateToString (trimRight: Bool = false, startCol: Int = 0, endCol: Int = -1, skipNullCellsFollowingWide: Bool = false, characterProvider: ((CharData) -> Character)? = nil) -> String
    {
        var ec = endCol == -1 ? dataSize : endCol
        if trimRight {
            ec = max (startCol, min (ec, getTrimmedLength()))
        }
        let limit = max(ec, startCol)
        if !skipNullCellsFollowingWide {
            var result = ""
            for i in startCol..<limit {
                let character = characterProvider?(data [i]) ?? data [i].getCharacter ()
                result.append (character)
            }
            return result
        }
        var result = ""
        var idx = startCol
        while idx < limit {
            if idx > 0 && data [idx].code == 0 && data [idx-1].width == 2 {
                idx += 1
                continue
            }
            let cell = data [idx]
            let character = characterProvider?(cell) ?? cell.getCharacter ()
            result.append (character)
            if cell.width == 2 {
                let nextIndex = idx + 1
                if nextIndex < limit && data [nextIndex].code == 0 {
                    idx += 2
                    continue
                }
            }
            idx += 1
        }
        return result
    }

    /// Attaches the specified terminal image to this buffer line.
    /// This method is internal - use Buffer.attachImage() to attach images with proper tracking.
    func attach (image: TerminalImage) {
        if var imageArray = self.images {
            imageArray.append (image)
            images = imageArray
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
