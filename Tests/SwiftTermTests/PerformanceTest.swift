//
//  PerformanceTest.swift
//
//
//  Created by Miguel de Icaza on 4/17/20.
//
#if os(macOS)
import Foundation
import Testing
import os
@testable import SwiftTerm

@Suite(.serialized)
final class PerformaceTests {
    let signposter = OSSignposter(subsystem: "SwiftTerm", category: .pointsOfInterest)

    @Test func testPerformance() {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        // 5.164 before the changes
        t.feed (text: "\u{1b}[38;2;19;49;174;48;2;23;56;179mStringThis is a very long line\n\r")
        for _ in 0..<20000 {
            t.feed(text: "pointless repetition\n")
        }
    }

    @Test func testPerformance2() {
        testFeed(
            tag: "insertCharacter",
            data: [UInt8]("pointless repetition\n".utf8),
            duration: Duration(secondsComponent: 10, attosecondsComponent: 0))
    }

    @Test func measureSIMDParserCorpora() {
#if !DEBUG
        let duration = Duration(secondsComponent: 1, attosecondsComponent: 0)
        testFeed(
            tag: "SIMDPlainASCII",
            data: repeatedCorpus("plain ascii terminal text ", byteCount: 4 * 1_024) + [0x0a, 0x0d],
            duration: duration)
        testFeed(
            tag: "SIMDEscapeDense",
            data: repeatedCorpus("abcdefghijklmnopqr\u{1b}[31m", byteCount: 4 * 1_024),
            duration: duration)
        testFeed(
            tag: "SIMDMixedUTF8",
            data: repeatedCorpus("ASCII-é-中-🙂 ", byteCount: 4 * 1_024),
            duration: duration)
        testFeed(
            tag: "SIMDCSIDense",
            data: repeatedCorpus("\u{1b}[1;1H\u{1b}[38;5;123mX", byteCount: 4 * 1_024),
            duration: duration)
        testFeed(
            tag: "SIMDOSCPayload",
            data: [0x1b, 0x5d] + Array("9999;".utf8) +
                Array(repeating: UInt8(0x61), count: 64 * 1_024) + [0x07],
            duration: duration)
#endif
    }

    @Test func measureSIMDScannerAgainstScalar() {
#if !DEBUG
        var simdBytes = Array(repeating: UInt8(0x41), count: 64 * 1_024)
        var scalarBytes = simdBytes
        var simdIteration = 0
        var scalarIteration = 0
        let duration = Duration(secondsComponent: 1, attosecondsComponent: 0)
        let simdMeasurement = callsPerSecond(duration: duration) {
            simdBytes[simdBytes.count - 1] = simdIteration.isMultiple(of: 2) ? 0x1f : 0x20
            simdIteration += 1
            return ByteRunScanner.firstC0Byte(in: simdBytes[...], from: simdBytes.startIndex)
        }
        let scalarMeasurement = callsPerSecond(duration: duration) {
            scalarBytes[scalarBytes.count - 1] = scalarIteration.isMultiple(of: 2) ? 0x1f : 0x20
            scalarIteration += 1
            return scalarFirstC0Byte(in: scalarBytes[...], from: scalarBytes.startIndex)
        }
        print("SIMD scanner: \(simdMeasurement.throughput) calls/s")
        print("Scalar scanner: \(scalarMeasurement.throughput) calls/s")
        print("SIMD scanner speedup: \(simdMeasurement.throughput / scalarMeasurement.throughput)x")
        print("Scanner checksums: \(simdMeasurement.checksum), \(scalarMeasurement.checksum)")
#endif
    }

    func testFeed(tag: StaticString, data: [UInt8], duration: Duration) {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!
        t.silentLog = true

        var now = ContinuousClock.now
        var outerIterations = 0
        let interval = signposter.beginInterval(tag)
        let start = ContinuousClock.now

        t.feed (text: "\u{1b}[38;2;19;49;174;48;2;23;56;179mStringThis is a very long line\n\r")

        repeat {
            t.feed(byteArray: data)
            outerIterations += 1
            now = .now
        } while (start.duration(to: now) < duration)
        let elapsed = start.duration(to: now)
        let attoseconds = Double(elapsed.components.attoseconds)
        let seconds = Double(elapsed.components.seconds)
        let throughput = Double(outerIterations) / (seconds + attoseconds / 1e18)
        signposter.endInterval(tag, interval, "\(throughput) throughput calls/s")
        print("\(tag): \(throughput) throughput calls/s")
    }

    private func repeatedCorpus(_ pattern: String, byteCount: Int) -> [UInt8] {
        let patternBytes = Array(pattern.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(byteCount)
        while result.count < byteCount {
            result.append(contentsOf: patternBytes)
        }
        return result
    }

    private func callsPerSecond(
        duration: Duration,
        body: () -> Int
    ) -> (throughput: Double, checksum: Int) {
        let start = ContinuousClock.now
        var now = start
        var iterations = 0
        var checksum = 0
        repeat {
            checksum &+= body()
            iterations += 1
            now = .now
        } while start.duration(to: now) < duration
        let elapsed = start.duration(to: now)
        let seconds = Double(elapsed.components.seconds) +
            Double(elapsed.components.attoseconds) / 1e18
        return (Double(iterations) / seconds, checksum)
    }

    private func scalarFirstC0Byte(in bytes: ArraySlice<UInt8>, from start: Int) -> Int {
        for index in start..<bytes.endIndex where bytes[index] < 0x20 {
            return index
        }
        return bytes.endIndex
    }

    @Test func measureBigBlogFeed() {
        guard let d = try? Data(contentsOf: URL(filePath: "/Users/miguel/cvs/vtebench/x")) else {
            print("Skipping test, we do not have the data")
            return
        }
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        let internval = signposter.beginInterval("FeedPerf")
        let start = ContinuousClock.now

        for _ in 0..<10 {
            t.feed(byteArray: [UInt8](d))
        }

        let elapsed = start.duration(to: ContinuousClock.now)
        signposter.endInterval("FeedPerf", internval, "Time \(elapsed)")
        print("measureBigBlogFeed: \(elapsed) elapsed")

    }

    @Test func repeatBigBlob() {
        // This file is generated with:
        // vtebench:
        // target/release/vtebench --max-samples 1 -b benchmarks/medium_cells/
        guard let d = try? Data(contentsOf: URL(filePath: "/Users/miguel/cvs/vtebench/x")) else {
            print("Skipping test, we do not have the data")
            return
        }

        testFeed(
            tag: "VteBenchPerf",
            data: [UInt8](d),
            duration: Duration(secondsComponent: 10, attosecondsComponent: 0))
    }

    @Test func repeatDataFile() {
        guard let d = try? Data(contentsOf: URL(filePath: "/Users/miguel/data-file")) else {
            print("Skipping test, we do not have the data")
            return
        }

        testFeed(
            tag: "DataFilePerf",
            data: [UInt8](d),
            duration: Duration(secondsComponent: 10, attosecondsComponent: 0))
    }

}
#endif
