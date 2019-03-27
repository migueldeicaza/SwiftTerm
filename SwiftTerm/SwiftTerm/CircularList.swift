//
//  CircularList.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/25/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation

public protocol Defaultable {
    init ()
}

enum ArgumentError : Error {
    case invalidArgument(String)
}
class CircularList<T : Defaultable> {
    
    var array : [T]
    var startIndex : Int
    var length : Int {
        didSet {
            if (length > oldValue){
                for i in length..<length {
                    array [i] = T()
                }
            }
        }
    }
    
    var maxLength : Int {
        didSet {
            guard maxLength != oldValue else {
                var newArray = Array.init(repeating: T(), count:Int(maxLength))
                let top = min (maxLength, array.count)
                for i in 0..<top {
                    newArray [i] = array [GetCyclicIndex(i)]
                }
                startIndex = 0
                array = newArray
                return
            }
        }
    }

    init (maxLength : Int)
    {
        array = Array.init(repeating: T(), count: Int(maxLength))
        self.maxLength = maxLength
        self.length = 0
        self.startIndex = 0
    }
    
    func GetCyclicIndex (_ index : Int) -> Int {
        return Int(startIndex + index) % (array.count)
    }
    
    subscript (index: Int) -> T {
        get {
            return array [GetCyclicIndex(index)]
        }
        set (newValue){
            array [GetCyclicIndex(index)] = newValue
        }
    }
    
    func Push (value : T)
    {
        array [GetCyclicIndex(length)] = value
        length = length + 1
        if (length == array.count){
            startIndex = startIndex + 1
            if (startIndex == array.count) {
                startIndex = 0
            }
        }
    }
    
    func Pop () -> T {
        let v = array [GetCyclicIndex(length-1)]
        length = length - 1
        return v
    }
    
    func Splice (start : Int, deleteCount: Int, items: [T])
    {
        if (deleteCount > 0){
            for i in start..<(length-deleteCount) {
                array [GetCyclicIndex(i)] = array [GetCyclicIndex(i+deleteCount)]
            }
            length = length - deleteCount
        }
        if (items.count != 0){
            // add items
            let ic = items.count
            for i in (start...length-1).reversed () {
                array [GetCyclicIndex(i + ic)] = array [GetCyclicIndex(i)]
            }
            for i in 0..<ic {
                array [GetCyclicIndex(start + i)] = items [i]
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
    
    func TrimSart (count:Int)
    {
        let c = count > length ? length : count;
        startIndex = startIndex + c
        length = length - c
    }
    
    func ShiftElements (start : Int, count : Int, offset : Int) throws
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
    
    var IsFull : Bool {
        get {
            return length == maxLength
        }
    }
}
