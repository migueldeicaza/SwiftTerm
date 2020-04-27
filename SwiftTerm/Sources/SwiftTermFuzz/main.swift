//
//  main.swift
//  
//  This file has two purposes, one it provides the entry point for the
//  fuzzer, and second, it runs through a battery of tests from the fuzzer
//  they are run separately
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

func testCrashes ()
{
    let crashes = [
        "crash-d289c73f90080308c483da206a97ccd3d511c749",
        "crash-36c36f0f7ad470e606763d49a75736fa0ee04d84",
        "crash-f6066c221374836a036f30e106489754549966c6",
        "crash-d214965096e8bbec69a90933332420253acad416",
        "crash-586179f846efe82d17ab7eac4dd05d37142a1698",
        "crash-4a6396e7ddc51a06e57a3e4998eb07df7274fd3f",
        "timeout-c7784cb0fcb8cd15fe71cd670e64a8bd6800a499",
        "crash-1166668d31fc739b2e728ae818329cedd52f46dd",
        "crash-89fbe8f483d3870f127aae78034fac288f2ca378",
        "crash-0bd46f43af414faa30387902d2b9f797d84e4815",
        "crash-c77af4da2eeae0c8167ae8c1aa00cde34d13365b",
        "slow-unit-c616385dc739fd46b2cdbe69cbf6d296b648a2c4",
        "crash-9722bf1001188e1582b36b017d35ede811d930c7",
        "crash-2cb86239bead50163f9673d077fff9d31d991f76",
        "crash-05d3371777486e9c21da9edaf37b64852b6a59ac",
        "crash-11e430733f1cb1dc91db8b2f0bf3fc6d47eae752",
        "crash-2a107abe9c27809af563e78ec5885a468b17cc85",
        "crash-40b78df2bca60d1f9bcd04719c671e9fb3ed4ac0",
        "crash-4ed9cd0097d80a3cd2a03a42f793f8bbcb7cb564",
        "crash-6eff71f43731490fbf02cfae5603d1c3d87007ac",
        "crash-8ec6dcd7ed7a5979b553a487333765aae0ca083b",
        "crash-98ce0e0b8d286505f093cca705ac3e2230d2bd80",
        "crash-b725370fac397e8db4818587957571938ac47163",
        "crash-bf4aad6f8ca36da6dfc61ba6a5724ef98df662c5",
        "crash-cebfabfae04b3fe4a6959b089d87e6b9cfe8708d",
        "crash-d4dea30dde6d0e9cbd3d8338a34c3b46867bfe19",
        "crash-dd110df2dae9279f883536052f91751ceb197196",
        "crash-e34608d8acd5a503bde845ba56cb42004e348b3a",
        "crash-e7023d5355113a5967bef15c34611e6ec177b312",
        "crash-f733f8bc1beecddd58e33bbd04fd43cf21a68cd0",
    ]
    
    for crash in crashes {
        let url = URL(fileURLWithPath: "/Users/miguel/cvs/SwiftTerm/\(crash)")
        do {
            print ("Running test \(crash)")
            let data = try Data(contentsOf: url)
            testInput (d: data)
        } catch {
            print ("Caught error in test \(crash)")
        }
        print ("passed crash \(crash)")
    }
    print ("Happy!")
}

//testCrashes()
