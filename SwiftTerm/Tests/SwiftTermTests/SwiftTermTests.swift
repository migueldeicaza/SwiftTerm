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
            "CUU", "DCS", "DECERA", "DECDSR", "DECFRA", "DECIC", "DECSTBM", "DECSTR", "DL", "HPR", "HTS", "TBC", "SM",
            "SOS", "VPR", "PM", "SU", "RM",
        
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
                // test_DECBI_Basic
                // test_DECBI_LeftOfMargin
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
                // test_DECFI_Basic
                // test_DECFI_RightOfMargin
                // test_DECFI_Scroll
                // test_DECFI_WholeScreenScroll
            
            // DECRQSS, 4 pass, 2 fail
            "DECRQSS_SGR",
            "DECRQSS_DECSTBM",
            "DECRQSS_DECSLRM",
            "DECRQSS_DECSCL",
                // Failing:
                // test_DECRQSS_DECSC
                // test_DECRQSS_DECSCUS
                        
            // DECSET, 14 pass, 9 fail
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
                // Failing:
                // test_DECSET_Allow80To132
                // test_DECSET_DECAWM_CursorAtRightMargin
                // test_DECSET_DECAWM_OffRespectsLeftRightMargin
                // test_DECSET_DECOM
                // test_DECSET_MoreFix
                // test_DECSET_OPT_ALTBUF_CURSOR
                // test_DECSET_ReverseWraparoundLastCol_BS
                // test_DECSET_ReverseWraparound_Multi
                // test_DECSET_ReverseWraparound_RequiresDECAWM

            // ECH, 4 pass, 2 failures
            "ECH_DefaultParam",
            "ECH_ExplicitParam",
            "ECH_IgnoresScrollRegion",
            "ECH_OutsideScrollRegion",
                // Failing:
                // test_ECH_doesNotRespectDECPRotection
                // test_ECH_respectsISOProtection

            // EL 6 pass, 1 failure
            "EL_0",
            "EL_1",
            "EL_2",
            "EL_Default",
            "EL_IgnoresScrollRegion",
            "EL_doesNotRespectDECProtection",
                // Failing:
                // test_EL_respectsISOProtection

            // FF 5 pass, 1 failure
            "FF_Basic",
            "FF_Scrolls",
            "FF_ScrollsInTopBottomRegionStartingAbove",
            "FF_ScrollsInTopBottomRegionStartingWithin",
            "FF_StopsAtBottomLineWhenBegunBelowScrollRegion",
                // Failing:
                // test_FF_MovesDoesNotScrollOutsideLeftRight

            // HPA 3 pass, 1 fails
            "HPA_DefaultParams",
            "HPA_DoesNotChangeRow",
            "HPA_StopsAtRightEdge",
                // Failing:
                // test_HPA_IgnoresOriginMode

            // HVP 5 pass, 1 fails
            "HVP_ColumnOnly",
            "HVP_DefaultParams",
            "HVP_OutOfBoundsParams",
            "HVP_RowOnly",
            "HVP_ZeroIsTreatedAsOne",
                // Failing:
                // test_HVP_RespectsOriginMode

            // ICH 5 pass, 1 fails
            "ICH_DefaultParam",
            "ICH_ExplicitParam",
            "ICH_ScrollEntirelyOffRightEdge",
            "ICH_ScrollOffRightEdge",
            "ICH_ScrollOffRightMarginInScrollRegion",
                // Failing:
                // test_ICH_IsNoOpWhenCursorBeginsOutsideScrollRegion

            // IL 3 pass, 3 fail
            "IL_DefaultParam",
            "IL_ExplicitParam",
            "IL_ScrollsOffBottom",
                // Failing:
                // test_IL_AboveScrollRegion
                // test_IL_RespectsScrollRegion
                // test_IL_RespectsScrollRegion_Over

            // IND 4 pass, 2 fail
            "IND_Basic",
            "IND_Scrolls",
            "IND_ScrollsInTopBottomRegionStartingAbove",
            "IND_ScrollsInTopBottomRegionStartingWithin",
                // Failing:
                // test_IND_MovesDoesNotScrollOutsideLeftRight
                // test_IND_StopsAtBottomLineWhenBegunBelowScrollRegion

            // LF 1 pass, 2 fail
            // "LF_Scrolls", // This works, but the LF_Scrolls* do not, so commented out
            "LF_StopsAtBottomLineWhenBegunBelowScrollRegion",
                // Failing:
                // test_IND_MovesDoesNotScrollOutsideLeftRight
                // test_IND_StopsAtBottomLineWhenBegunBelowScrollRegion

            // NEL 4 pass, 2 fail
            "NEL_Basic",
            "NEL_Scrolls",
            "NEL_ScrollsInTopBottomRegionStartingAbove",
            "NEL_ScrollsInTopBottomRegionStartingWithin",
                // Failing:
                // test_NEL_MovesDoesNotScrollOutsideLeftRight
                // test_NEL_StopsAtBottomLineWhenBegunBelowScrollRegion

            // REP 2 pass, 2 fail
            "REP_DefaultParam",
            "REP_ExplicitParam",
                // Failing:
                // test_REP_RespectsLeftRightMargins
                // test_REP_RespectsTopBottomMargins

            // ResetColor
            // RI 5 pass, 1 fail
            "RI_Basic",
            "RI_Scrolls",
            "RI_ScrollsInTopBottomRegionStartingBelow",
            "RI_ScrollsInTopBottomRegionStartingWithin",
            "RI_StopsAtTopLineWhenBegunAboveScrollRegion",
                // Failing:
                // test_RI_MovesDoesNotScrollOutsideLeftRight

            // RIS 6 pass, 1 expected
            "RIS_ClearsScreen",
            "RIS_CursorToOrigin",
            "RIS_RemoveMargins",
            "RIS_ResetDECOM",
            "RIS_ResetTabs",
            "RIS_ResetTitleMode",
            "RIS_ExitAltScreen",
                // Expected: this is because this assumes that if we are at 132 columns a reset (RIS) should
                // switch to 80 and that is just not the case for this terminal emultaor.
                // test_RIS_ResetDECCOLM


            // s8c1t?
            
            
            // VPA 3 pass, 1 fail
            "VPA_DefaultParams",
            "VPA_DoesNotChangeColumn",
            "VPA_StopsAtBottomEdge",
                // Failing:
                // test_VPA_IgnoresOriginMode

            // VT 5 pass, 1 fail
            "VT_Basic",
            "VT_Scrolls",
            "VT_ScrollsInTopBottomRegionStartingAbove",
            "VT_ScrollsInTopBottomRegionStartingWithin",
            "VT_StopsAtBottomLineWhenBegunBelowScrollRegion",
                // Failing:
                // test_VT_MovesDoesNotScrollOutsideLeftRight

        ]
        
        let expr = "test_(\(good.joined(separator: "|")))"
        
        XCTAssertNil(runTester (expr))
    }
    
    func testSingle ()
    {
        //XCTAssertNil(runTester ("test_DL_ClearOutLeftRightAndTopBottomScrollRegion"))
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
