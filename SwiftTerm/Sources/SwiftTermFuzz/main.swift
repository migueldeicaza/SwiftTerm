//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 4/24/20.
//

import Foundation
import SwiftTerm

var queue = DispatchQueue(label: "Runner", qos: .userInteractive, attributes: .concurrent, autoreleaseFrequency: .inherit, target: nil)

// Fuzzer entry point
@_cdecl("LLVMFuzzerTestOneInput") public func fuzzMe(data: UnsafePointer<UInt8>, length: CInt) -> CInt{
    
    let h = HeadlessTerminal (queue: queue) { exitCode in }
    
    let t = h.terminal!
    
    let buffer = UnsafeBufferPointer(start: data, count: Int (length))
    let arr = Array(buffer)
    
    t.feed (byteArray: arr)
    return 0
}

// For manually testing stuff and use the Xcode debugger
func testInput (d: Data)
{
    let h = HeadlessTerminal (queue: queue) { exitCode in }
    var data : [UInt8] = []
    data.append(contentsOf: d)
    let t = h.terminal!

    t.feed (byteArray: data)
}


let url = URL(fileURLWithPath: "/Users/miguel/cvs/SwiftTerm/crash-98ce0e0b8d286505f093cca705ac3e2230d2bd80")
do {
    let data = try Data(contentsOf: url)
    testInput (d: data)
} catch {
    
}
print ("Happy!")
