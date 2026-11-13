//
//  LocalProcessPrimaryDescriptorTests.swift
//  SwiftTermTests
//
//  Exercises LocalProcess primary publication, locked caller-owned duplication
//  and pre-publication close-on-exec setup against real PTY children.
//
#if os(macOS) || os(Linux)
#if os(macOS)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif
import Foundation
import Testing
@testable import SwiftTerm

private struct PrimaryDescriptorIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let rdev: dev_t
    let mode: mode_t
}

private enum PrimaryDescriptorTestError: Error {
    case couldNotMakeFifo(String, Int32)
    case couldNotOpenFifo(String, Int32)
    case couldNotCreateTemporaryFile(String)
    case couldNotOpenFile(String, Int32)
    case couldNotDuplicateDescriptor(Int32, Int32)
    case couldNotReserveDescriptor(Int32)
    case missingDescriptor(Int32, Int32)
    case launchFailed(String)
}

private func primaryDescriptorIdentity(_ descriptor: Int32) throws -> PrimaryDescriptorIdentity {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
        throw PrimaryDescriptorTestError.missingDescriptor(descriptor, errno)
    }
    return PrimaryDescriptorIdentity(
        device: info.st_dev,
        inode: info.st_ino,
        rdev: info.st_rdev,
        mode: info.st_mode)
}

private func primaryDescriptorAliases(
    of identity: PrimaryDescriptorIdentity
) throws -> [Int32] {
#if os(macOS)
    let descriptorDirectory = "/dev/fd"
#else
    let descriptorDirectory = "/proc/self/fd"
#endif
    return try FileManager.default.contentsOfDirectory(atPath: descriptorDirectory)
        .compactMap(Int32.init)
        .filter { descriptor in
            guard let candidate = try? primaryDescriptorIdentity(descriptor) else {
                return false
            }
            return candidate == identity
        }
}

private func primaryAliasCount(of identity: PrimaryDescriptorIdentity) throws -> Int {
    try primaryDescriptorAliases(of: identity).count
}

private func descriptorRefersToSameOpenFile(
    _ descriptor: Int32,
    as identity: PrimaryDescriptorIdentity
) -> Bool {
    guard let current = try? primaryDescriptorIdentity(descriptor) else {
        return false
    }
    return current == identity
}

private func waitUntilPrimaryDescriptorCloses(
    number: Int32,
    identity: PrimaryDescriptorIdentity,
    timeout: TimeInterval
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !descriptorRefersToSameOpenFile(number, as: identity) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.001)
    }
    return !descriptorRefersToSameOpenFile(number, as: identity)
}

/// Reserves exactly `target` from an owned, unrelated descriptor. Only a
/// duplicate returned by F_DUPFD_CLOEXEC is closed while retrying; the source
/// descriptor and any other number are never touched.
private func reservePrimarySlot(at target: Int32, from source: Int32) throws -> Int32 {
    for _ in 0..<400 {
        let duplicate = fcntl(source, F_DUPFD_CLOEXEC, target)
        if duplicate < 0 {
            throw PrimaryDescriptorTestError.couldNotDuplicateDescriptor(source, errno)
        }
        if duplicate == target {
            return duplicate
        }
        close(duplicate)
        Thread.sleep(forTimeInterval: 0.001)
    }
    throw PrimaryDescriptorTestError.couldNotReserveDescriptor(target)
}

private func heldChildArguments(
    readyPath: String,
    commandPath: String,
    lifetimePath: String,
    ignoreTerm: Bool
) -> [String] {
    let trap = ignoreTerm ? "trap '' HUP TERM" : "trap '' HUP"
    let script = """
        stty -echo 2>/dev/null
        exec 3>"$1"
        exec 4>"$3"
        printf ready >&3
        \(trap)
        IFS= read -r line <"$2"
        exit 0
        """
    return ["-c", script, "sh", readyPath, commandPath, lifetimePath]
}

/// Ends a test-owned process: SIGTERM first, then SIGKILL for children that
/// ignore it. This never touches a reused PID because it reads shellPid.
private func closeTestDescriptor(_ descriptor: Int32) {
#if os(macOS)
    Darwin.close(descriptor)
#else
    close(descriptor)
#endif
}

private func forceEndChild(_ process: LocalProcess) {
    process.terminate()
    let pid = process.shellPid
    if pid > 0 {
        kill(pid, SIGKILL)
    }
}

/// Serialized: these tests observe scheduling-dependent descriptor and process
/// transitions, so they must not compete with one another for those windows.
@Suite(.serialized)
final class LocalProcessPrimaryDescriptorTests {
    // MARK: - Task 3: locked caller-owned acquisition

    @Test func acquisitionWinsEOFRetainsOwnedCLOEXECPrimary() throws {
        // Break caught: duplication rechecks childfd outside the session lock,
        // so EOF retires the primary before the duplicate runs and the caller
        // receives no owned descriptor or one unrelated to this PTY.
        let fifo = try PrimaryFifo()
        defer { fifo.close() }
        let delegate = PrimaryTestDelegate()
        let duplicateEntered = DispatchSemaphore(value: 0)
        let finishDuplicate = DispatchSemaphore(value: 0)
        let duplicateCalls = Locked(0)
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.primary.eof-wins-acquisition"),
            duplicateDescriptor: { fcntl($0, F_DUPFD_CLOEXEC, 0) },
            duplicatePrimary: { fd in
                duplicateCalls.withLock { $0 += 1 }
                duplicateEntered.signal()
                finishDuplicate.wait()
                return fcntl(fd, F_DUPFD_CLOEXEC, 0)
            })
        defer { forceEndChild(process) }

        fifo.startChild(process, ignoreTerm: false)
        #expect(fifo.waitForToken(Array("ready".utf8), timeout: 3))
        let primary = process.childfd
        #expect(primary >= 0)
        let identity = try primaryDescriptorIdentity(primary)

        let acquired = Locked<Result<Int32?, LocalProcessError>>(.failure(.notRunning))
        let acquisitionDone = TestThreadCompletion()
        let launchBox = TestBox(process)
        let acquisitionThread = Thread {
            let result = launchBox.value.duplicatePrimaryDescriptor()
            acquired.withLock { $0 = result }
            acquisitionDone.signal()
        }
        acquisitionThread.name = "swiftterm-test-primary-acquisition"
        acquisitionThread.start()

        #expect(duplicateEntered.wait(timeout: .now() + 2) == .success)
        // Request EOF while the duplicate syscall is paused under the session
        // lock. The child exits after reading its command byte, and the
        // pipeline then blocks on the same lock before invalidating childfd.
        #expect(fifo.releaseChild())
        #expect(!acquisitionDone.wait(timeout: 0.2))
        finishDuplicate.signal()
        #expect(acquisitionDone.wait(timeout: 2))
        #expect(delegate.waitForTermination(count: 1, timeout: 5))

