//
//  main.swift
//  
//  This file has two purposes, one it provides the entry point for the
//  fuzzer, and second, it runs through a battery of tests from the fuzzer
//  they are run separately.
//
//  Sadly, there does not seem a way of making this file serve two purposes
//  at once without editing it every time.   If compiled for fuzzing, no
//  calls from the toplevel are allowed, but to exercise, you want that call.
//
//  Created by Miguel de Icaza on 4/24/20.
//
#if os(macOS)
import Foundation
import SwiftTerm

var queue = DispatchQueue(label: "Runner", qos: .userInteractive, attributes: .concurrent, autoreleaseFrequency: .inherit, target: nil)

// Fuzzer entry point
@_cdecl("LLVMFuzzerTestOneInput") public func fuzzMe(data: UnsafePointer<UInt8>, length: CInt) -> CInt{
    
    let h = HeadlessTerminal (queue: queue) { exitCode in }
    
    let t = h.terminal!
    t.silentLog = true
    let buffer = UnsafeBufferPointer(start: data, count: Int (length))
    let arr = Array(buffer)
    
    t.feed (byteArray: arr)
    return 0
}
#endif
