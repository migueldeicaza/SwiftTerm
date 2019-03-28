//
//  BufferLine.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/26/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation

class BufferLine {
    var isWrapped : Bool
    var data : [CharData]
    
    init (cols:Int, fillData : CharData?, isWrapped : Bool = false)
    {
        let fill = (fillData == nil) ? CharData.Null : fillData!
        data = Array.init(repeating: fill, count: cols)
        self.isWrapped = isWrapped
    }
    
    subscript (index : Int) -> CharData {
        get {
            return data [index]
        }
        set(value) {
            data [index] = value
        }
    }
    
    func GetWidth (index : Int) -> Int {
        return Int (data [index].Width)
    }
    
    func InsertCells (pos :Int, n : Int, fillData : CharData)
    {
        let len = data.count
        let pos = pos % len
        if (n < len - pos){
            for i in (0..<len-pos-n).reversed() {
                data [pos+n+i] = data [pos+i]
            }
            for i in pos..<len {
                data [i] = fillData
            }
        }
    }
    
    func DeleteCells (pos : Int, n : Int, fillData : CharData)
    {
        let len = data.count
        let p = pos % len
        if (n < len - p){
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
    
    func ReplaceCells (start : Int, end : Int, fillData : CharData)
    {
    
        let top = min (end, data.count)
        for i in start..<top {
            data [i] = fillData
        }
    }
    
    func Resize (cols : Int, fillData : CharData)
    {
        let len = data.count
        if (len == cols) {
            return
        }
        
        if (cols > len){
            var newData = Array.init(repeating: fillData, count: cols)
            if (len > 0){
                for i in 0..<len {
                    newData [i] = data [i]
                }
            }
        } else {
            if (cols > 0){
                data = Array.init (data [0..<cols])
            } else {
                data = [CharData]()
            }
        }
    }
}