        let result = acquired.withLock { $0 }
        switch result {
        case .success(let descriptor?):
            #expect(descriptor >= 0)
            #expect(descriptor != primary)
            #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
            let description = try primaryDescriptorIdentity(descriptor)
            #expect(description == identity)
            #expect(process.childfd == -1)
            #expect(!process.running)
            close(descriptor)
        case .success(nil), .failure:
            Issue.record("Acquisition that won EOF did not retain an owned duplicate")
        }
        #expect(duplicateCalls.withLock { $0 } == 1)

        // A terminating phase with a live attached child that ignores TERM
        // must also transfer an owned duplicate: the published primary stays
        // valid for the foreground ending path.
        let terminatingFifo = try PrimaryFifo()
        defer { terminatingFifo.close() }
        let terminatingDelegate = PrimaryTestDelegate()
        let terminatingProcess = LocalProcess(
            delegate: terminatingDelegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.primary.terminating-acquisition"))
        defer { forceEndChild(terminatingProcess) }
        terminatingFifo.startChild(terminatingProcess, ignoreTerm: true)
        #expect(terminatingFifo.waitForToken(Array("ready".utf8), timeout: 3))
        let terminatingPrimary = terminatingProcess.childfd
        #expect(terminatingPrimary >= 0)
        let terminatingIdentity = try primaryDescriptorIdentity(terminatingPrimary)
        terminatingProcess.terminate()
        #expect(terminatingProcess.running)
        switch terminatingProcess.duplicatePrimaryDescriptor() {
        case .success(let descriptor?):
            #expect(descriptor >= 0)
            #expect(descriptor != terminatingPrimary)
            #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
            let description = try primaryDescriptorIdentity(descriptor)
            #expect(description == terminatingIdentity)
            close(descriptor)
        case .success(nil), .failure:
            Issue.record("Terminating acquisition did not retain an owned duplicate")
        }
        forceEndChild(terminatingProcess)
        #expect(terminatingDelegate.waitForTermination(count: 1, timeout: 5))
    }

    @Test func eofWinsAcquisitionNeverTouchesReusedNumber() throws {
        // Break caught: the API duplicates a former primary number after EOF
        // closed it, transferring an unrelated file that reused that slot.
        let fifo = try PrimaryFifo()
        defer { fifo.close() }
        let delegate = PrimaryTestDelegate()
        let duplicateCalls = Locked(0)
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.primary.eof-first"),
            duplicatePrimary: { fd in
                duplicateCalls.withLock { $0 += 1 }
                return fcntl(fd, F_DUPFD_CLOEXEC, 0)
            })
        let unrelated = try OwnedUnrelatedFile()
        defer {
            forceEndChild(process)
            unrelated.close()
        }

        fifo.startChild(process, ignoreTerm: false)
        #expect(fifo.waitForToken(Array("ready".utf8), timeout: 3))
        let formerPrimary = process.childfd
        #expect(formerPrimary >= 0)
        let unrelatedFlagsBefore = fcntl(unrelated.descriptor, F_GETFD)
        #expect(unrelatedFlagsBefore >= 0)
        let unrelatedIdentity = try primaryDescriptorIdentity(unrelated.descriptor)

        #expect(fifo.releaseChild())
        #expect(delegate.waitForTermination(count: 1, timeout: 5))
        #expect(process.childfd == -1)
        #expect(!process.running)

        let reserved = try reservePrimarySlot(at: formerPrimary, from: unrelated.descriptor)
        defer { close(reserved) }
        let reservedIdentity = try primaryDescriptorIdentity(reserved)
        #expect(reservedIdentity == unrelatedIdentity)

