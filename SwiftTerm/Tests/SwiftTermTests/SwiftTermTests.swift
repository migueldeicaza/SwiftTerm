import XCTest
@testable import SwiftTerm

final class SwiftTermTests: XCTestCase {
    static var queue: DispatchQueue!
    
    class override func setUp() {
        queue = DispatchQueue(label: "Runner", qos: .userInteractive, attributes: .concurrent, autoreleaseFrequency: .inherit, target: nil)
    }
    
    func run (cmd: String)
    {
        
    }
    
    func testExample() {
        let t = HeadlessTerminal (queue: SwiftTermTests.queue)
        t.process.startProcess()
        
        t.send ("~/cvs/esctest/esctest/esctest.py --include=test_BS --expected-terminal xterm --xterm-checksum=334\n")
        Thread.sleep(forTimeInterval: 10)
        print ("Done")
    }

    static var allTests = [
        ("testExample", testExample),
    ]
}
