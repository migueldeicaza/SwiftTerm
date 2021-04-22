//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 4/17/21.
//

import Foundation

extension UInt8 {
    // ascii codes 48 '0' through 57 '9' return as their digit
    var digit: Int? {
        guard self >= 48 && self <= 59 else {
            return nil
        }
        return Int(self) - 48
    }
}

extension ArraySlice where Element == UInt8 {
    func hasPrefix(_ string: String) -> Bool {
        var k = 0
        for char in string {
            guard k < count else { return false }
            
            if self[startIndex+k] != char.asciiValue {
                return false
            }
            
            k += 1
        }
        return true
    }
    
    func debugString(from: Int, to: Int) -> String {
        var nullTerminated = [UInt8](self[from..<to])
        nullTerminated.append(0)
        return String(cString: nullTerminated)
    }

    func debugString(around: Int) -> String {
        let end = around + 30
        let to = end < self.endIndex ? end : self.endIndex
        return debugString(from: around, to: to)
    }
}

extension Array where Element == UInt8 {
    // replace existing sequences of bytes corresponding to ascii encoding of from
    // with ascii encoding of to where nothing happens if strings are not pure 7-bit ascii
    mutating func replace(_ from: String, _ to: String) {
        // fast exit if first element of from is missing
        guard let first = from.first?.asciiValue,
              contains(first) else {
            return
        }
        
        // we can do work on ascii sequences
        guard from.allSatisfy({ $0.asciiValue != nil }),
              to.allSatisfy({ $0.asciiValue != nil }) else {
            return
        }
        let array1 = from.map({ $0.asciiValue! })
        let array2 = to.map({ $0.asciiValue! })
        
        // we just do naive search and replace on byte level
        var k = 0
        while k + array1.count <= count {
            var match = true
            for i in 0..<array1.count {
                if array1[i] != self[k+i] {
                    match = false
                    break
                }
            }
            if match {
                replaceSubrange(k..<(k+array1.count), with: array2)
            } else {
                k += 1
            }
        }
    }
}

extension ArraySlice where Element == UInt8 {
}