        switch process.duplicatePrimaryDescriptor() {
        case .success(nil):
            break
        case .success(let descriptor?):
            close(descriptor)
            Issue.record("Acquisition transferred a reused descriptor number")
        case .failure:
            Issue.record("Unpublished acquisition reported a syscall failure")
        }
        #expect(duplicateCalls.withLock { $0 } == 0)
        let survivingIdentity = try primaryDescriptorIdentity(reserved)
        #expect(survivingIdentity == unrelatedIdentity)
        #expect(fcntl(unrelated.descriptor, F_GETFD) == unrelatedFlagsBefore)
    }

    @Test func unpublishedPhasesReturnNilWithoutDescriptorOperation() throws {
        // Break caught: idle/starting/exited/windingDown or EOF-unpublished
        // states call the duplicate syscall and return an unowned descriptor.
        let idleCalls = Locked(0)
        let idleDelegate = PrimaryTestDelegate()
        let idleProcess = LocalProcess(
            delegate: idleDelegate,
            duplicatePrimary: { fd in
                idleCalls.withLock { $0 += 1 }
                return fcntl(fd, F_DUPFD_CLOEXEC, 0)
            })
        switch idleProcess.duplicatePrimaryDescriptor() {
        case .success(nil):
            break
        case .success(let descriptor?):
            close(descriptor)
            Issue.record("Idle acquisition returned a descriptor")
        case .failure:
            Issue.record("Idle acquisition reported a syscall failure")
        }
        #expect(idleCalls.withLock { $0 } == 0)

        // Starting: block the delegate's window-size request, which the launch
        // calls before the fork, while the test asks for the primary.
        let startingCalls = Locked(0)
        let startingDelegate = PrimaryTestDelegate()
        let startingEntry = DispatchSemaphore(value: 0)
        let startingRelease = DispatchSemaphore(value: 0)
        startingDelegate.windowSizeEntry = startingEntry
        startingDelegate.windowSizeRelease = startingRelease
        let startingProcess = LocalProcess(
            delegate: startingDelegate,
            duplicatePrimary: { fd in
                startingCalls.withLock { $0 += 1 }
                return fcntl(fd, F_DUPFD_CLOEXEC, 0)
            })
        let startingBox = TestBox(startingProcess)
        let launchThread = Thread {
            startingBox.value.startProcess(
                executable: "/bin/sh", args: ["-c", "exit 0"])
        }
        launchThread.name = "swiftterm-test-primary-starting"
        launchThread.start()
        defer {
            startingRelease.signal()
            _ = startingDelegate.waitForTermination(count: 1, timeout: 5)
        }
        #expect(startingEntry.wait(timeout: .now() + 2) == .success)
        #expect(startingProcess.childfd == -1)
        #expect(!startingProcess.running)
        #expect(!startingProcess.windingDown)
        switch startingProcess.duplicatePrimaryDescriptor() {
        case .success(nil):
            break
        case .success(let descriptor?):
            close(descriptor)
            Issue.record("Starting acquisition returned a descriptor")
        case .failure:
            Issue.record("Starting acquisition reported a syscall failure")
        }
        #expect(startingCalls.withLock { $0 } == 0)
        startingRelease.signal()
        #expect(startingDelegate.waitForTermination(count: 1, timeout: 5))

        // Exited during a controlled slow drain: the child is reaped and its
        // primary unpublished, while the pipeline drain is still running.
        let exitedCalls = Locked(0)
        let exitedDelegate = PrimaryTestDelegate()
        let dataEntry = DispatchSemaphore(value: 0)
        let dataRelease = DispatchSemaphore(value: 0)
        exitedDelegate.dataEntry = dataEntry
        exitedDelegate.dataRelease = dataRelease
        let exitedProcess = LocalProcess(
            delegate: exitedDelegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.primary.exited-drain"),
            directDelivery: true,
            duplicatePrimary: { fd in
                exitedCalls.withLock { $0 += 1 }
                return fcntl(fd, F_DUPFD_CLOEXEC, 0)
            })
        defer {
            dataRelease.signal()
            _ = exitedDelegate.waitForTermination(count: 1, timeout: 5)
        }
        exitedProcess.drainTimeout = 10
        if case .failure(let error) = exitedProcess.startProcessChecked(
            executable: "/bin/sh",
            args: ["-c", "stty -echo 2>/dev/null; printf x; exit 0"]) {
            Issue.record("Slow-drain launch failed: \(error)")
            return
        }
        #expect(dataEntry.wait(timeout: .now() + 5) == .success)
        let exitedDeadline = Date().addingTimeInterval(5)
        while !(exitedProcess.shellPid == 0 && exitedProcess.childfd == -1),
              Date() < exitedDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        #expect(exitedProcess.shellPid == 0)
        #expect(exitedProcess.childfd == -1)
        #expect(exitedProcess.running)
        #expect(!exitedProcess.windingDown)
        switch exitedProcess.duplicatePrimaryDescriptor() {
        case .success(nil):
            break
        case .success(let descriptor?):
            close(descriptor)
            Issue.record("Exited-drain acquisition returned a descriptor")
        case .failure:
            Issue.record("Exited-drain acquisition reported a syscall failure")
        }
        #expect(exitedCalls.withLock { $0 } == 0)
        dataRelease.signal()
        #expect(exitedDelegate.waitForTermination(count: 1, timeout: 5))

        // Winding down: an unchecked launch failure awaits callback delivery
        // on a suspended queue. The phase is real `.windingDown`, and no
        // primary is published while the failure is pending.
        let queue = DispatchQueue(label: "SwiftTerm.primary.winding-down")
        queue.suspend()
        let resumed = Locked(false)
        let windingCalls = Locked(0)
        let windingDelegate = PrimaryTestDelegate()
        let windingProcess = LocalProcess(
            delegate: windingDelegate,
            dispatchQueue: queue,
            duplicateDescriptor: { _ in
                errno = EMFILE
                return -1
            },
            duplicatePrimary: { fd in
                windingCalls.withLock { $0 += 1 }
                return fcntl(fd, F_DUPFD_CLOEXEC, 0)
            })
        defer {
            let shouldResume = resumed.withLock { value -> Bool in
                defer { value = true }
                return !value
            }
            if shouldResume {
                queue.resume()
            }
            _ = windingDelegate.waitForFailure(timeout: 5)
        }
        windingProcess.startProcess(executable: "/bin/sh", args: ["-c", "exit 0"])
        let windingDeadline = Date().addingTimeInterval(5)
        while !windingProcess.windingDown, Date() < windingDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        #expect(windingProcess.windingDown)
        switch windingProcess.duplicatePrimaryDescriptor() {
        case .success(nil):
            break
        case .success(let descriptor?):
            close(descriptor)
            Issue.record("Winding-down acquisition returned a descriptor")
        case .failure:
            Issue.record("Winding-down acquisition reported a syscall failure")
        }
        #expect(windingCalls.withLock { $0 } == 0)
        resumed.withLock { $0 = true }
        queue.resume()
        #expect(windingDelegate.waitForFailure(timeout: 5))

        // EOF while the phase remains running: the pipeline's identity-checked
        // EOF callback unpublishes the primary while the exit transaction is
        // still queued on a suspended delivery queue. The child has ended, but
        // publication, not a claimed exit, is what the API observes.
        let eofQueue = DispatchQueue(label: "SwiftTerm.primary.eof-running")
        eofQueue.suspend()
        let eofResumed = Locked(false)
        let eofCalls = Locked(0)
        let eofDelegate = PrimaryTestDelegate()
        let eofFifo = try PrimaryFifo()
        defer {
            eofFifo.close()
            let shouldResume = eofResumed.withLock { value -> Bool in
                defer { value = true }
                return !value
            }
            if shouldResume {
                eofQueue.resume()
            }
        }
        let eofProcess = LocalProcess(
            delegate: eofDelegate,
            dispatchQueue: eofQueue,
            directDelivery: true,
            duplicatePrimary: { fd in
                eofCalls.withLock { $0 += 1 }
                return fcntl(fd, F_DUPFD_CLOEXEC, 0)
            })
        if case .failure(let error) = eofProcess.startProcessChecked(
            executable: "/bin/sh",
            args: heldChildArguments(
                readyPath: eofFifo.readyPath,
                commandPath: eofFifo.commandPath,
                lifetimePath: eofFifo.lifetimePath,
                ignoreTerm: false)) {
            Issue.record("EOF-running launch failed: \(error)")
            return
        }
        #expect(eofFifo.waitForToken(Array("ready".utf8), timeout: 3))
        #expect(eofFifo.releaseChild())
        let eofDeadline = Date().addingTimeInterval(5)
        while eofProcess.childfd != -1, Date() < eofDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        let eofPrimaryUnpublished = eofProcess.childfd == -1
        #expect(eofPrimaryUnpublished)
        let eofStillRunning = eofProcess.running
        #expect(eofStillRunning)
        let eofPidPublished = eofProcess.shellPid > 0
        #expect(eofPidPublished)
        switch eofProcess.duplicatePrimaryDescriptor() {
        case .success(nil):
            break
        case .success(let descriptor?):
            close(descriptor)
            Issue.record("EOF-unpublished acquisition returned a descriptor")
        case .failure:
            Issue.record("EOF-unpublished acquisition reported a syscall failure")
        }
        #expect(eofCalls.withLock { $0 } == 0)
        eofResumed.withLock { $0 = true }
        eofQueue.resume()
        #expect(eofDelegate.waitForTermination(count: 1, timeout: 5))
    }

    @Test func childExitAndAcquisitionSerializeWithoutForeignAliases() throws {
        // Break caught: the duplicate transaction races the reaper and returns
        // a descriptor for a reused number instead of this PTY or nil.
        let fifo = try PrimaryFifo()
        defer { fifo.close() }
        let delegate = PrimaryTestDelegate()
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.primary.child-exit"),
            duplicatePrimary: { fcntl($0, F_DUPFD_CLOEXEC, 0) })
        defer { forceEndChild(process) }

        fifo.startChild(process, ignoreTerm: false)
        #expect(fifo.waitForToken(Array("ready".utf8), timeout: 3))
        let primary = process.childfd
        #expect(primary >= 0)
        let identity = try primaryDescriptorIdentity(primary)
        switch process.duplicatePrimaryDescriptor() {
        case .success(let descriptor?):
            let description = try primaryDescriptorIdentity(descriptor)
            #expect(description == identity)
            close(descriptor)
        case .success(nil), .failure:
            Issue.record("Running acquisition did not produce an owned primary duplicate")
        }

        let successes = Locked(0)
        let foreign = Locked(0)
        let nilResults = Locked(0)
        let firstSuccess = DispatchSemaphore(value: 0)
        let loopDone = TestThreadCompletion()
        let box = TestBox(process)
        let loop = Thread {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                switch box.value.duplicatePrimaryDescriptor() {
                case .success(let descriptor?):
                    let count = successes.withLock { value -> Int in
                        value += 1
                        return value
                    }
                    let matches = (try? primaryDescriptorIdentity(descriptor)) == identity
                    close(descriptor)
                    if !matches {
                        foreign.withLock { $0 += 1 }
                    }
                    if count == 1 {
                        firstSuccess.signal()
                    }
                case .success(nil):
                    nilResults.withLock { $0 += 1 }
                    loopDone.signal()
                    return
                case .failure:
                    foreign.withLock { $0 += 1 }
                    loopDone.signal()
                    return
                }
            }
            loopDone.signal()
        }
        loop.name = "swiftterm-test-primary-child-exit"
        loop.start()
        // Serialized by the session lock, the loop observes real owned
        // duplicates before the child exit completes.
        #expect(firstSuccess.wait(timeout: .now() + 2) == .success)
        #expect(fifo.releaseChild())
        #expect(loopDone.wait(timeout: 5))
        #expect(delegate.waitForTermination(count: 1, timeout: 5))

        #expect(successes.withLock { $0 } > 0)
        #expect(foreign.withLock { $0 } == 0)
        #expect(nilResults.withLock { $0 } > 0)
        switch process.duplicatePrimaryDescriptor() {
        case .success(nil):
            break
        case .success(let descriptor?):
            close(descriptor)
            Issue.record("Acquisition after child teardown returned a descriptor")
        case .failure:
            Issue.record("Acquisition after child teardown reported a syscall failure")
        }
    }

    @Test func stalePipelineEOFCannotInvalidateReplacementSession() throws {
        // Break caught: a foreign pipeline's EOF callback retires the
        // replacement process's published primary after a real
        // callback-driven relaunch.
        let firstFifo = try PrimaryFifo()
        defer { firstFifo.close() }
        let secondFifo = try PrimaryFifo()
        defer { secondFifo.close() }
        let delegate = PrimaryTestDelegate()
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.primary.stale-pipeline"))
        defer { forceEndChild(process) }
        delegate.onTermination = {
            secondFifo.startChild(process, ignoreTerm: false)
        }

        firstFifo.startChild(process, ignoreTerm: false)
        #expect(firstFifo.waitForToken(Array("ready".utf8), timeout: 3))
        #expect(firstFifo.releaseChild())
        #expect(delegate.waitForTermination(count: 1, timeout: 5))
        #expect(process.childfd == -1)
        #expect(secondFifo.waitForToken(Array("ready".utf8), timeout: 3))
        let replacementPrimary = process.childfd
        #expect(replacementPrimary >= 0)
        let replacementIdentity = try primaryDescriptorIdentity(replacementPrimary)

        let staleDelegate = StalePipelineDelegate()
        let stalePipeline = TerminalIOPipeline(fd: -1, delegate: staleDelegate)
        process.pipelineDidReachEOF(stalePipeline)
        let replacementAfterStale = try primaryDescriptorIdentity(replacementPrimary)
        #expect(replacementAfterStale == replacementIdentity)
        #expect(process.childfd == replacementPrimary)
        withExtendedLifetime(stalePipeline) {}

        switch process.duplicatePrimaryDescriptor() {
        case .success(let descriptor?):
            let description = try primaryDescriptorIdentity(descriptor)
            #expect(description == replacementIdentity)
            close(descriptor)
        case .success(nil), .failure:
            Issue.record("Stale EOF retired the replacement primary")
        }

        forceEndChild(process)
        #expect(delegate.waitForTermination(count: 2, timeout: 5))
    }

    @Test func pipelineStartFailureSerializesWithOwnedAcquisition() throws {
        // Break caught: startup-failure invalidation and acquisition disagree
        // about publication, returning a closed descriptor or invalidating a
        // replacement slot without the session lock.
        let fifo = try PrimaryFifo()
        defer { fifo.close() }
        let prepareEntered = DispatchSemaphore(value: 0)
        let finishPrepare = DispatchSemaphore(value: 0)
        let delegate = PrimaryTestDelegate()
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.primary.startup-failure"),
            duplicateDescriptor: { fcntl($0, F_DUPFD_CLOEXEC, 0) },
            duplicatePrimary: { fcntl($0, F_DUPFD_CLOEXEC, 0) },
            preparePipelineDescriptor: { _ in
                prepareEntered.signal()
                finishPrepare.wait()
                return false
            })
        let unrelated = try OwnedUnrelatedFile()
        defer {
            forceEndChild(process)
            unrelated.close()
        }

        let arguments = heldChildArguments(
            readyPath: fifo.readyPath,
            commandPath: fifo.commandPath,
            lifetimePath: fifo.lifetimePath,
            ignoreTerm: true)
        let launchDone = TestThreadCompletion()
        let launchBox = TestBox(process)
        let launchThread = Thread {
            _ = launchBox.value.startProcessChecked(
                executable: "/bin/sh",
                args: arguments)
            launchDone.signal()
        }
        launchThread.name = "swiftterm-test-primary-launch"
        launchThread.start()
        #expect(fifo.waitForToken(Array("ready".utf8), timeout: 3))
        #expect(prepareEntered.wait(timeout: .now() + 2) == .success)
        let formerPrimary = process.childfd
        #expect(formerPrimary >= 0)
        let identity = try primaryDescriptorIdentity(formerPrimary)
        switch process.duplicatePrimaryDescriptor() {
        case .success(let descriptor?):
            let description = try primaryDescriptorIdentity(descriptor)
            #expect(description == identity)
            #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
            close(descriptor)
        case .success(nil), .failure:
            Issue.record("Acquisition before startup failure did not own the primary")
        }
        finishPrepare.signal()
        #expect(launchDone.wait(timeout: 2))
        #expect(process.childfd == -1)
        #expect(!process.windingDown)
        #expect(process.running)
        forceEndChild(process)
        #expect(delegate.waitForTermination(count: 1, timeout: 5))

        let reserved = try reservePrimarySlot(at: formerPrimary, from: unrelated.descriptor)
        defer { close(reserved) }
        let reservedIdentity = try primaryDescriptorIdentity(reserved)
        process.terminate()
        Thread.sleep(forTimeInterval: 0.05)
        let survivingIdentity = try primaryDescriptorIdentity(reserved)
        #expect(survivingIdentity == reservedIdentity)

        // Startup failure before acquisition: the start-failure invalidation
        // wins and the API returns nil without touching the closed number.
        let secondFifo = try PrimaryFifo()
        defer { secondFifo.close() }
        let failureDelegate = PrimaryTestDelegate()
        let failureCalls = Locked(0)
        let failureProcess = LocalProcess(
            delegate: failureDelegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.primary.startup-failure-second"),
            duplicatePrimary: { fd in
                failureCalls.withLock { $0 += 1 }
                return fcntl(fd, F_DUPFD_CLOEXEC, 0)
            },
            preparePipelineDescriptor: { _ in false })
        defer { forceEndChild(failureProcess) }
        if case .failure(let error) = failureProcess.startProcessChecked(
            executable: "/bin/sh",
            args: heldChildArguments(
                readyPath: secondFifo.readyPath,
                commandPath: secondFifo.commandPath,
                lifetimePath: secondFifo.lifetimePath,
                ignoreTerm: true)) {
            Issue.record("Startup-failure launch failed: \(error)")
            return
        }
        #expect(failureProcess.childfd == -1)
        #expect(failureProcess.running)
        switch failureProcess.duplicatePrimaryDescriptor() {
        case .success(nil):
            break
        case .success(let descriptor?):
            close(descriptor)
            Issue.record("Startup failure left the invalidated primary acquirable")
        case .failure:
            Issue.record("Startup failure acquisition reported a syscall failure")
        }
        #expect(failureCalls.withLock { $0 } == 0)
        forceEndChild(failureProcess)
        #expect(failureDelegate.waitForTermination(count: 1, timeout: 5))
    }

    @Test func duplicateErrnoDoesNotTransferOrClosePrimary() throws {
        // Break caught: a failed F_DUPFD_CLOEXEC is treated as success, closes
        // the primary, or leaks an alias while reporting the typed errno.
        let fifo = try PrimaryFifo()
        defer { fifo.close() }
        let failOnce = Locked(true)
        let delegate = PrimaryTestDelegate()
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.primary.duplicate-emfile"),
            duplicatePrimary: { fd in
                let shouldFail = failOnce.withLock { value -> Bool in
                    defer { value = false }
                    return value
                }
                if shouldFail {
                    errno = EMFILE
                    return -1
                }
                return fcntl(fd, F_DUPFD_CLOEXEC, 0)
            })
        defer { forceEndChild(process) }
        fifo.startChild(process, ignoreTerm: false)
        #expect(fifo.waitForToken(Array("ready".utf8), timeout: 3))
        let primary = process.childfd
        #expect(primary >= 0)
        let identity = try primaryDescriptorIdentity(primary)
        let aliasesBefore = try primaryAliasCount(of: identity)
        let flagsBefore = fcntl(primary, F_GETFD)

        switch process.duplicatePrimaryDescriptor() {
        case .failure(.descriptorDuplicationFailed(EMFILE)):
            break
        case .failure(let error):
            Issue.record("Unexpected duplication error: \(error)")
        case .success:
            Issue.record("EMFILE duplication reported success")
        }
        let primaryAfterFailure = try primaryDescriptorIdentity(primary)
        #expect(primaryAfterFailure == identity)
        #expect(fcntl(primary, F_GETFD) == flagsBefore)
        let aliasesAfterFailure = try primaryAliasCount(of: identity)
        #expect(aliasesAfterFailure == aliasesBefore)
        #expect(!process.windingDown)

        switch process.duplicatePrimaryDescriptor() {
        case .success(let descriptor?):
            let description = try primaryDescriptorIdentity(descriptor)
            #expect(description == identity)
            close(descriptor)
        case .success(nil):
            Issue.record("The still-published primary disappeared after a failed duplicate")
        case .failure(let error):
            Issue.record("Acquisition after EMFILE failed: \(error)")
        }
        let aliasesAfterSuccess = try primaryAliasCount(of: identity)
        #expect(aliasesAfterSuccess == aliasesBefore)
        #expect(delegate.terminationCount == 0)
        #expect(fifo.releaseChild())
        #expect(delegate.waitForTermination(count: 1, timeout: 5))
        #expect(delegate.exitCode == 0)
    }

    @Test func ownerTeardownWaitsForAcquisitionThenClosesOnlyPrimary() throws {
        // Break caught: teardown closes the caller's duplicate, waits for the
        // pipeline or child under the session lock, or double-closes a slot
        // that has been safely reserved after the primary closed.
        let fifo = try PrimaryFifo()
        defer { fifo.close() }
        let unrelated = try OwnedUnrelatedFile()
        defer { unrelated.close() }
        let delegate = PrimaryTestDelegate()
        let released = WeakProcessReference()

        // The owner must leave this function scope to deallocate; a guard-let
        // binding would keep it alive until the test ends.
        func startAcquireAndRelease() -> (
            primary: Int32,
            identity: PrimaryDescriptorIdentity?,
            owned: Int32,
            ownedFlags: Int32,
            unrelatedFlagsBefore: Int32
        ) {
            let process = LocalProcess(
                delegate: delegate,
                dispatchQueue: DispatchQueue(label: "SwiftTerm.primary.owner-teardown"),
                duplicatePrimary: { fcntl($0, F_DUPFD_CLOEXEC, 0) })
            released.value = process
            fifo.startChild(process, ignoreTerm: true)
            let primary = process.childfd
            let identity = try? primaryDescriptorIdentity(primary)
            let unrelatedFlagsBefore = fcntl(unrelated.descriptor, F_GETFD)
            let owned: Int32
            switch process.duplicatePrimaryDescriptor() {
            case .success(let descriptor?):
                owned = descriptor
            case .success(nil), .failure:
                owned = -1
            }
            return (primary, identity, owned, fcntl(owned, F_GETFD), unrelatedFlagsBefore)
        }
        let acquired = startAcquireAndRelease()
        let primary = acquired.primary
        let identity = acquired.identity
        let owned = acquired.owned
        let ownedFlags = acquired.ownedFlags
        let unrelatedFlagsBefore = acquired.unrelatedFlagsBefore
        defer {
            if owned >= 0 {
                close(owned)
            }
        }
        #expect(primary >= 0)
        #expect(owned >= 0)
        #expect(identity != nil)
        if let identity {
            let ownedIdentity = try primaryDescriptorIdentity(owned)
            #expect(ownedIdentity == identity)
        }
        #expect(fcntl(owned, F_GETFD) & FD_CLOEXEC != 0)

        let releaseDeadline = Date().addingTimeInterval(2)
        while released.value != nil, Date() < releaseDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        #expect(released.value == nil)

        if let identity {
            let primaryClosed = waitUntilPrimaryDescriptorCloses(
                number: primary,
                identity: identity,
                timeout: 3)
            #expect(primaryClosed)
        }
        let childEnded = fifo.waitForLifetimeEnd(timeout: 3)
        #expect(childEnded)
        if let identity {
            let ownedAfterTeardown = try primaryDescriptorIdentity(owned)
            #expect(ownedAfterTeardown == identity)
        }
        #expect(fcntl(owned, F_GETFD) == ownedFlags)

        let reserved = try reservePrimarySlot(at: primary, from: unrelated.descriptor)
        defer { close(reserved) }
        let reservedIdentity = try primaryDescriptorIdentity(reserved)
        Thread.sleep(forTimeInterval: 0.2)
        let survivingIdentity = try primaryDescriptorIdentity(reserved)
        #expect(survivingIdentity == reservedIdentity)
        #expect(fcntl(unrelated.descriptor, F_GETFD) == unrelatedFlagsBefore)
    }

    // MARK: - Task 4: primary close-on-exec setup

    @Test func publishedPrimaryPreservesFlagsAndIsCloseOnExec() throws {
        // Break caught: the published primary lacks FD_CLOEXEC, so a later
        // exec inherits it; F_SETFD also fails to preserve prior flags, or
        // primary setup runs after the write alias is created.
        let fifo = try PrimaryFifo()
        defer { fifo.close() }
        let recorder = PrimarySetupRecorder()
        let delegate = PrimaryTestDelegate()
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.primary.cloexec"),
            duplicateDescriptor: { fd in
                recorder.recordWriteAlias()
                return fcntl(fd, F_DUPFD_CLOEXEC, 0)
            },
            duplicatePrimary: { fcntl($0, F_DUPFD_CLOEXEC, 0) },
            primaryDescriptorControl: { fd, command, value in
                recorder.recordControl(fd: fd, command: command, value: value)
            })
        defer { forceEndChild(process) }
        fifo.startChild(process, ignoreTerm: false)
        #expect(fifo.waitForToken(Array("ready".utf8), timeout: 3))
        let primary = process.childfd
        #expect(primary >= 0)
        let identity = try primaryDescriptorIdentity(primary)
        let primaryFlags = fcntl(primary, F_GETFD)
        #expect(primaryFlags >= 0)
        #expect(primaryFlags & FD_CLOEXEC != 0)

        let events = recorder.snapshot()
        let getFlags = events.first { $0.kind == .getFlags }
        let setFlags = events.first { $0.kind == .setFlags }
        #expect(getFlags != nil)
        #expect(setFlags != nil)
        if let getFlags, let setFlags {
            #expect(getFlags.fd == primary)
            #expect(setFlags.fd == primary)
            #expect(setFlags.value & FD_CLOEXEC != 0)
            let preservedFlags = (setFlags.value & ~FD_CLOEXEC)
            let originalFlags = (getFlags.result & ~FD_CLOEXEC)
            #expect(preservedFlags == originalFlags)
        }
        if let setIndex = events.firstIndex(where: { $0.kind == .setFlags }),
           let aliasIndex = events.firstIndex(where: { $0.kind == .writeAlias }) {
            #expect(setIndex < aliasIndex)
        } else {
            Issue.record("Primary setup or write-alias creation was not recorded")
        }

        let aliases = try primaryDescriptorAliases(of: identity)
        #expect(aliases.count >= 2)
        switch process.duplicatePrimaryDescriptor() {
        case .success(let descriptor?):
            #expect(descriptor >= 0)
            #expect(descriptor != primary)
            #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
            let description = try primaryDescriptorIdentity(descriptor)
            #expect(description == identity)
            let probeDescriptors = aliases.map(String.init) + [String(descriptor)]
            let probeDelegate = PrimaryTestDelegate()
            let probe = LocalProcess(delegate: probeDelegate)
            defer { forceEndChild(probe) }
            let probeScript = """
                for fd in \(probeDescriptors.joined(separator: " ")); do
                    if test -t "$fd"; then
                        printf 'inherited PTY: %s' "$fd"
                        exit 1
                    fi
                done
                printf isolated
                """
            if case .failure(let error) = probe.startProcessChecked(
                executable: "/bin/sh", args: ["-c", probeScript, "descriptor-probe"]) {
                Issue.record("Descriptor probe launch failed: \(error)")
            } else {
                let ended = probeDelegate.waitForTermination(count: 1, timeout: 5)
                #expect(ended)
                #expect(probeDelegate.exitCode == 0)
                let probeOutput = String(decoding: probeDelegate.receivedData(), as: UTF8.self)
                #expect(probeOutput == "isolated")
            }
            close(descriptor)
        case .success(nil), .failure:
            Issue.record("Published primary was not acquirable")
        }

        #expect(fifo.releaseChild())
        #expect(delegate.waitForTermination(count: 1, timeout: 5))
    }

    @Test func primaryGetFlagsFailureClosesUnpublishedMasterAndReapsChild() throws {
        // Break caught: an F_GETFD failure publishes or leaks the primary, or
        // returns a launch failure without reaping the forked child.
        let fifo = try PrimaryFifo()
        defer { fifo.close() }
        let sawReady = Locked(false)
        let delegate = PrimaryTestDelegate()
        var failFirstGet = true
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.primary.getflags-failure"),
            primaryDescriptorControl: { fd, command, value in
                if command == F_GETFD && failFirstGet {
                    failFirstGet = false
                    sawReady.withLock { $0 = fifo.waitForToken(Array("ready".utf8), timeout: 2) }
                    errno = EIO
                    return -1
                }
                return fcntl(fd, command, value)
            })
        defer { forceEndChild(process) }
        switch process.startProcessChecked(
            executable: "/bin/sh",
            args: heldChildArguments(
                readyPath: fifo.readyPath,
                commandPath: fifo.commandPath,
                lifetimePath: fifo.lifetimePath,
                ignoreTerm: true)) {
        case .failure(.primaryDescriptorSetupFailed(EIO)):
            break
        case .failure(let error):
            Issue.record("Unexpected launch failure: \(error)")
            return
        case .success:
            Issue.record("F_GETFD failure launched successfully")
            return
        }
        #expect(sawReady.withLock { $0 })
        #expect(process.childfd == -1)
        #expect(process.shellPid == 0)
        #expect(!process.running)
        #expect(!process.windingDown)
        #expect(delegate.failureCount == 0)
        #expect(delegate.terminationCount == 0)
        // The readiness pull holds its own live descriptor, so child death is
        // proven by the child's independent lifetime channel, not by that EOF.
        #expect(fifo.waitForLifetimeEnd(timeout: 3))

        if case .failure(let error) = process.startProcessChecked(
            executable: "/bin/sh", args: ["-c", "exit 0"]) {
            Issue.record("Relaunch after F_GETFD failure failed: \(error)")
        }
        #expect(delegate.waitForTermination(count: 1, timeout: 5))
        #expect(delegate.exitCode == 0)
    }

    @Test func primarySetFlagsFailureClosesUnpublishedMasterAndReapsChild() throws {
        // Break caught: an F_SETFD failure after a successful F_GETFD leaves
        // the primary open or the forked child unreaped.
        let fifo = try PrimaryFifo()
        defer { fifo.close() }
        let sawReady = Locked(false)
        let delegate = PrimaryTestDelegate()
        var failFirstSet = true
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: DispatchQueue(label: "SwiftTerm.primary.setflags-failure"),
            primaryDescriptorControl: { fd, command, value in
                if command == F_GETFD {
                    sawReady.withLock { $0 = fifo.waitForToken(Array("ready".utf8), timeout: 2) }
                }
                if command == F_SETFD && failFirstSet {
                    failFirstSet = false
                    errno = EIO
                    return -1
                }
                return fcntl(fd, command, value)
            })
        defer { forceEndChild(process) }
        switch process.startProcessChecked(
            executable: "/bin/sh",
            args: heldChildArguments(
                readyPath: fifo.readyPath,
                commandPath: fifo.commandPath,
                lifetimePath: fifo.lifetimePath,
                ignoreTerm: true)) {
        case .failure(.primaryDescriptorSetupFailed(EIO)):
            break
        case .failure(let error):
            Issue.record("Unexpected launch failure: \(error)")
            return
        case .success:
            Issue.record("F_SETFD failure launched successfully")
            return
        }
        #expect(sawReady.withLock { $0 })
        #expect(process.childfd == -1)
        #expect(process.shellPid == 0)
        #expect(!process.running)
        #expect(!process.windingDown)
        #expect(delegate.failureCount == 0)
        #expect(delegate.terminationCount == 0)
        // The readiness pull holds its own live descriptor, so child death is
        // proven by the child's independent lifetime channel, not by that EOF.
        #expect(fifo.waitForLifetimeEnd(timeout: 3))

        if case .failure(let error) = process.startProcessChecked(
            executable: "/bin/sh", args: ["-c", "exit 0"]) {
            Issue.record("Relaunch after F_SETFD failure failed: \(error)")
        }
        #expect(delegate.waitForTermination(count: 1, timeout: 5))
        #expect(delegate.exitCode == 0)
    }

    // MARK: - Fixture cleanup

    @Test func explicitReservationCloseDoesNotCloseAReusedDescriptorOnDeinit() throws {
        // Break caught: explicit close leaves the helper's number valid, so its
        // later deinit closes a reservation that a new owner took in that slot.
        let sourcePath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftterm-primary-reservation-source-\(UUID().uuidString).dat")
            .path
        let released = WeakOwnedUnrelatedFileReference()

        // The reservation source is opened while the helper still owns its
        // slot, and the helper outlives the reservation only until this
        // function returns, so its deinit runs after the slot is ours.
        func closeReserveAndRelease() throws -> (
            reserved: Int32,
            identity: PrimaryDescriptorIdentity
        ) {
            let helper = try OwnedUnrelatedFile()
            released.value = helper
            let former = helper.descriptor
            let source = open(sourcePath, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard source >= 0 else {
                throw PrimaryDescriptorTestError.couldNotOpenFile(sourcePath, errno)
            }
            defer {
                closeTestDescriptor(source)
                try? FileManager.default.removeItem(atPath: sourcePath)
            }
            let identity = try primaryDescriptorIdentity(source)
            helper.close()
            let reserved = try reservePrimarySlot(at: former, from: source)
            // Pin the helper through the reservation so the old deinit, not a
            // pre-reservation release, is what the test observes.
            withExtendedLifetime(helper) {}
            return (reserved, identity)
        }
        let acquired = try closeReserveAndRelease()
        #expect(released.value == nil)
        defer {
            // The old deinit closes this slot; only close it while it still
            // is our reservation rather than an unrelated reused file.
            if descriptorRefersToSameOpenFile(acquired.reserved, as: acquired.identity) {
                closeTestDescriptor(acquired.reserved)
            }
        }
        let surviving = try? primaryDescriptorIdentity(acquired.reserved)
        #expect(surviving == acquired.identity)
    }
}

