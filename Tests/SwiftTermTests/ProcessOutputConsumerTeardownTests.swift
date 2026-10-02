#if os(macOS)
import AppKit
import Darwin
import MachO
import XCTest

@testable import SwiftTerm

@MainActor
final class ProcessOutputConsumerTeardownTests: XCTestCase {
    private static let childModeKey = "SWIFTTERM_CONSUMER_TEARDOWN_CHILD"
    nonisolated private static let batchCount = 20_000

    private final class Capture {
        var view: LocalProcessTerminalView?
        weak var weakView: LocalProcessTerminalView?
        weak var weakAdapter: LocalProcessDelegate?
        var batches = 0
        var firstAddress: UInt = 0
        var lastAddress: UInt = 0
    }

    func testBorrowedConsumerInvocationStackDoesNotGrow() throws {
        try checkInvocationStack(borrowed: true)
    }

    func testSliceConsumerInvocationStackDoesNotGrow() throws {
        try checkInvocationStack(borrowed: false)
    }

    private func checkInvocationStack(borrowed: Bool) throws {
        let capture = Capture()
        let adapter = try prepareAdapter(capture, batches: 1_000)
        Self.deliverAndRelease(adapter, borrowed: borrowed, batches: 1_000)
        XCTAssertEqual(capture.batches, 1_000)
        let growth = max(capture.firstAddress, capture.lastAddress) - min(capture.firstAddress, capture.lastAddress)
        FileHandle.standardError.write(Data("INVOCATION STACK \(borrowed ? "borrowed" : "slice"): \(growth) bytes\n".utf8))
        XCTAssertLessThan(growth, 4_096, "consumer invocation stack grew by \(growth) bytes")
    }

    func testBorrowedConsumerTeardownAfterManyBatches() async throws {
        try await runChild(mode: "borrowed")
    }

    func testSliceConsumerTeardownAfterManyBatches() async throws {
        try await runChild(mode: "slice")
    }

    private func runChild(mode: String) async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/consumer-teardown-tests/\(UUID().uuidString)")
        let fileManager = FileManager.default
        for name in ["home", "runtime"] {
            try fileManager.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        defer { try? fileManager.removeItem(at: root) }
        let logURL = root.appendingPathComponent("child.log")
        XCTAssertTrue(fileManager.createFile(atPath: logURL.path, contents: nil))
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let child = Process()
        // Reuse the XCTest runner directly: xcrun strips sanitizer preload variables.
        child.executableURL = try XCTUnwrap(Bundle.main.executableURL)
        child.arguments = [
            "-XCTest",
            "SwiftTermTests.ProcessOutputConsumerTeardownTests/testConsumerTeardownChild",
            Bundle(for: Self.self).bundleURL.path
        ]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.childModeKey] = mode
        environment["HOME"] = root.appendingPathComponent("home").path
        environment["CFFIXED_USER_HOME"] = environment["HOME"]
        environment["TMPDIR"] = root.appendingPathComponent("runtime").path
        environment["SHELL"] = "/bin/sh"
        // XCTest loads the test bundle dynamically. Preload ThreadSanitizer
        // in children too, even when the parent consumed its DYLD environment.
        let sanitizer = (0..<_dyld_image_count()).compactMap { index in
            _dyld_get_image_name(index).map { String(cString: $0) }
        }.first { $0.contains("/libclang_rt.tsan_") }
        if let sanitizer {
            environment["DYLD_INSERT_LIBRARIES"] = [sanitizer, environment["DYLD_INSERT_LIBRARIES"]]
                .compactMap { $0 }.joined(separator: ":")
        }
        child.environment = environment
        child.standardOutput = log
        child.standardError = log
        try child.run()
        defer {
            if child.isRunning {
                kill(child.processIdentifier, SIGKILL)
                child.waitUntilExit()
            }
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while child.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if child.isRunning {
            child.terminate()
            let terminationDeadline = ContinuousClock.now + .seconds(2)
            while child.isRunning, ContinuousClock.now < terminationDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            XCTFail("\(mode) consumer teardown child timed out")
        }
        child.waitUntilExit()
        let output = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(child.terminationReason, .exit, output)
        XCTAssertEqual(child.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("TEARDOWN COMPLETE \(mode)"), output)
    }

    func testConsumerTeardownChild() async throws {
        guard let mode = ProcessInfo.processInfo.environment[Self.childModeKey] else {
            throw XCTSkip("Runs only in the isolated teardown subprocess")
        }
        let capture = Capture()
        let adapter = try prepareAdapter(capture)
        let completed = Locked(false)
        let worker = Thread {
            Self.deliverAndRelease(adapter, borrowed: mode == "borrowed")
            FileHandle.standardError.write(Data("TEARDOWN COMPLETE \(mode)\n".utf8))
            completed.withLock { $0 = true }
        }
        worker.name = "swiftterm-output-consumer-teardown"
        worker.stackSize = 512 * 1024
        worker.start()
        let deadline = ContinuousClock.now + .seconds(20)
        while !completed.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(completed.withLock { $0 })
        XCTAssertEqual(capture.batches, Self.batchCount)
        XCTAssertNil(capture.weakView)
        XCTAssertNil(capture.weakAdapter)
        // AppKit autorelease can delay final destruction until main; retain
        // the drift assertion so a delayed release cannot mask stack growth.
        let growth = max(capture.firstAddress, capture.lastAddress) - min(capture.firstAddress, capture.lastAddress)
        XCTAssertLessThan(growth, 4_096, "consumer invocation stack grew by \(growth) bytes")
    }

    private func prepareAdapter(_ capture: Capture, batches: Int = batchCount) throws -> Locked<LocalProcessDelegate?> {
        let view = LocalProcessTerminalView(frame: .zero)
        capture.view = view
        capture.weakView = view
        try view.setProcessOutputConsumer { bytes in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(bytes, [UInt8(truncatingIfNeeded: capture.batches)])
            var marker = 0
            let address = withUnsafePointer(to: &marker) { UInt(bitPattern: $0) }
            if capture.batches == 0 { capture.firstAddress = address }
            capture.lastAddress = address
            capture.batches += 1
            if capture.batches == batches {
                FileHandle.standardError.write(Data("DELIVERED \(capture.batches); dropping view on main\n".utf8))
                capture.view = nil
            }
        }
        // Keep the production adapter private: this probe only borrows the
        // delegate installed by the real view, without changing library API.
        let value = Mirror(reflecting: view).children.first { $0.label == "processAdapter" }?.value
        let adapter = try XCTUnwrap(value as? LocalProcessDelegate)
        capture.weakAdapter = adapter
        return Locked(adapter)
    }

    @inline(never)
    nonisolated private static func deliverAndRelease(
        _ pending: Locked<LocalProcessDelegate?>, borrowed: Bool, batches: Int = batchCount
    ) {
        let adapter = pending.withLock { value in
            let current = value
            value = nil
            return current
        }!
        for index in 0..<batches {
            let bytes = [UInt8(truncatingIfNeeded: index)]
            let slice = bytes[...]
            if borrowed {
                (adapter as! LocalProcessBorrowedDataDelegate).dataReceivedBorrowed(slice.span)
            } else {
                adapter.dataReceived(slice: slice)
            }
        }
        // Returning drops the last adapter reference on the same-sized worker
        // stack used by LocalProcess, after main has released the owning view.
        withExtendedLifetime(adapter) {}
    }
}
#endif
