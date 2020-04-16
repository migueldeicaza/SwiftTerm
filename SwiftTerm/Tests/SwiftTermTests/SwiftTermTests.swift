import XCTest
@testable import SwiftTerm

final class SwiftTermTests: XCTestCase {
    static var queue: DispatchQueue!
    
    class override func setUp() {
        queue = DispatchQueue(label: "Runner", qos: .userInteractive, attributes: .concurrent, autoreleaseFrequency: .inherit, target: nil)
        
        if !FileManager.default.fileExists(atPath: esctest) {
            esctest = "/Users/miguel/cvs/esctest/esctest/esctest.py"
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
            if FileManager.default.fileExists (atPath: "/tmp/log") {
                try FileManager.default.removeItem(atPath: "/tmp/log")
            }
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
            "BS", "CUP", "DCS", "CHT", "CAT", "CHA", "CR", "CUB", "CUD", "CUD", "CUF", "CUP",
            "CUU", "DCS", "DECERA", "DECDSR", "DECFRA", "DECSTBM", "DECSTR", "HPR", "HTS", "TBC", "SOS", "VPR", "PM",
            "RM",
        
            // These are partial successes, with known bugs, but let us not regress the ones that pass
            
            // DCH, passes 4, 2 failures
            "DCH_ExplicitParam", "DCH_RespectsMargins", "DCH_WorksOutsideTopBottomMargin", "DCH_DefaultParam",
                // Failing:
                // test_DCH_DeleteAllWithMargin
                // test_DCH_DoesNothingOutsideLeftRightMargi
            
            // DECALN, 2 pass, 2 fail
            "DECALN_FillsScreen", "DECALN_MovesCursorHome",
                // Failing:
                // test_DECALN_ClearsMargin
            
            // DECBI, 1 passes, 4 fail
            "DECBI_NoWrapOnLeftEdge",
                // Failing:
                // test_DECBI_Basi
                // test_DECBI_LeftOfMargi
                // test_DECBI_Scroll
                // test_DECBI_WholeScreenScroll
            
            // DECCRA, 8 pass, 2 fail
            "DECCRA_cursorDoesNotMove", "DECCRA_defaultValuesInDest", "DECCRA_defaultValuesInSource",
            "DECCRA_destinationPartiallyOffscreen", "DECCRA_ignoresMargins", "DECCRA_invalidSourceRectDoesNothing",
            "DECCRA_nonOverlappingSourceAndDest", "DECCRA_overlappingSourceAndDest",
                // Failing:
                // test_DECCRA_overlyLargeSourceClippedToScreenSiz
                // test_DECCRA_respectsOriginMode
            
            // DECDC, 6 pass, 1 fail
            "DECDC_CursorWithinTopBottom", "DECDC_DefaultParam", "DECDC_DeleteAll",
            "DECDC_DeleteAllWithLeftRightMargins", "DECDC_DeleteWithLeftRightMargin", "DECDC_ExplicitParam",
                // Failing:
                // test_DECDC_IsNoOpWhenCursorBeginsOutsideScrollRegio
            
            // DECFI, 1 pass, 6 fail
            "DECFI_NoWrapOnRightEdge",
                // Failing:
                // test_DECFI_Basi
                // test_DECFI_RightOfMargi
                // test_DECFI_Scroll
                // test_DECFI_WholeScreenScroll
            
            // DECIC, 5 pass, 2 fail
            "DECIC_ScrollEntirelyOffRightEdge",
            "DECIC_ScrollOffRightEdge",
            "DECIC_ScrollOffRightMarginInScrollRegion",
            "DECIC_DefaultParam",
            "DECIC_ExplicitParam",
                // Failing:
                // test_DECIC_CursorWithinTopBotto
                // test_DECIC_IsNoOpWhenCursorBeginsOutsideScrollRegio

            // DECRQSS, 4 pass, 2 fail
            "DECRQSS_SGR",
            "DECRQSS_DECSTBM",
            "DECRQSS_DECSLRM",
            "DECRQSS_DECSCL",
                // Failing:
                // test_DECRQSS_DECSC
                // test_DECRQSS_DECSCUS
            
            // In the following groups, these are the tests that pass, the ones that do not pass still need
            // to be tracked here, like the lines above
            
            // DECSET
            "DECSET_ALTBUF",
            "DECSET_DECAWM_NoLineWrapOnTabWithLeftRightMargin",
            "DECSET_DECAWM_OnRespectsLeftRightMargin",
            "DECSET_DECAWM_TabDoesNotWrapAround",
            "DECSET_DECCOLM",
            "DECSET_DECLRMM",
            "DECSET_DECLRMM_MarginsResetByDECSTR",
            "DECSET_DECLRMM_ModeNotResetByDECSTR",
            "DECSET_DECOM_DECRQCRA",
            "DECSET_DECOM_SoftReset",
            // "DECSET_OPT_ALTBUF", ALBUF works, but not ALTBUF_CURSOR
            "DECSET_ResetReverseWraparoundDisablesIt",
            "DECSET_ReverseWraparound_BS",
            "DECSET_SaveRestoreCursor",

            // DL
            "DL_DefaultParam",
            "DL_DeleteMoreThanVisible",
            "DL_ExplicitParam",
            "DL_InScrollRegion",

            // ECH
            "ECH_DefaultParam",
            "ECH_ExplicitParam",
            "ECH_IgnoresScrollRegion",
            "ECH_OutsideScrollRegion",

            // EL
            "EL_0",
            "EL_1",
            "EL_2",
            "EL_Default",
            "EL_IgnoresScrollRegion",
            "EL_doesNotRespectDECProtection",

            // FF
            "FF_Basic",
            "FF_Scrolls",
            "FF_ScrollsInTopBottomRegionStartingAbove",
            "FF_ScrollsInTopBottomRegionStartingWithin",
            "FF_StopsAtBottomLineWhenBegunBelowScrollRegion",

            // HPA
            "HPA_DefaultParams",
            "HPA_DoesNotChangeRow",
            "HPA_StopsAtRightEdge",

            // HVP
            "HVP_ColumnOnly",
            "HVP_DefaultParams",
            "HVP_OutOfBoundsParams",
            "HVP_RowOnly",
            "HVP_ZeroIsTreatedAsOne",

            // ICH
            "ICH_DefaultParam",
            "ICH_ExplicitParam",
            "ICH_ScrollEntirelyOffRightEdge",
            "ICH_ScrollOffRightEdge",
            "ICH_ScrollOffRightMarginInScrollRegion",

            // IL
            "IL_DefaultParam",
            "IL_ExplicitParam",
            "IL_ScrollsOffBottom",

            // IND
            "IND_Basic",
            "IND_Scrolls",
            "IND_ScrollsInTopBottomRegionStartingAbove",
            "IND_ScrollsInTopBottomRegionStartingWithin",

            // LF
            // "LF_Scrolls", // This works, but the LF_Scrolls* do not, so commented out
            "LF_StopsAtBottomLineWhenBegunBelowScrollRegion",

            // NEL
            "NEL_Basic",
            "NEL_Scrolls",
            "NEL_ScrollsInTopBottomRegionStartingAbove",
            "NEL_ScrollsInTopBottomRegionStartingWithin",

            // REP
            "REP_DefaultParam",
            "REP_ExplicitParam",

            // ResetColor
            // RI
            "RI_Basic",
            "RI_Scrolls",
            "RI_ScrollsInTopBottomRegionStartingBelow",
            "RI_ScrollsInTopBottomRegionStartingWithin",
            "RI_StopsAtTopLineWhenBegunAboveScrollRegion",

            // RIS
            "RIS_ClearsScreen",
            "RIS_CursorToOrigin",
            "RIS_RemoveMargins",
            "RIS_ResetDECOM",
            "RIS_ResetTabs",
            "RIS_ResetTitleMode",


            // s8c1t?
            // SM
            "SM_IRM",
            "SM_IRM_DoesNotWrapUnlessCursorAtMargin",
            "SM_IRM_TruncatesAtRightMargin",

            // SU
            "SU_CanClearScreen",
            "SU_DefaultParam",
            "SU_ExplicitParam",
            "SU_OutsideTopBottomScrollRegion",
            "SU_RespectsTopBottomScrollRegion",

            // VPA
            "VPA_DefaultParams",
            "VPA_DoesNotChangeColumn",
            "VPA_StopsAtBottomEdge",

            // VT
            "VT_Basic",
            "VT_Scrolls",
            "VT_ScrollsInTopBottomRegionStartingAbove",
            "VT_ScrollsInTopBottomRegionStartingWithin",
            "VT_StopsAtBottomLineWhenBegunBelowScrollRegion",

        ]
        
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