// MARK: - Fixtures and synchronization

private final class PrimaryFifo {
    let readyPath: String
    let commandPath: String
    let lifetimePath: String
    private var readyFd: Int32 = -1
    private var commandFd: Int32 = -1
    private var lifetimeFd: Int32 = -1

    init() throws {
        let stem = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftterm-primary-\(UUID().uuidString)")
            .path
        readyPath = stem + ".ready"
        commandPath = stem + ".command"
        lifetimePath = stem + ".lifetime"
        guard mkfifo(readyPath, 0o600) == 0 else {
            throw PrimaryDescriptorTestError.couldNotMakeFifo(readyPath, errno)
        }
        guard mkfifo(commandPath, 0o600) == 0 else {
            try? FileManager.default.removeItem(atPath: readyPath)
            throw PrimaryDescriptorTestError.couldNotMakeFifo(commandPath, errno)
        }
        guard mkfifo(lifetimePath, 0o600) == 0 else {
            cleanupPaths()
            throw PrimaryDescriptorTestError.couldNotMakeFifo(lifetimePath, errno)
        }
        readyFd = open(readyPath, O_RDONLY | O_NONBLOCK)
        guard readyFd >= 0 else {
            let failure = errno
            cleanupPaths()
            throw PrimaryDescriptorTestError.couldNotOpenFifo(readyPath, failure)
        }
        // A read-write command end lets the child open its read end without
        // blocking and lets the test release or end the child later.
        commandFd = open(commandPath, O_RDWR | O_NONBLOCK)
        guard commandFd >= 0 else {
            let failure = errno
            cleanupPaths()
            throw PrimaryDescriptorTestError.couldNotOpenFifo(commandPath, failure)
        }
        lifetimeFd = open(lifetimePath, O_RDONLY | O_NONBLOCK)
        guard lifetimeFd >= 0 else {
            let failure = errno
            cleanupPaths()
            throw PrimaryDescriptorTestError.couldNotOpenFifo(lifetimePath, failure)
        }
    }

