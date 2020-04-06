import XCTest
@testable import SwiftTerm

final class SwiftTermTests: XCTestCase {
    static var queue: DispatchQueue!
    
    class override func setUp() {
        queue = DispatchQueue(label: "Runner", qos: .userInteractive, attributes: .concurrent, autoreleaseFrequency: .inherit, target: nil)
        
        if !FileManager.default.fileExists(atPath: esctest) {
            esctest = "/Users/miguel/cvs/SwiftTerm/esctest/esctest/esctest.py"
        }
        // Ignore SIGCHLD
        signal (SIGCHLD, SIG_IGN)
    }
    
    static var esctest = "../esctest/esctest/esctest.py"
    var termConfig = "--expected-terminal xterm --xterm-checksum=334"
    var logfile = "/tmp/log"
    
    func runTester (_ includeRegexp: String) -> String?
    {
        let psem = DispatchSemaphore(value: 0)
        
        let t = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in
            Thread.sleep(forTimeInterval: 1)
            psem.signal ()
        }
        var args: [String] = ["--expected-terminal", "xterm", "--xterm-checksum=334", "--logfile", logfile]
        args += ["--include=\(includeRegexp)"]
        
        do {
            try FileManager.default.removeItem(atPath: "/tmp/log")
        } catch {
            // Ignore
        }
        t.process.startProcess(executable: SwiftTermTests.esctest, args: args, environment: nil)
        
        psem.wait ()
        
        do {
            let log = try String(contentsOf: URL(fileURLWithPath: logfile), encoding: .isoLatin1)
            if log.contains("0 tests failed ***") {
                return nil
            }
            if log.contains ("FAILED ***") {
                return log
            }
        } catch {
            return "Exception while loading \(logfile) \(error)"
        }
        return "Should have found test marker"
    }
    
    func testKnownGood() {
        let good = [
            "BS", "CUP", "DCS", "CHT", "CAT", "CHA", "DECFRA", "CR", "CUB", "CUD", "CUD", "CUF", "CUP",
            "CUU", "DCS", "DECERA", "DECDSR", "DECSTBM", "DECSTR", "HPR", "HTS", "TBC", "SOS", "VPR", "PM"]
        
        let expr = "test_(\(good.joined(separator: "|")))"
        
        XCTAssertNil(runTester (expr))
    }
    
    func xtestFailuresOnHeadless ()
    {
        XCTAssertNil(runTester ("test_DECCRA"))
        XCTAssertNil(runTester ("test_HPA"))
    }

    //
    // Only add tests here when the only failure is the ISO protection tests, and add the passing
    // tests manually
    //
    func testIsoProtection ()
    {
        XCTAssertNil(runTester ("test_SM_(IRM|RM_DoesNotWrapUnlessCursorAtMargin|IRM_TruncatesAtRightMargin)"))
        XCTAssertNil(runTester ("test_ECH_(ExplicitParam|IgnoresScrollRegion|OutsideScrollRegion)"))
        XCTAssertNil(runTester ("test_EL_(0|1|2|Default|IgnoresScrollRegion|doesNotRespectDECProtection)"))
    }
    
    static var allTests = [
        ("testKnownGood", testKnownGood),
        //("testMarkerMissing", testFailuresOnHeadless),
        ("testIsoProtection", testIsoProtection),
    ]
}
