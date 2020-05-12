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

// For manually testing stuff and use the Xcode debugger
func testInput (d: Data)
{
    let h = HeadlessTerminal (queue: queue) { exitCode in }
    var data : [UInt8] = []
    data.append(contentsOf: d)
    let t = h.terminal!
    t.silentLog = true
    t.feed (byteArray: data)
}

func testCrashes ()
{
    let crashes = [
        "crash-0a14a360e820c3801095d8bdbc130b3e18d55261",
        "slow-unit-16849a4439a9ada62a289f64d122b3f898410375",
        "slow-unit-be2210ab3bc792ab4932a65d0aecd1e3bbdb7db1",
        "slow-unit-cb67af81341f405834d562bcb49570e2d3a95348",
        "slow-unit-ff24adf923bfd5c9ccb4d58722c31c48d3f86480",

        "crash-166a328f85dd916e1602764a1792f95b7d749a0e",
        "crash-2b6b8631ea3cc418a069994de53e207da2d81230",
        "crash-509b3b6f6b74c483c515eecb5114f2f21f7ca576",
        "crash-698522a0a18e4fa7dcd0ee6b232d24cacecec07d",
        "crash-6f6c2b5c064f8ef4510305a3e04b2ef2c646b731",
        "crash-8876cfdf6927d0729ceccb6ae1c03da57c402eca",
        "crash-b60503f1c280209282018547ac732afd6d735dd9",
        "crash-ce788aaf77fa3219df3dea89f4a6771662402ebe",
        "crash-cf873cabbbf89413ae6f40ffc3f87e452cb9ed9b",
        "crash-e68d1073bb2f9140f95b4d9ad8dd076e5827f6c8",
        "crash-e6a7981c673480824152b1f8c948fac0d4a294f4",

        "crash-039a0b21c56b1e3a7a51056dd4f8daa9130c7312",
        "crash-36eb1fbfdb3a61e7b17b166d190ffd85ad9c80ab",
        "crash-4ba9dc95bc1c5d691fd9e80a4de72d65184e5c56",
        "crash-59fb9d3b7ab81c1782d26dfc69a962fae49ec449",
        "crash-64300317b2f97db7bfacfd77ba4d879e9726fd68",
        "crash-b926cdde789b73ff9680ff9ab643f13fa36c0571",
        "crash-c1147059ce893629e13289b43ae2b2ad1edcf44f",
        "crash-de2a0b4222547592208f7f85e2cd5b2730194daa",
        "crash-e1f2f0f2ef07d6d728316fa1bc336e6d1d699b99",
        "crash-ec47d21af677ee8eb18f91e150cdfb5d41d931c1",

        
    ]
    
    for crash in crashes {
        let url = URL(fileURLWithPath: "/Users/miguel/cvs/SwiftTerm/\(crash)")
        let data: Data
        do {
            print ("Running test \(crash)")
            data = try Data(contentsOf: url)
        } catch {
            print ("Caught error loading \(crash)")
            continue
        }

        testInput (d: data)
        
        print ("passed crash \(crash)")
    }
    print ("Happy!")
}

testCrashes()