    func startChild(_ process: LocalProcess, ignoreTerm: Bool) {
        _ = process.startProcessChecked(
            executable: "/bin/sh",
            args: heldChildArguments(
                readyPath: readyPath,
                commandPath: commandPath,
                lifetimePath: lifetimePath,
                ignoreTerm: ignoreTerm))
    }

    @discardableResult
    func releaseChild() -> Bool {
        guard commandFd >= 0 else { return false }
        // The held child completes `read -r line` only at a newline, and the
        // test keeps the command write end open, so a bare byte would block.
        var newline: UInt8 = 0x0a
        let written = write(commandFd, &newline, 1)
        return written == 1
    }

    func waitForToken(_ token: [UInt8], timeout: TimeInterval) -> Bool {
        guard readyFd >= 0 else { return false }
        var collected: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        while collected.count < token.count {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            var descriptor = pollfd(fd: readyFd, events: Int16(POLLIN), revents: 0)
            let polled = poll(&descriptor, 1, Int32(max(1, remaining * 1_000)))
            if polled < 0 {
                if errno == EINTR { continue }
                return false
            }
            if polled == 0 { return false }
            var buffer = [UInt8](repeating: 0, count: 64)
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return read(readyFd, base, bytes.count)
            }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                return false
            }
            if count == 0 { return false }
            collected.append(contentsOf: buffer.prefix(count))
        }
        return collected.prefix(token.count).elementsEqual(token)
    }

    /// Waits for the child's private lifetime write end to close, which
    /// proves actual child death regardless of readiness or command pulls.
    /// A direct nonblocking read is used because macOS FIFO poll does not
    /// report the writer-close hangup for this read end.
    func waitForLifetimeEnd(timeout: TimeInterval) -> Bool {
        guard lifetimeFd >= 0 else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: 64)
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return read(lifetimeFd, base, bytes.count)
            }
            if count == 0 { return true }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    Thread.sleep(forTimeInterval: 0.001)
                    continue
                }
                return false
            }
        }
        return false
    }

    func close() {
        if readyFd >= 0 {
            closeTestDescriptor(readyFd)
            readyFd = -1
        }
        if commandFd >= 0 {
            closeTestDescriptor(commandFd)
            commandFd = -1
        }
        if lifetimeFd >= 0 {
            closeTestDescriptor(lifetimeFd)
            lifetimeFd = -1
        }
        cleanupPaths()
    }

    private func cleanupPaths() {
        try? FileManager.default.removeItem(atPath: readyPath)
        try? FileManager.default.removeItem(atPath: commandPath)
        try? FileManager.default.removeItem(atPath: lifetimePath)
    }

    deinit {
        close()
    }
}

