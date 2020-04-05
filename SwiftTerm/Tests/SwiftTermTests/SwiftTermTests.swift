import XCTest
@testable import SwiftTerm

final class SwiftTermTests: XCTestCase {
    class override func setUp() {
    }

    func run (cmd: String)
    {
        
    }
    
    func testExample() {
        var t = HeadlessTerminal ()
        t.run ("echo hello")
        
    }

    static var allTests = [
        ("testExample", testExample),
    ]
}
