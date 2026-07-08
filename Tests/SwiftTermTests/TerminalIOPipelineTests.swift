//
//  TerminalIOPipelineTests.swift
//  SwiftTermTests
//
//  Exercises the gather/parse pty read pipeline against a real openpty()
//  pair: integrity, EOF, backpressure, shutdown, latency, and bridging.
//
#if !os(iOS) && !os(Windows)
import Foundation
import Testing
@testable import SwiftTerm

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Serialized: these tests assert scheduling-dependent properties (delivery
// latency, producer stalls), so they should not also compete with each other.
// They still run in parallel with other suites, which is why the assertions
// below are written to hold even on a fully loaded machine.
@Suite(.serialized)
final class TerminalIOPipelineTests {
    @Test func integrityAndOrdering() throws {
        let payload = Self.countingPattern(byteCount: 16 * 1024 * 1024)
        let pty = try Self.makeRawPty()
        let capture = PipelineCapture()
        let pipeline = TerminalIOPipeline(fd: pty.master, delegate: capture)
        pipeline.start()

        let writer = PtyWriter(fd: pty.slave, payload: payload, chunkSizes: Self.randomChunkSizes(count: 1024))
        writer.start()

        #expect(capture.waitForEOF(timeout: 20))
        #expect(writer.waitUntilDone(timeout: 1))
        #expect(capture.receivedBytes == payload.count)
        #expect(capture.receivedData() == payload)
        #expect(pipeline.waitUntilStopped(timeout: 1))
    }

    @Test func eofAfterLastBatch() throws {
        let payload = Array("last batch before eof".utf8)
        let pty = try Self.makeRawPty()
        let capture = PipelineCapture()
        let pipeline = TerminalIOPipeline(fd: pty.master, delegate: capture)
        pipeline.start()

        let writer = PtyWriter(fd: pty.slave, payload: payload, chunkSizes: [payload.count])
        writer.start()

        #expect(capture.waitForEOF(timeout: 3))
        #expect(capture.receivedData() == payload)
        #expect(writer.waitUntilDone(timeout: 1))
        #expect(pipeline.waitUntilStopped(timeout: 1))
    }

    @Test func delegateBackpressureStallsProducerWithoutLoss() throws {
        // 512 KiB with a 50 ms delegate delay: at the ideal 64 KiB batch size
        // that is 8 batches (>= 400 ms, proving the producer was stalled by the
        // blocked delegate). Even fully starved into 1 KiB batches it is 512
        // batches (~26 s), safely under the timeout.
        let payload = Self.countingPattern(byteCount: 512 * 1024)
        let pty = try Self.makeRawPty()
        let capture = PipelineCapture(delayPerBatch: 0.05)
        let pipeline = TerminalIOPipeline(fd: pty.master, delegate: capture)
        pipeline.start()

        let writer = PtyWriter(fd: pty.slave, payload: payload, chunkSizes: [65_536])
        let start = ContinuousClock.now
        writer.start()

        #expect(capture.waitForEOF(timeout: 60))
        let elapsed = start.duration(to: .now)
        #expect(writer.waitUntilDone(timeout: 1))
        #expect(capture.receivedData() == payload)
        #expect(elapsed > .milliseconds(200))
        #expect(pipeline.waitUntilStopped(timeout: 1))
    }

    @Test func shutdownWakesIdlePipeline() throws {
        let pty = try Self.makeRawPty()
        let capture = PipelineCapture()
        let pipeline = TerminalIOPipeline(fd: pty.master, delegate: capture)
        pipeline.start()

        Thread.sleep(forTimeInterval: 0.02)
        let start = ContinuousClock.now
        pipeline.shutdown()

        #expect(pipeline.waitUntilStopped(timeout: 1))
        let elapsed = start.duration(to: .now)
        #expect(elapsed < .milliseconds(200))
        #expect(!capture.didReachEOF)
        close(pty.slave)
    }

    @Test func interactiveTrickleIsDeliveredImmediately() throws {
        // The property: a tiny write is delivered on its own, without the
        // pipeline waiting for more input or for EOF. The slave stays open, so
        // if the trickle fast path were broken this would time out rather than
        // flake under load (no wall-clock assertion on purpose).
        let payload = Array("hello".utf8)
        let pty = try Self.makeRawPty()
        let capture = PipelineCapture()
        let pipeline = TerminalIOPipeline(fd: pty.master, delegate: capture)
        pipeline.start()

        let writer = PtyWriter(fd: pty.slave, payload: payload, chunkSizes: [payload.count], closeWhenDone: false)
        writer.start()

        #expect(capture.waitForBytes(payload.count, timeout: 5))
        #expect(!capture.didReachEOF)
        #expect(capture.receivedData() == payload)

        writer.closeFd()
        #expect(capture.waitForEOF(timeout: 5))
        #expect(writer.waitUntilDone(timeout: 1))
        #expect(pipeline.waitUntilStopped(timeout: 1))
    }

    @Test func saturatedStreamBridgesIntoLargeBatches() throws {
        let payload = Self.countingPattern(byteCount: 4 * 1024 * 1024)
        let pty = try Self.makeRawPty()
        let capture = PipelineCapture()
        let pipeline = TerminalIOPipeline(fd: pty.master, delegate: capture)
        pipeline.start()

        let writer = PtyWriter(fd: pty.slave, payload: payload, chunkSizes: [65_536])
        writer.start()

        #expect(capture.waitForEOF(timeout: 30))
        #expect(writer.waitUntilDone(timeout: 1))
        #expect(capture.receivedData() == payload)
        // Bridging is what carries a batch past the ~1 KiB-per-read kernel tty
        // cap (the inner gather loop alone stops at the first EAGAIN). Assert
        // on the largest batch: the mean collapses when the gather thread is
        // preempted by parallel test suites, but a saturated stream must
        // produce at least one well-bridged batch even on a loaded machine.
        let largest = capture.maxBatchSize
        print("saturated stream: mean batch \(Int(capture.meanBatchSize)) bytes, max \(largest) bytes")
#if canImport(Darwin)
        #expect(largest > 8_192)
#else
        #expect(largest > 2_048)
#endif
        #expect(pipeline.waitUntilStopped(timeout: 1))
    }

    private static func makeRawPty() throws -> (master: Int32, slave: Int32) {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var terminalSettings = termios()
        if tcgetattr(slave, &terminalSettings) == 0 {
            cfmakeraw(&terminalSettings)
            _ = tcsetattr(slave, TCSANOW, &terminalSettings)
        }
        return (master, slave)
    }

    private static func countingPattern(byteCount: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: byteCount)
        for index in result.indices {
            result[index] = UInt8(truncatingIfNeeded: index)
        }
        return result
    }

    private static func randomChunkSizes(count: Int) -> [Int] {
        var seed: UInt64 = 0x5eed
        var result: [Int] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            result.append(Int(seed % 65_521) + 1)
        }
        return result
    }
}

