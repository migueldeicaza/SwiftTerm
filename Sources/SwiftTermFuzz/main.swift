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
        "timeout-a9539e3703587af2fe071ece51e17fa168ac6d2d",
        "timeout-c7784cb0fcb8cd15fe71cd670e64a8bd6800a499",
        "crash-dda8a48c04d1461c3b1cf179ae2f6367c8d4ec7b",
        "crash-98664e18a4536bf5b581833b4316b19d30d1fc50",
        "crash-dd8d21f5b5b50b1f44c46b7d62079317b5dfba92",
        "crash-8be177cdaef621d1ca821effcea130e4a0367435",
        "crash-78efb40b60415603381a78d4658d516daacbf734",
        "crash-1a406725874a3abfd50d2f0afc5763b942eacb0a",
        "crash-f7cfa2f5bdd849060e3801853ca4d3b64e0c03b0",
        "crash-11101292c68ab9046a2d9cbb8590ceaf797eb076",
        "crash-3fdb4cba0474412d2c3dc07f8d15936b420d7a81",
        "crash-0c3dd84afd1b451fb0fdd4709851fab1c8082fae",
        "crash-36b4fd080b9c7dd54b231a9325200dcc9e71a342",
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
        let url = URL(fileURLWithPath: "/Users/miguel/cvs/SwiftTerm/results-fuzzer/\(crash)")
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

testCrashes()
