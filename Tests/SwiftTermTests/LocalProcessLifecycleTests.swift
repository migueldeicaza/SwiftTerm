#if os(macOS) || os(Linux)
#if os(macOS)
import Darwin
#else
import Glibc
#endif
import Foundation
import XCTest

@testable import SwiftTerm

final class LocalProcessLifecycleTests: XCTestCase {
    func testForkptyPublishesExactPIDAndNormalizedExitCode() {
        let terminated = expectation(description: "process terminated")
        let delegate = LifecycleDelegate()
        delegate.onTermination = { terminated.fulfill() }
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.LocalProcessLifecycle.exit"))

        // The child blocks on read until the test has captured its PID;
        // reading shellPid after an instantly-exiting child races the reaper
        // retiring it.
        process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "read line; exit 7"],
            environment: nil,
            execName: "sh")

        let pid = process.shellPid
        XCTAssertGreaterThan(pid, 0)
        process.send(data: ArraySlice("\n".utf8))
        wait(for: [terminated], timeout: 5)
        XCTAssertEqual(delegate.exitCode, 7)
        XCTAssertFalse(process.running)
        XCTAssertEqual(process.shellPid, 0)
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testInstantExitDeliversDataBeforeTermination() {
        let terminated = expectation(description: "process terminated")
        let events = Locked<[String]>([])
        let delegate = LifecycleDelegate()
        delegate.onData = {
            events.withLock { $0.append("data") }
        }
        delegate.onTermination = {
            events.withLock { $0.append("termination") }
            terminated.fulfill()
        }
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.LocalProcessLifecycle.instant-exit"))

        process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "printf hello"],
            environment: nil,
            execName: "sh")

        wait(for: [terminated], timeout: 5)
        XCTAssertEqual(delegate.receivedData, Array("hello".utf8))
        let deliveredEvents = events.withLock { $0 }
        XCTAssertEqual(deliveredEvents.last, "termination")
        XCTAssertTrue(deliveredEvents.dropLast().allSatisfy { $0 == "data" })
    }

    func testTerminateSignalsAndReapsExactChildBeforeRelaunch() {
        let firstTermination = expectation(description: "first child terminated")
        let secondTermination = expectation(description: "replacement child terminated")
        let delegate = LifecycleDelegate()
        let terminationCount = Locked(0)
        delegate.onTermination = {
            let count = terminationCount.withLock { value in
                value += 1
                return value
            }
            if count == 1 {
                firstTermination.fulfill()
            } else {
                secondTermination.fulfill()
            }
        }
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.LocalProcessLifecycle.relaunch"))

        process.startProcess(
            executable: "/bin/sleep",
            args: ["30"],
            environment: nil,
            execName: "sleep")
        let firstPID = process.shellPid
        XCTAssertEqual(kill(firstPID, SIGSTOP), 0)
        process.terminate()
        process.startProcess(
            executable: "/usr/bin/true",
            environment: nil,
            execName: "true")

        XCTAssertEqual(process.shellPid, firstPID)
        XCTAssertEqual(kill(firstPID, SIGCONT), 0)
        wait(for: [firstTermination], timeout: 5)
        XCTAssertEqual(kill(firstPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertNil(delegate.exitCode)

        process.startProcess(
            executable: "/usr/bin/true",
            environment: nil,
            execName: "true")
        wait(for: [secondTermination], timeout: 5)
        XCTAssertEqual(terminationCount.withLock { $0 }, 2)
    }

    func testReapedChildDrainsOutputBeforeCallbackDrivenRelaunch() throws {
        let payload = Data(repeating: 0x78, count: 256 * 1024)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftTerm-LocalProcess-\(UUID().uuidString)")
        try payload.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let secondTermination = expectation(description: "replacement child terminated")
        let delegate = LifecycleDelegate(dataDelay: 0.001)
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.LocalProcessLifecycle.drain"))
        let terminationCount = Locked(0)
        let byteCountAtFirstTermination = Locked(0)
        delegate.onTermination = {
            let count = terminationCount.withLock { value in
                value += 1
                return value
            }
            if count == 1 {
                byteCountAtFirstTermination.withLock {
                    $0 = delegate.receivedByteCount
                }
                process.startProcess(
                    executable: "/usr/bin/true",
                    environment: nil,
                    execName: "true")
            } else {
                secondTermination.fulfill()
            }
        }

        process.startProcess(
            executable: "/bin/cat",
            args: [fileURL.path],
            environment: nil,
            execName: "cat")

        wait(for: [secondTermination], timeout: 10)
        XCTAssertEqual(byteCountAtFirstTermination.withLock { $0 }, payload.count)
        XCTAssertEqual(delegate.receivedByteCount, payload.count)
        XCTAssertEqual(terminationCount.withLock { $0 }, 2)
    }

    func testDirectChildExitDoesNotWaitForDescendantPTYClosure() throws {
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftTerm-descendant-\(UUID().uuidString)")
        try Data().write(to: markerURL)
        defer { try? FileManager.default.removeItem(at: markerURL) }

        let firstTermination = expectation(description: "direct child terminated")
        let secondTermination = expectation(description: "replacement child terminated")
        let delegate = LifecycleDelegate()
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.LocalProcessLifecycle.descendant"))
        let terminationCount = Locked(0)
        delegate.onTermination = {
            let count = terminationCount.withLock { value in
                value += 1
                return value
            }
            if count == 1 {
                firstTermination.fulfill()
                process.startProcess(
                    executable: "/usr/bin/true",
                    environment: nil,
                    execName: "true")
            } else {
                secondTermination.fulfill()
            }
        }

        process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "while test -e '\(markerURL.path)'; do sleep 0.1; done &"],
            environment: nil,
            execName: "sh")

        wait(for: [firstTermination, secondTermination], timeout: 5)
        XCTAssertEqual(terminationCount.withLock { $0 }, 2)
    }

    func testDirectDeliveryRelaunchWaitsForQueuedTermination() {
        let deliveryQueue = DispatchQueue(
            label: "SwiftTerm.LocalProcessLifecycle.direct-order")
        let dataEntered = expectation(description: "direct data delivery entered")
        let queueBlocked = expectation(description: "delivery queue blocked")
        let firstTermination = expectation(description: "first termination delivered")
        let replacementData = expectation(description: "replacement data delivered")
        let secondTermination = expectation(description: "replacement termination delivered")
        let releaseData = DispatchSemaphore(value: 0)
        let unblockQueue = DispatchSemaphore(value: 0)
        let events = Locked<[String]>([])
        let delegate = LifecycleDelegate()
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: deliveryQueue,
            directDelivery: true)
        let terminationCount = Locked(0)
        delegate.onData = {
            dataEntered.fulfill()
            releaseData.wait()
        }
        delegate.onTermination = {
            let count = terminationCount.withLock { value in
                value += 1
                return value
            }
            if count == 1 {
                events.withLock { $0.append("termination") }
                firstTermination.fulfill()
                delegate.onData = {
                    events.withLock { $0.append("data") }
                    replacementData.fulfill()
                }
                process.startProcess(
                    executable: "/bin/sh",
                    args: ["-c", "printf replacement"],
                    environment: nil,
                    execName: "sh")
            } else {
                secondTermination.fulfill()
            }
        }

        process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "printf held"],
            environment: nil,
            execName: "sh")
        wait(for: [dataEntered], timeout: 5)
        defer {
            releaseData.signal()
            unblockQueue.signal()
        }

        XCTAssertTrue(waitUntil(timeout: 5) { process.shellPid == 0 })
        deliveryQueue.async {
            queueBlocked.fulfill()
            unblockQueue.wait()
        }
        wait(for: [queueBlocked], timeout: 5)
        releaseData.signal()

        XCTAssertTrue(waitUntil(timeout: 5) { !process.running })
        XCTAssertTrue(process.windingDown)
        process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "printf premature"],
            environment: nil,
            execName: "sh")
        XCTAssertEqual(process.shellPid, 0)
        XCTAssertTrue(events.withLock { $0.isEmpty })

        unblockQueue.signal()
        wait(
            for: [firstTermination, replacementData, secondTermination],
            timeout: 10)
        XCTAssertEqual(events.withLock { $0.first }, "termination")
        XCTAssertEqual(terminationCount.withLock { $0 }, 2)
    }

    func testReapedChildRetiresPublicHandlesBeforeSlowOutputDrain() {
        let dataEntered = expectation(description: "data delivery entered")
        let terminated = expectation(description: "termination delivered")
        let releaseData = DispatchSemaphore(value: 0)
        let delegate = LifecycleDelegate()
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: DispatchQueue(
                label: "SwiftTerm.LocalProcessLifecycle.retired-handles"),
            directDelivery: true)
        delegate.onData = {
            dataEntered.fulfill()
            releaseData.wait()
        }
        delegate.onTermination = { terminated.fulfill() }

        process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "printf buffered-output"],
            environment: nil,
            execName: "sh")
        wait(for: [dataEntered], timeout: 5)
        defer { releaseData.signal() }

        XCTAssertTrue(waitUntil(timeout: 5) { process.shellPid == 0 })
        XCTAssertEqual(process.childfd, -1)
        XCTAssertTrue(process.running)

        process.startProcess(
            executable: "/usr/bin/true",
            environment: nil,
            execName: "true")
        XCTAssertEqual(process.shellPid, 0)

        releaseData.signal()
        wait(for: [terminated], timeout: 5)
        XCTAssertFalse(process.running)
    }

    func testDeinitTerminatesAndReapsChild() {
        let delegate = LifecycleDelegate()
        weak var releasedProcess: LocalProcess?
        var pid: pid_t = 0

        autoreleasepool {
            let process = LocalProcess(
                delegate: delegate,
                dispatchQueue: DispatchQueue(label: "SwiftTerm.LocalProcessLifecycle.deinit"))
            process.startProcess(
                executable: "/bin/sleep",
                args: ["30"],
                environment: nil,
                execName: "sleep")
            pid = process.shellPid
            releasedProcess = process
        }

        XCTAssertNil(releasedProcess)
        XCTAssertTrue(waitUntil(timeout: 5, interval: 0.01) {
            kill(pid, 0) == -1 && errno == ESRCH
        })
    }

    func testDeinitEscalatesWhenChildIgnoresTermination() {
        let ready = expectation(description: "signal traps installed")
        let delegate = LifecycleDelegate()
        delegate.onData = { ready.fulfill() }
        weak var releasedProcess: LocalProcess?
        var process: LocalProcess? = LocalProcess(
            delegate: delegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.LocalProcessLifecycle.deinit-escalation"))
        process?.startProcess(
            executable: "/bin/sh",
            args: ["-c", "trap '' HUP TERM; echo ready; while :; do :; done"],
            environment: nil,
            execName: "sh")
        let pid = process?.shellPid ?? 0
        releasedProcess = process

        wait(for: [ready], timeout: 5)
        process = nil

        XCTAssertNil(releasedProcess)
        XCTAssertTrue(waitUntil(timeout: 5, interval: 0.01) {
            kill(pid, 0) == -1 && errno == ESRCH
        })
    }

    func testStartProcessWhileRunningIsRefused() {
        let terminated = expectation(description: "process terminated")
        let terminationCount = Locked(0)
        let delegate = LifecycleDelegate()
        delegate.onTermination = {
            terminationCount.withLock { $0 += 1 }
            terminated.fulfill()
        }
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.LocalProcessLifecycle.second-start"))

        process.startProcess(
            executable: "/bin/sleep",
            args: ["30"],
            environment: nil,
            execName: "sleep")
        let pid = process.shellPid
        process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "printf unexpected"],
            environment: nil,
            execName: "sh")

        XCTAssertEqual(process.shellPid, pid)
        XCTAssertTrue(process.running)
        process.terminate()
        wait(for: [terminated], timeout: 5)
        XCTAssertEqual(terminationCount.withLock { $0 }, 1)
        XCTAssertTrue(delegate.receivedData.isEmpty)
    }

    func testTwoConcurrentInstancesGetTheirOwnExitCodes() {
        let firstTerminated = expectation(description: "first process terminated")
        let secondTerminated = expectation(description: "second process terminated")
        let firstDelegate = LifecycleDelegate()
        let secondDelegate = LifecycleDelegate()
        firstDelegate.onTermination = { firstTerminated.fulfill() }
        secondDelegate.onTermination = { secondTerminated.fulfill() }
        let firstProcess = LocalProcess(
            delegate: firstDelegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.LocalProcessLifecycle.concurrent.first"))
        let secondProcess = LocalProcess(
            delegate: secondDelegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.LocalProcessLifecycle.concurrent.second"))

        firstProcess.startProcess(
            executable: "/bin/sh",
            args: ["-c", "printf first; exit 3"],
            environment: nil,
            execName: "sh")
        secondProcess.startProcess(
            executable: "/bin/sh",
            args: ["-c", "printf second; exit 5"],
            environment: nil,
            execName: "sh")

        wait(for: [firstTerminated, secondTerminated], timeout: 5)
        XCTAssertEqual(firstDelegate.exitCode, 3)
        XCTAssertEqual(secondDelegate.exitCode, 5)
        XCTAssertEqual(firstDelegate.receivedData, Array("first".utf8))
        XCTAssertEqual(secondDelegate.receivedData, Array("second".utf8))
    }

    private func waitUntil(
        timeout: TimeInterval,
        interval: TimeInterval = 0.001,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            Thread.sleep(forTimeInterval: interval)
        }
        return condition()
    }
}

private final class LifecycleDelegate: LocalProcessDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let dataDelay: TimeInterval
    private var storedExitCode: Int32?
    private var storedReceivedData: [UInt8] = []
    private var storedOnTermination: (() -> Void)?
    private var storedOnData: (() -> Void)?

    init(dataDelay: TimeInterval = 0) {
        self.dataDelay = dataDelay
    }

    var onTermination: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedOnTermination
        }
        set {
            lock.lock()
            storedOnTermination = newValue
            lock.unlock()
        }
    }

    var onData: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedOnData
        }
        set {
            lock.lock()
            storedOnData = newValue
            lock.unlock()
        }
    }

    var exitCode: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return storedExitCode
    }

    var receivedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedReceivedData.count
    }

    var receivedData: [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return storedReceivedData
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        lock.lock()
        storedExitCode = exitCode
        let callback = storedOnTermination
        lock.unlock()
        callback?()
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        lock.lock()
        storedReceivedData.append(contentsOf: slice)
        let callback = storedOnData
        storedOnData = nil
        lock.unlock()
        callback?()
        if dataDelay > 0 {
            Thread.sleep(forTimeInterval: dataDelay)
        }
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: 24, ws_col: 80, ws_xpixel: 640, ws_ypixel: 480)
    }
}
#endif
