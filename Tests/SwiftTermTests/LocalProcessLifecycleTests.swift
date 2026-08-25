#if os(macOS)
import Darwin
import Foundation
import XCTest

@testable import SwiftTerm

final class LocalProcessLifecycleTests: XCTestCase {
    override func setUp() {
        super.setUp()
        signal(SIGCHLD, SIG_DFL)
    }

    func testForkptyPublishesExactPIDAndNormalizedExitCode() {
        let terminated = expectation(description: "process terminated")
        let delegate = LifecycleDelegate()
        delegate.onTermination = { terminated.fulfill() }
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.LocalProcessLifecycle.exit"))

        process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "exit 7"],
            environment: nil,
            execName: "sh")

        let pid = process.shellPid
        XCTAssertGreaterThan(pid, 0)
        wait(for: [terminated], timeout: 5)
        XCTAssertEqual(delegate.exitCode, 7)
        XCTAssertFalse(process.running)
        XCTAssertEqual(process.shellPid, 0)
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testTerminateSignalsAndReapsExactChildBeforeRelaunch() {
        let firstTermination = expectation(description: "first child terminated")
        let secondTermination = expectation(description: "replacement child terminated")
        let delegate = LifecycleDelegate()
        var terminationCount = 0
        delegate.onTermination = {
            terminationCount += 1
            if terminationCount == 1 {
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

        process.startProcess(
            executable: "/usr/bin/true",
            environment: nil,
            execName: "true")
        wait(for: [secondTermination], timeout: 5)
        XCTAssertEqual(terminationCount, 2)
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
        let deadline = Date().addingTimeInterval(5)
        while kill(pid, 0) == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}

private final class LifecycleDelegate: LocalProcessDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var storedExitCode: Int32?
    var onTermination: (() -> Void)?

    var exitCode: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return storedExitCode
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        lock.lock()
        storedExitCode = exitCode
        let callback = onTermination
        lock.unlock()
        callback?()
    }

    func dataReceived(slice: ArraySlice<UInt8>) {}

    func getWindowSize() -> winsize {
        winsize(ws_row: 24, ws_col: 80, ws_xpixel: 640, ws_ypixel: 480)
    }
}
#endif
