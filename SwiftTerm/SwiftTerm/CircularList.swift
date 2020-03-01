//
//  CircularList.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/25/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation

enum ArgumentError : Error {
    case invalidArgument(String)
}

class CircularList<T> {
    
    var array: [T?]
    var startIndex: Int
    var length: Int {
        didSet {
            if (length > oldValue){
                for i in length..<length {
                    array [i] = nil
                }
            } else {
                array.removeSubrange(oldValue..<array.count)
            }
        }
    }
    
    var maxLength: Int {
        didSet {
            guard maxLength != oldValue else {
                let empty : T? = nil
                var newArray = Array.init(repeating: empty, count:Int(maxLength))
                let top = min (maxLength, array.count)
                for i in 0..<top {
                    newArray [i] = array [getCyclicIndex(i)]!
                }
                startIndex = 0
                array = newArray
                return
            }
        }
    }

    public init (maxLength: Int)
    {
        array = Array.init(repeating: nil, count: Int(maxLength))
        self.maxLength = maxLength
        self.length = 0
        self.startIndex = 0
    }
    
    func getCyclicIndex (_ index: Int) -> Int {
        return Int(startIndex + index) % (array.count)
    }
    
    subscript (index: Int) -> T {
        get {
            return array [getCyclicIndex(index)]!
        }
        set (newValue){
            array [getCyclicIndex(index)] = newValue
        }
    }
    
    func push (_ value: T)
    {
        array [getCyclicIndex(length)] = value
        length = length + 1
        if (length == array.count){
            startIndex = startIndex + 1
            if (startIndex == array.count) {
                startIndex = 0
            }
        }
    }
    
    @discardableResult
    func pop () -> T {
        let v = array [getCyclicIndex(length-1)]!
        length = length - 1
        return v
    }
    
    func splice (start: Int, deleteCount: Int, items: [T])
    {
        if (deleteCount > 0){
            for i in start..<(length-deleteCount) {
                array [getCyclicIndex(i)] = array [getCyclicIndex(i+deleteCount)]
            }
            length = length - deleteCount
        }
        if (items.count != 0){
            // add items
            let ic = items.count
            for i in (start...length-1).reversed () {
                array [getCyclicIndex(i + ic)] = array [getCyclicIndex(i)]
            }
            for i in 0..<ic {
                array [getCyclicIndex(start + i)] = items [i]
            }
            
            // Adjust length as needed
            if (Int(length) + ic > array.count){
                let countToTrim = length + items.count - array.count
                startIndex = startIndex + countToTrim
                length = array.count
            } else {
                length = length + items.count
            }
        }
    }
    
    func trimStart (count: Int)
    {
        let c = count > length ? length : count;
        startIndex = startIndex + c
        length = length - c
    }
    
    func shiftElements (start: Int, count: Int, offset: Int) throws
    {
        if (count < 0) {
            throw ArgumentError.invalidArgument("count < 0")
        }
        if (start < 0 || start > length){
            throw ArgumentError.invalidArgument("start is < 0 or > length")
        }
        if (start + offset < 0){
            throw ArgumentError.invalidArgument("Can not shift elements in list beyond index 0")
        }
        if (offset > 0){
            for i in (0..<count).reversed() {
                self [start + i + offset] = self [start + i]
            }
            let expandListBy = start + count + offset - length
            if (expandListBy > 0){
                length += expandListBy
                while (length > array.count){
                    length -= 1
                    startIndex += 1
                    // trimmed callback invoke
                }
            }
        } else {
            for i in 0..<count {
                self [start + i + offset] = self [start + i]
            }
        }
    }
    
    var isFull: Bool {
        get {
            return length == maxLength
        }
    }
}