private final class OwnedUnrelatedFile {
    let path: String
    private(set) var descriptor: Int32

    init() throws {
        path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftterm-primary-reservation-\(UUID().uuidString).dat")
            .path
        guard FileManager.default.createFile(atPath: path, contents: Data("reserved".utf8)) else {
            throw PrimaryDescriptorTestError.couldNotCreateTemporaryFile(path)
        }
        descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            let failure = errno
            try? FileManager.default.removeItem(atPath: path)
            throw PrimaryDescriptorTestError.couldNotOpenFile(path, failure)
        }
    }

    /// Invalidates before closing so a later `deinit` cannot close a foreign
    /// file that reused this number.
    func close() {
        if descriptor >= 0 {
            let closing = descriptor
            descriptor = -1
            closeTestDescriptor(closing)
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    deinit {
        close()
    }
}

/// Observes deallocation of an `OwnedUnrelatedFile` without retaining it.
private final class WeakOwnedUnrelatedFileReference {
    weak var value: OwnedUnrelatedFile?
}

/// Records primary control calls and write-alias creation in program order,
/// and performs the real syscalls so launch semantics stay intact.
private final class PrimarySetupRecorder {
    enum Kind {
        case getFlags
        case setFlags
        case writeAlias
    }

    struct Event {
        let kind: Kind
        let fd: Int32
        let value: Int32
        let result: Int32
    }

    private let lock = NSLock()
    private var events: [Event] = []

    func recordControl(fd: Int32, command: Int32, value: Int32) -> Int32 {
        let result = fcntl(fd, command, value)
        let kind: Kind = command == F_GETFD ? .getFlags : .setFlags
        lock.lock()
        events.append(Event(kind: kind, fd: fd, value: value, result: result))
        lock.unlock()
        return result
    }

    func recordWriteAlias() {
        lock.lock()
        events.append(Event(kind: .writeAlias, fd: -1, value: 0, result: 0))
        lock.unlock()
    }

    func snapshot() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class PrimaryTestDelegate: LocalProcessDelegate, @unchecked Sendable {
    private let condition = NSCondition()
    private var storedExitCode: Int32?
    private var storedTerminationCount = 0
    private var storedFailureCount = 0
    private var storedFailures: [LocalProcessError] = []
    private var storedReceived: [UInt8] = []

    var windowSizeEntry: DispatchSemaphore?
    var windowSizeRelease: DispatchSemaphore?
    var dataEntry: DispatchSemaphore?
    var dataRelease: DispatchSemaphore?
    var onTermination: (() -> Void)?

    var terminationCount: Int {
        condition.lock()
        let count = storedTerminationCount
        condition.unlock()
        return count
    }

    var failureCount: Int {
        condition.lock()
        let count = storedFailureCount
        condition.unlock()
        return count
    }

    var failures: [LocalProcessError] {
        condition.lock()
        let copy = storedFailures
        condition.unlock()
        return copy
    }

    var exitCode: Int32? {
        condition.lock()
        let code = storedExitCode
        condition.unlock()
        return code
    }

    func receivedData() -> [UInt8] {
        condition.lock()
        let copy = storedReceived
        condition.unlock()
        return copy
    }

    func waitForTermination(count: Int, timeout: TimeInterval) -> Bool {
        wait(timeout: timeout) { self.storedTerminationCount >= count }
    }

    func waitForFailure(timeout: TimeInterval) -> Bool {
        wait(timeout: timeout) { self.storedFailureCount > 0 }
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        condition.lock()
        storedExitCode = exitCode
        storedTerminationCount += 1
        condition.broadcast()
        condition.unlock()
        onTermination?()
    }

    func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        condition.lock()
        storedFailureCount += 1
        storedFailures.append(error)
        condition.broadcast()
        condition.unlock()
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        condition.lock()
        storedReceived.append(contentsOf: slice)
        condition.unlock()
        dataEntry?.signal()
        dataRelease?.wait()
    }

    func getWindowSize() -> winsize {
        windowSizeEntry?.signal()
        windowSizeRelease?.wait()
        return winsize(ws_row: 24, ws_col: 80, ws_xpixel: 640, ws_ypixel: 480)
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

private final class StalePipelineDelegate: TerminalIOPipelineDelegate {
    func pipeline(_ pipeline: TerminalIOPipeline, received data: Span<UInt8>) {}

    func pipelineDidReachEOF(_ pipeline: TerminalIOPipeline) {}
}

private final class TestThreadCompletion: @unchecked Sendable {
    private let condition = NSCondition()
    private var done = false

    func signal() {
        condition.lock()
        done = true
        condition.broadcast()
        condition.unlock()
    }

    func wait(timeout: TimeInterval) -> Bool {
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
}

/// Observes deallocation without extending the observed owner's lifetime.
private final class WeakProcessReference: @unchecked Sendable {
    weak var value: LocalProcess?

    init(_ value: LocalProcess? = nil) {
        self.value = value
    }
}

/// Test-only transfer wrapper for non-Sendable objects handed to a worker.
private final class TestBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
#endif
