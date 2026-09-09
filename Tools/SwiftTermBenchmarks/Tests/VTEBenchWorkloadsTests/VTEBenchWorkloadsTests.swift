import CryptoKit
import Foundation
import Testing
@testable import VTEBenchWorkloads

@Suite("vtebench workload port")
struct VTEBenchWorkloadsTests {
    @Test("Ports every default case in sorted order")
    func caseNames() throws {
        let names = try VTEBenchWorkloads.makeDefault().map(\.name)
        #expect(names == [
            "cursor_motion",
            "dense_cells",
            "light_cells",
            "medium_cells",
            "scrolling",
            "scrolling_bottom_region",
            "scrolling_bottom_small_region",
            "scrolling_fullscreen",
            "scrolling_top_region",
            "scrolling_top_small_region",
            "sync_medium_cells",
            "unicode"
        ])
    }

    @Test("Keeps hardening workloads separate and deterministic")
    func hardeningCases() {
        let workloads = VTEBenchWorkloads.makeHardening()
        #expect(workloads.map(\.name) == [
            "hardening_ascii_seam_noop",
            "hardening_wide_seam_overwrite_edit",
            "hardening_horizontal_margin_wide_scroll_edit",
            "hardening_osc_bounded_normal",
            "hardening_osc_bounded_over_limit",
            "hardening_osc_bounded_chunked"
        ])

        let byName = Dictionary(uniqueKeysWithValues: workloads.map { ($0.name, $0) })
        #expect(byName["hardening_ascii_seam_noop"]?.setup.starts(with: [0x1b, 0x5b, 0x3f]) == true)
        #expect(String(decoding: byName["hardening_wide_seam_overwrite_edit"]!.payload, as: UTF8.self).contains("界"))
        #expect(String(decoding: byName["hardening_horizontal_margin_wide_scroll_edit"]!.setup, as: UTF8.self).contains("\u{1b}[?69h"))

        #expect(byName["hardening_osc_bounded_normal"]?.maximumOscBytes == 4_096)
        #expect(byName["hardening_osc_bounded_over_limit"]?.payload.count == 4_100)
        #expect(byName["hardening_osc_bounded_chunked"]?.inputChunkSize == 127)
    }

    @Test("Preserves captured byte streams")
    func capturedStreams() throws {
        let workloads = try dictionary()
        #expect(workloads["medium_cells"]?.payload.count == 178_345)
        #expect(sha256(workloads["medium_cells"]!.payload) ==
                "eb71cdb2c6255725288535f759c7177b3d601a0fe92dde114443462c4a7db727")
        #expect(workloads["sync_medium_cells"]?.payload.count == 185_737)
        #expect(sha256(workloads["sync_medium_cells"]!.payload) ==
                "f3b8a3dfdec88620539faaf53f12ef5f5a051886ddbd508086ede685fa9e6227")
        #expect(workloads["unicode"]?.payload.count == 138_296)
        #expect(sha256(workloads["unicode"]!.payload) ==
                "0650c4a97837d04d459492b601ea1d0d563517853525a8657a11a4bdd2d60fea")
    }

    @Test("Matches fixed-size generators and setup streams")
    func generatedStreams() throws {
        let workloads = try dictionary()
        #expect(workloads["cursor_motion"]?.payload.count == 456_066)
        #expect(sha256(workloads["cursor_motion"]!.payload) ==
                "32ccbdddef7a327eb198a0e9134fa6fb3d6149c6a2b08fe2521fdaec084436c1")
        #expect(workloads["dense_cells"]?.payload.count == 1_404_078)
        #expect(sha256(workloads["dense_cells"]!.payload) ==
                "6720e099478b939f97638048c5aa03358703421ca34d8591b0a8f2f55c5a19f4")
        #expect(workloads["light_cells"]?.payload.count == 52_078)
        #expect(sha256(workloads["light_cells"]!.payload) ==
                "47c08c85fb50d59ad1e787b23f8df6a0912f07126fc2cf53f28926c54ac54e6a")
        #expect(workloads["scrolling_fullscreen"]?.payload.count == 2_106)
        #expect(sha256(workloads["scrolling_fullscreen"]!.payload) ==
                "b247c42735889bd02cd746cd03a8b331c94b773199897f6956d11219742fea0f")
        #expect(workloads["scrolling"]?.setup.count == 200_002)
        #expect(String(decoding: workloads["scrolling_bottom_region"]!.setup, as: UTF8.self) ==
                "\u{1b}[?1049h\u{1b}[1;24r")
        #expect(String(decoding: workloads["scrolling_bottom_small_region"]!.setup, as: UTF8.self) ==
                "\u{1b}[?1049h\u{1b}[1;12r")
        #expect(String(decoding: workloads["scrolling_top_region"]!.setup, as: UTF8.self) ==
                "\u{1b}[?1049h\u{1b}[2;25r")
        #expect(String(decoding: workloads["scrolling_top_small_region"]!.setup, as: UTF8.self) ==
                "\u{1b}[?1049h\u{1b}[12;25r")
    }

    @Test("Repeats complete payloads to the minimum sample size")
    func sampleExpansion() {
        let workload = VTEBenchWorkload(name: "example", payload: [1, 2, 3])
        #expect(workload.sample(minimumByteCount: 1) == [1, 2, 3])
        #expect(workload.sample(minimumByteCount: 3) == [1, 2, 3])
        #expect(workload.sample(minimumByteCount: 4) == [1, 2, 3, 1, 2, 3])
    }

    @Test("Splits samples only when a workload requests input chunks")
    func sampleChunks() {
        let unsplit = VTEBenchWorkload(name: "whole", payload: [1, 2, 3])
        #expect(unsplit.sampleChunks(minimumByteCount: 4) == [[1, 2, 3, 1, 2, 3]])

        let chunked = VTEBenchWorkload(name: "chunked", payload: [1, 2, 3], inputChunkSize: 2)
        #expect(chunked.sampleChunks(minimumByteCount: 4) == [[1, 2], [3, 1], [2, 3]])
    }

    private func dictionary() throws -> [String: VTEBenchWorkload] {
        Dictionary(uniqueKeysWithValues: try VTEBenchWorkloads.makeDefault().map { ($0.name, $0) })
    }

    private func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }
}
