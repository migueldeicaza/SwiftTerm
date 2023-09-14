#if os(macOS)
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
    
    static var esctest = "esctest/esctest/esctest.py"
    var termConfig = "--expected-terminal xterm --xterm-checksum=334"
    var logfile = NSTemporaryDirectory() + "log"
    
    func python27Bin() -> String? {
        guard let python27 = getenv("PYTHON_BIN") else {
            return "/Users/miguel/bin/python2.7"
        }
        return String(validatingUTF8: python27)
    }
    
    func runTester(_ includeRegexp: String) -> String?
    {
        let psem = DispatchSemaphore(value: 0)
        
        let t = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in
            Thread.sleep(forTimeInterval: 1)
            psem.signal ()
        }
        let python27 = python27Bin()!
        var args: [String] = ["--expected-terminal", "xterm", "--xterm-checksum=334", "--logfile", logfile]
        args += ["--include=\(includeRegexp)"]
        
        do {
            if FileManager.default.fileExists (atPath: logfile) {
                try FileManager.default.removeItem(atPath: logfile)
            }
        } catch {
            // Ignore
        }
        print ("Starting \(SwiftTermTests.esctest) with \(args)")
        args.insert(SwiftTermTests.esctest, at: 0)
        t.process.startProcess(executable: python27, args: args, environment: nil)
        
        psem.wait ()
        print ("Does the file exist? \(FileManager.default.fileExists (atPath: logfile))")
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
            "BS", "CAT", "CHA", "CHT", "CNL", "CPL", "CR", "CUB", "CUD", "CUF", "CUP", "CUU",
            "DCH", "DCS", "DECBI", "DECDC", "DECDSR", "DECERA", "DECFRA", "DECIC", "DECSTBM", "DECSTR", "DL",
            "FF", "HPR", "HTS", "HVP", "ICH", "IL", "LF",
            "PM", "REP", "ResetColor", "RM", "SD", "SM", "SOS", "SU", "TBC", "VPR", "VT",
        
            // These are partial successes, with known bugs, but let us not regress the ones that pass
                        
            // DECALN, 2 pass, 2 fail
            "DECALN_FillsScreen", "DECALN_MovesCursorHome",
                // Failing:
                // test_DECALN_ClearsMargin
            
            // DECRQM, 19 pass
            "DECRQM_ANSI_FETM", "DECRQM_ANSI_GATM", "DECRQM_ANSI_HEM", "DECRQM_ANSI_IRM", "DECRQM_ANSI_LNM",
            "DECRQM_ANSI_MATM", "DECRQM_ANSI_PUM", "DECRQM_ANSI_SATM", "DECRQM_ANSI_SRTM", "DECRQM_ANSI_TSM",
            "DECRQM_ANSI_TTM", "DECRQM_ANSI_VEM", "DECRQM_DEC_DECAWM", "DECRQM_DEC_DECCKM", "DECRQM_DEC_DECCOLM",
            "DECRQM_DEC_DECLRMM", "DECRQM_DEC_DECNKM", "DECRQM_DEC_DECOM", "DECRQM_DEC_DECSCNM",
            "DECRQM_DEC_DECSCLM",
            
                // This test probes modes, and some of these modes fail due to the difference between
                // a value configured, versus a hardwired value, so they are mostly fine, but worth
                // submiting patches or just accepting defeat and changing the default
                // those that return 0 are definitly not handled
                // * DECRQM_ANSI_KAM expected 2,1 got 2,2
                // DECRQM_DEC_DECAAM 100,2 got 100,0
                // DECRQM_DEC_DECARM, 8, 2, got 8,1
                // DECRQM_DEC_DECARSM 98,2, got 98,0
                // * DECRQM_DEC_DECBKM, 67,2 got 67,4
                // DECRQM_DEC_DECCANSM 101,2 got 101,0
                // DECRQM_DEC_DECCRTSM 97,2 got 97,0
                // DECRQM_DEC_DECESKM 104,2 got 104,0
                // DECRQM_DEC_DECHCCM 60,4 got 60,0
                // DECRQM_DEC_DECHDPXM 103,2 got 103,0
                // * DECRQM_DEC_DECHEBM 35,2 got 35,0
                // DECRQM_DEC_DECHEM 36,2 got 36,0
                // DECRQM_DEC_DECKBUM 68,2 got 68,0
                // DECRQM_DEC_DECKPM 81,2 got 81,0
                // DECRQM_DEC_DECMCM 99,2, got 99,0
                // DECRQM_DEC_DECNAKB 57,2 got 57,0
                // * DECRQM_DEC_DECNRCM 42,2 got 42,4
                // DECRQM_DEC_DECNULM 102,2, got 102,0
                // DECRQM_DEC_DECOSCNM 106,2 got 106,0
                // DECRQM_DEC_DECPCCM 64,2 got 64,0
                // DECRQM_DEC_DECRLCM 96,2 got 96,0
                // DECRQM_DEC_DECRLM 34,2 got 34, 0
                // DECRQM_DEC_DECSCLM 4,2 got 4,4
                // DECRQM_DEC_DECVCCM 61,2 got 61,0
                // DECRQM_DEC_DECXRLM   73,2 got 73,0
                // DECRQM_ANSI_SRM, 12,2 got 12,1 (needs to track state)
                // DECRQM_DEC_DECNCSM, 95,2 got 95,1 (needs to track state)
                // DECRQM_DEC_DECPEX, needs to track state)
                // DECRQM_DEC_DECPFF, needs to track state)
            
            // DECCRA, 8 pass, 2 fail
            "DECCRA_cursorDoesNotMove", "DECCRA_defaultValuesInDest", "DECCRA_defaultValuesInSource",
            "DECCRA_destinationPartiallyOffscreen", "DECCRA_ignoresMargins", "DECCRA_invalidSourceRectDoesNothing",
            "DECCRA_nonOverlappingSourceAndDest", "DECCRA_overlappingSourceAndDest",
                // Failing:
                // test_DECCRA_overlyLargeSourceClippedToScreenSize
                // test_DECCRA_respectsOriginMode
            
            // DECFI, 4 pass, 1 fail
            "DECFI_NoWrapOnRightEdge",
            "DECFI_Basic",
            "DECFI_RightOfMargin",
            "DECFI_Scroll",
                // Failing:
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
            "DECSET_Allow80To132",
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

            // HPA 3 pass, 1 fails
            "HPA_DefaultParams",
            "HPA_DoesNotChangeRow",
            "HPA_StopsAtRightEdge",
                // Failing:
                // test_HPA_IgnoresOriginMode - this is a problem with the mouse reporting, and not the actual position

            // IND 4 pass, 2 fail
            "IND_Basic",
            "IND_Scrolls",
            "IND_ScrollsInTopBottomRegionStartingAbove",
            "IND_ScrollsInTopBottomRegionStartingWithin",
                // Failing:
                // test_IND_MovesDoesNotScrollOutsideLeftRight
                // test_IND_StopsAtBottomLineWhenBegunBelowScrollRegion

            // NEL 4 pass, 2 fail
            "NEL_Basic",
            "NEL_Scrolls",
            "NEL_ScrollsInTopBottomRegionStartingAbove",
            "NEL_ScrollsInTopBottomRegionStartingWithin",
                // Failing: these are linked to the two previous IND failures
                // test_NEL_MovesDoesNotScrollOutsideLeftRight
                // test_NEL_StopsAtBottomLineWhenBegunBelowScrollRegion

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
            // "RIS_ResetTitleMode",  -- This was disabled, as it poses a security hole, see:
            // https://github.com/migueldeicaza/SwiftTerm/security/advisories/GHSA-jq43-q8mx-r7mq
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
            
            // ChangeColor 4 pass, 9 fail
            "ChangeColor_Hash3",
            "ChangeColor_Hash6",
            "ChangeColor_Hash9",
            "ChangeColor_RGB$",
            "ChangeColor_Multiple",
                // Failing:
                // ChangeColor_Hash12   - I disagree with this test, it passes 16 bit 0xf000 red and expects back 0xf0f0
                //
                // These are additional color spaces, RGBI looks
                // ChangeColor_RGBI
                // ChangeColor_CIELab
                // ChangeColor_CIELuv
                // ChangeColor_CIEXYZ
                // ChangeColor_CIEuvY
                // ChangeColor_CIExyY
                // ChangeColor_TekHVC
            
            "ChangeDynamicColor_Multiple",
            "ChangeDynamicColor_RGB$",
            "ChangeDynamicColor_Hash3",
            "ChangeDynamicColor_Hash6",
            "ChangeDynamicColor_Hash9",
            
            // Failing:
                // ChangeDynamicColor_CIELab
                // ChangeDynamicColor_CIELuv
                // ChangeDynamicColor_CIEXYZ
                // ChangeDynamicColor_CIEuvY
                // ChangeDynamicColor_CIExyY
                // ChangeDynamicColor_Hash12
                // ChangeDynamicColor_RGBI
                // ChangeDynamicColor_TekHVC

        ]
        
        let expr = "test_(\(good.joined(separator: "|")))"

        XCTAssertNil(runTester (expr))
    }
    
    // Use this test to run a single test
    func testSingle ()
    {
        XCTAssertNil(runTester ("test_ChangeColor_Hash3"))
    }
    
    func xtestFailuresOnHeadless ()
    {
        XCTAssertNil(runTester ("test_DECCRA"))
        XCTAssertNil(runTester ("test_HPA"))
    }

    static var allTests = [
        ("testKnownGood", testKnownGood),
        //("testMarkerMissing", testFailuresOnHeadless),
    ]
}
#endif
