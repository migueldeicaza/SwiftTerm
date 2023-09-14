//
// FuzzerTests: runs the tests that feed the fuzzer inputs
//  
//
//  Created by Miguel de Icaza on 4/29/21.
//
#if os(macOS)
import Foundation
import XCTest
import Foundation

@testable import SwiftTerm

final class FuzzerTests: XCTestCase {
    var queue = DispatchQueue(label: "Runner", qos: .userInteractive, attributes: .concurrent, autoreleaseFrequency: .inherit, target: nil)
    
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

    // These do not really test crashes, they are just slow:
    //        "slow-unit-0c2689cd9f79cf89245ff42a5c312ebf0742e5be",
    //        "slow-unit-16849a4439a9ada62a289f64d122b3f898410375",
    //        "slow-unit-be2210ab3bc792ab4932a65d0aecd1e3bbdb7db1",
    //        "slow-unit-cb67af81341f405834d562bcb49570e2d3a95348",
    //        "slow-unit-ff24adf923bfd5c9ccb4d58722c31c48d3f86480",

    func test (_ crash: String) {
        var file: String
        let t1 = "/Users/miguel/cvs/SwiftTerm/\(crash)"
        let t2 = "/Users/miguel/cvs/SwiftTermFuzzerResults/\(crash)"
        
        if FileManager.default.fileExists(atPath: t1) {
            file = t1
        } else if FileManager.default.fileExists(atPath: t2) {
            file = t2
        } else {
            print ("Data file \(crash) not found in the peer directory or this directory")
            return
        }
        let url = URL(fileURLWithPath: file)
        let data: Data
        do {
            print ("Running test \(crash)")
            data = try Data(contentsOf: url)
        } catch {
            print ("Failure to load the data file \(crash)")
            return
        }

        testInput (d: data)
    }
    
    func testCrashes ()
    {
        // This is because I do not include the crashes on github
        // I need to put them somewhere
        return
        test ("timeout-cba40aaea6bc68c8dfb3672bc433337e07f792a2")
        test ("timeout-041483b16f77af768280b38a3b80a718bfd56c2b")
        test ("timeout-046c83ffd57883a21160651a6c765def56fc4b90")
        test ("slow-unit-3956bd3929f8b05f523b9780c3b48e8175550302")
        test ("slow-unit-99b162e9e3ea46e7c9c5d601ef1f5b232becce49")
        test ("crash-80a2f29e6efcd55477f3275434cf45f241777573")
        test ("crash-661c9f1d29d682c0d7fd640fa57266b24c9a8ed2")
        test ("crash-a455aeceaf7374464ee888fbf85691ef91ab6480")
        test ("crash-a58b5a38135bd7ffadad8b420ab8dcd0c3e4a1bd")
        test ("crash-840102113e655342bfc30d2749406756a6e812d3")
        test ("crash-654c8421b816426f584c3347a72cd2e869602ed5")
        test ("crash-c6f850474ed073bb5b2e032c13d66819e68acc88")
        test ("crash-a18a4cccc2a2b1c6f14ea804d15dd7f93682abf2")
        test ("crash-b274a2639cd901a107778760708bb759c52086f8")
        test ("crash-9ff2abe9af46be74ca774b8d684e1df0737aa0bf")
        test ("crash-fb6fa24871a603f7920dd24d467c449ac5b8d893")
        test ("crash-f8e22628b8a2bb06d06fa9c064fe3a7363c35bde")
        test ("crash-dc9cf799322b1223cb9a0e40283cb61812d50fbb")
        test ("crash-c5c6e20dacfbb1a72599f8e135321a343d0dc2c6")
        test ("crash-d38b59abae508cafa02c586d1706cf734977e6eb")
        test ("crash-96e8d67b4e139f9eaebb950c5d25b7d5bd456359")
        test ("crash-be2c5a1d40465efe36dd95771161829427dd6356")
        test ("crash-3154715068e3ec98c7b425cc0fe56c1dbd1e1f58")
        test ("crash-41df255a79feb00f8ded38dac7a51065a2758977")
        test ("crash-45157239bc429db89546e2f0fea38b26f608b8d9")
        test ("crash-2f5d273ae2f2bb95152905486bd9bfd8afa83c02")
        test ("crash-17381a13c18b7bda011f260e38952fb8fb7e4616")
        test ("crash-0a14a360e820c3801095d8bdbc130b3e18d55261")
        test ("crash-166a328f85dd916e1602764a1792f95b7d749a0e")
        test ("crash-2b6b8631ea3cc418a069994de53e207da2d81230")
        test ("crash-509b3b6f6b74c483c515eecb5114f2f21f7ca576")
        test ("crash-698522a0a18e4fa7dcd0ee6b232d24cacecec07d")
        test ("crash-6f6c2b5c064f8ef4510305a3e04b2ef2c646b731")
        test ("crash-8876cfdf6927d0729ceccb6ae1c03da57c402eca")
        test ("crash-b60503f1c280209282018547ac732afd6d735dd9")
        test ("crash-ce788aaf77fa3219df3dea89f4a6771662402ebe")
        test ("crash-cf873cabbbf89413ae6f40ffc3f87e452cb9ed9b")
        test ("crash-e68d1073bb2f9140f95b4d9ad8dd076e5827f6c8")
        test ("crash-e6a7981c673480824152b1f8c948fac0d4a294f4")
        test ("crash-039a0b21c56b1e3a7a51056dd4f8daa9130c7312")
        test ("crash-36eb1fbfdb3a61e7b17b166d190ffd85ad9c80ab")
        test ("crash-4ba9dc95bc1c5d691fd9e80a4de72d65184e5c56")
        test ("crash-59fb9d3b7ab81c1782d26dfc69a962fae49ec449")
        test ("crash-64300317b2f97db7bfacfd77ba4d879e9726fd68")
        test ("crash-b926cdde789b73ff9680ff9ab643f13fa36c0571")
        test ("crash-c1147059ce893629e13289b43ae2b2ad1edcf44f")
        test ("crash-de2a0b4222547592208f7f85e2cd5b2730194daa")
        test ("crash-e1f2f0f2ef07d6d728316fa1bc336e6d1d699b99")
        test ("crash-ec47d21af677ee8eb18f91e150cdfb5d41d931c1")
    }
    
    func testTimeouts ()
    {
        test ("timeout-44d56090b5e02248f1d90d2ff371d27abaae532f")
        test ("timeout-8244fb7b31c904aff447c0456cebd79688f142db")
    }
    
    static var allTests = [
        ("testFuzzerCrashes", testCrashes),
        ("testFuzzerTimeouts", testTimeouts)
    ]
}
#endif