private final class PipelineCapture: TerminalIOPipelineDelegate {
    private let condition = NSCondition()
    private let delayPerBatch: TimeInterval
    private var received: [UInt8] = []
    private var batchSizes: [Int] = []
    private(set) var didReachEOF = false

    init(delayPerBatch: TimeInterval = 0) {
        self.delayPerBatch = delayPerBatch
    }

    var receivedBytes: Int {
        condition.lock()
        let count = received.count
        condition.unlock()
        return count
    }

    var meanBatchSize: Double {
        condition.lock()
        let sizes = batchSizes
        condition.unlock()
        guard !sizes.isEmpty else {
            return 0
        }
        return Double(sizes.reduce(0, +)) / Double(sizes.count)
    }

    var maxBatchSize: Int {
        condition.lock()
        let largest = batchSizes.max() ?? 0
        condition.unlock()
        return largest
    }

    func receivedData() -> [UInt8] {
        condition.lock()
        let copy = received
        condition.unlock()
        return copy
    }

    func waitForBytes(_ count: Int, timeout: TimeInterval) -> Bool {
        wait(timeout: timeout) {
            self.received.count >= count
        }
    }

    func waitForEOF(timeout: TimeInterval) -> Bool {
        wait(timeout: timeout) {
            self.didReachEOF
        }
    }

    func pipeline(_ pipeline: TerminalIOPipeline, received data: [UInt8]) {
        if delayPerBatch > 0 {
            Thread.sleep(forTimeInterval: delayPerBatch)
        }
        condition.lock()
        received.append(contentsOf: data)
        batchSizes.append(data.count)
        condition.broadcast()
        condition.unlock()
    }

    func pipelineDidReachEOF(_ pipeline: TerminalIOPipeline) {
        condition.lock()
        didReachEOF = true
        condition.broadcast()
        condition.unlock()
    }

    private func wait(timeout: TimeInterval, predicate: () -> Bool) -> Bool {
        let limit = Date().addingTimeInterval(timeout)
        condition.lock()
        while !predicate() {
            if !condition.wait(until: limit) {
                condition.unlock()
                return false
            }
        }
        condition.unlock()
        return true
    }
}

private final class PtyWriter {
    private let condition = NSCondition()
    private let fd: Int32
    private let payload: [UInt8]
    private let chunkSizes: [Int]
    private let closeWhenDone: Bool
    private var closed = false
    private var done = false

    init(fd: Int32, payload: [UInt8], chunkSizes: [Int], closeWhenDone: Bool = true) {
        self.fd = fd
        self.payload = payload
        self.chunkSizes = chunkSizes
        self.closeWhenDone = closeWhenDone
    }

    func closeFd() {
        condition.lock()
        let shouldClose = !closed
        closed = true
        condition.unlock()
        if shouldClose {
            close(fd)
        }
    }

    func start() {
        Thread {
            self.writeAll()
        }.start()
    }

    func waitUntilDone(timeout: TimeInterval) -> Bool {
        let limit = Date().addingTimeInterval(timeout)
        condition.lock()
        while !done {
            if !condition.wait(until: limit) {
                condition.unlock()
                return false
            }
        }
        condition.unlock()
        return true
    }

    private func writeAll() {
        var offset = 0
        var chunkIndex = 0
        payload.withUnsafeBytes { rawPointer in
            guard let base = rawPointer.baseAddress else {
                return
            }
            while offset < payload.count {
                let chunkSize = chunkSizes[chunkIndex % chunkSizes.count]
                chunkIndex += 1
                let remaining = payload.count - offset
                let requested = min(chunkSize, remaining)
                let n = write(fd, base.advanced(by: offset), requested)
                if n > 0 {
                    offset += n
                    continue
                }
                if n < 0 && errno == EINTR {
                    continue
                }
                break
            }
        }
        if closeWhenDone {
            closeFd()
        }
        condition.lock()
        done = true
        condition.broadcast()
        condition.unlock()
    }
}
#endif
