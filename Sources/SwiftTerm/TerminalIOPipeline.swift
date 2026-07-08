//
//  TerminalIOPipeline.swift
//  SwiftTerm
//
//  Two-stage pty read pipeline, a port of Ghostty's termio design
//  (ghostty/src/termio/Exec.zig): a gather thread drains the kernel pty
//  queue into a small ring of buffers, a parse thread delivers batches.
//
#if !os(iOS) && !os(Windows)
import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

protocol TerminalIOPipelineDelegate: AnyObject {
    /// Called on the parse thread, synchronously. Blocking here IS the
    /// backpressure mechanism.
    func pipeline(_ pipeline: TerminalIOPipeline, received data: [UInt8])
    /// Called on the parse thread on EOF/HUP/read error (not on shutdown()).
    func pipelineDidReachEOF(_ pipeline: TerminalIOPipeline)
}

final class TerminalIOPipeline {
#if canImport(Darwin)
    // Darwin ptys cap master reads around 1 KiB. Four 64 KiB buffers let the
    // gather thread keep draining while the parse thread works, without adding
    // unbounded elastic buffering.
    private static let bufferCount = 4
    private static let bufferCapacity = 65_536
#else
    // Other POSIX platforms use a smaller ring for tighter parser backpressure.
    private static let bufferCount = 2
    private static let bufferCapacity = 8_192
#endif
    // A short read below one tty-queue-sized refill is treated as interactive
    // trickle and delivered immediately.
    private static let bridgeThreshold = 1024
    // Saturated streams get a bounded spin before sleeping, which bridges the
    // producer's microsecond refill gaps without penalizing interactive output.
    private static let bridgeSpinMax = 16
    private static let bridgePollTimeoutMs: Int32 = 1
    // Per-batch bridge budget, well under a display frame.
    private static let gatherBudgetNs: UInt64 = 3_000_000

    private weak var delegate: TerminalIOPipelineDelegate?
    private var fd: Int32
    private var quitReadFd: Int32 = -1
    private var quitWriteFd: Int32 = -1
    private var idleReadFd: Int32 = -1
    private var idleWriteFd: Int32 = -1

    private let storage: UnsafeMutablePointer<UInt8>
    private let condition = NSCondition()

    // Buffer contents are never locked: each slot is owned by exactly one stage
    // at a time. This condition protects only ring metadata. With one gather
    // and one parse thread, the wait predicates are mutually exclusive (parse
    // waits only while count == 0, gather only while count == bufferCount), so a
    // single condition with signal() is equivalent to separate batch/slot condvars.
    private var lens = Array(repeating: 0, count: TerminalIOPipeline.bufferCount)
    private var head = 0
    private var tail = 0
    private var count = 0
    private var bridging = false
    private var done = false
    private var quitRequested = false
    private var remainingThreads = 2
    private var descriptorsClosed = false
    private var started = false

    init(fd: Int32, delegate: TerminalIOPipelineDelegate) {
        self.fd = fd
        self.delegate = delegate
        self.storage = UnsafeMutablePointer<UInt8>.allocate(
            capacity: TerminalIOPipeline.bufferCount * TerminalIOPipeline.bufferCapacity)
        _ = Self.makePipe(readFd: &quitReadFd, writeFd: &quitWriteFd)
        _ = Self.makePipe(readFd: &idleReadFd, writeFd: &idleWriteFd)
    }

    deinit {
        shutdown()
        if !started {
            closeDescriptorsIfNeeded()
        }
        storage.deallocate()
    }

    func start() {
        condition.lock()
        if started {
            condition.unlock()
            return
        }
        started = true
        condition.unlock()

        guard Self.setNonBlocking(fd) else {
            // No threads were spawned, so nobody else will deliver EOF or
            // run the thread-exit accounting; do both here so the owner
            // still learns the stream is dead and waiters can finish.
            condition.lock()
            done = true
            remainingThreads = 0
            condition.broadcast()
            condition.unlock()
            closeDescriptorsIfNeeded()
            delegate?.pipelineDidReachEOF(self)
            return
        }

        let gatherThread = Thread { [self] in
            gatherMain()
        }
        let parseThread = Thread { [self] in
            parseMain()
        }
#if canImport(Darwin)
        gatherThread.qualityOfService = .userInitiated
        parseThread.qualityOfService = .userInitiated
#endif
        gatherThread.start()
        parseThread.start()
    }

    func shutdown() {
        condition.lock()
        quitRequested = true
        if quitWriteFd >= 0 {
            Self.writeWakeByte(quitWriteFd)
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Testing hook. Only call after the stream has ended (shutdown() or EOF):
    /// waiting concurrently with active streaming adds a third waiter to the
    /// condition, and the hot-path signal() could then wake this thread instead
    /// of the gather/parse thread it was meant for.
    func waitUntilStopped(timeout: TimeInterval) -> Bool {
        let limit = Date().addingTimeInterval(timeout)
        condition.lock()
        while remainingThreads > 0 {
            if !condition.wait(until: limit) {
                condition.unlock()
                return false
            }
        }
        condition.unlock()
        return true
    }

    private func parseMain() {
#if canImport(Darwin)
        pthread_setname_np("swiftterm-io-reader")
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
#endif
        defer { threadDidExit() }

        while true {
            let slot: Int
            let length: Int
            let notifyEOF: Bool

            condition.lock()
            while count == 0 && !done {
                condition.wait()
            }
            if done && count == 0 {
                notifyEOF = !quitRequested
                condition.unlock()
                if notifyEOF {
                    delegate?.pipelineDidReachEOF(self)
                }
                return
            }
            slot = tail
            length = lens[slot]
            condition.unlock()

            let base = storage.advanced(by: slot * TerminalIOPipeline.bufferCapacity)
            let data = Array(UnsafeBufferPointer(start: base, count: length))

            let shouldWakeGather: Bool
            condition.lock()
            tail = (tail + 1) % TerminalIOPipeline.bufferCount
            count -= 1
            shouldWakeGather = count == 0 && bridging && idleWriteFd >= 0
            condition.signal()
            condition.unlock()

            if shouldWakeGather {
                Self.writeWakeByte(idleWriteFd)
            }
            delegate?.pipeline(self, received: data)
        }
    }

    private func gatherMain() {
#if canImport(Darwin)
        pthread_setname_np("swiftterm-io-gather")
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
#endif
        defer { threadDidExit() }
        defer { markDone() }

        var pollFds = [
            pollfd(fd: fd, events: Self.pollIn, revents: 0),
            pollfd(fd: quitReadFd, events: Self.pollIn, revents: 0),
            pollfd(fd: idleReadFd, events: Self.pollIn, revents: 0)
        ]

        while true {
            let slot: Int
            condition.lock()
            while count == TerminalIOPipeline.bufferCount && !quitRequested {
                condition.wait()
            }
            if quitRequested {
                condition.unlock()
                return
            }
            slot = head
            condition.unlock()

            let buffer = storage.advanced(by: slot * TerminalIOPipeline.bufferCapacity)
            var total = 0
            var bridgeStart: UInt64?
            var spins = 0
            var fatal = false

            while total < TerminalIOPipeline.bufferCapacity {
                let n = Self.readFd(fd, into: buffer.advanced(by: total), count: TerminalIOPipeline.bufferCapacity - total)
                if n > 0 {
                    total += n
                    spins = 0
                    continue
                }
                if n == 0 {
                    fatal = true
                    break
                }

                let err = errno
                if err == EINTR {
                    continue
                }
                if err == EAGAIN || err == EWOULDBLOCK {
                    if total < TerminalIOPipeline.bridgeThreshold {
                        break
                    }
                    if spins < TerminalIOPipeline.bridgeSpinMax {
                        spins += 1
                        continue
                    }

                    let now = DispatchTime.now().uptimeNanoseconds
                    if let start = bridgeStart {
                        if now - start >= TerminalIOPipeline.gatherBudgetNs {
                            break
                        }
                    } else {
                        bridgeStart = now
                    }

                    condition.lock()
                    if count == 0 {
                        condition.unlock()
                        break
                    }
                    bridging = true
                    condition.unlock()

                    let pollResult = Self.pollFds(&pollFds, count: pollFds.count, timeout: TerminalIOPipeline.bridgePollTimeoutMs)
                    // Capture errno before clearBridging: its lock/unlock is
                    // not guaranteed to preserve it.
                    let pollErrno = errno
                    clearBridging()

                    if pollResult < 0 {
                        if pollErrno == EINTR {
                            continue
                        }
                        break
                    }
                    if pollResult == 0 {
                        break
                    }
                    if Self.hasPollIn(pollFds[1]) {
                        fatal = true
                        break
                    }
                    if Self.hasPollIn(pollFds[2]) {
                        drainIdlePipe()
                        break
                    }
                    if !Self.hasPollIn(pollFds[0]) {
                        break
                    }
                    continue
                }
                // Every other errno (EIO when the slave side is gone, EBADF,
                // anything unexpected) ends the stream.
                fatal = true
                break
            }

            if total > 0 {
                condition.lock()
                lens[head] = total
                head = (head + 1) % TerminalIOPipeline.bufferCount
                count += 1
                condition.signal()
                condition.unlock()
            }

            if fatal {
                return
            }
            if total == TerminalIOPipeline.bufferCapacity {
                continue
            }

            while true {
                let pollResult = Self.pollFds(&pollFds, count: 2, timeout: -1)
                if pollResult < 0 && errno == EINTR {
                    continue
                }
                if pollResult < 0 {
                    return
                }
                if Self.hasPollIn(pollFds[1]) {
                    return
                }
                if Self.hasPollHup(pollFds[0]) && !Self.hasPollIn(pollFds[0]) {
                    return
                }
                break
            }
        }
    }

    private func markDone() {
        condition.lock()
        done = true
        // broadcast, not signal: a waitUntilStopped caller may also be waiting
        // on this condition, and a signal could wake it instead of the parse
        // thread. This is off the hot path, so the cost does not matter.
        condition.broadcast()
        condition.unlock()
    }

    private func clearBridging() {
        condition.lock()
        bridging = false
        condition.unlock()
    }

    private func drainIdlePipe() {
        guard idleReadFd >= 0 else {
            return
        }
        var trash = [UInt8](repeating: 0, count: 16)
        trash.withUnsafeMutableBytes { pointer in
            guard let base = pointer.baseAddress else {
                return
            }
            while true {
                let n = Self.readFd(idleReadFd, into: base, count: pointer.count)
                if n < pointer.count {
                    break
                }
            }
        }
    }

    private func threadDidExit() {
        var shouldClose = false
        condition.lock()
        remainingThreads -= 1
        if remainingThreads == 0 {
            shouldClose = true
        }
        condition.broadcast()
        condition.unlock()
        if shouldClose {
            closeDescriptorsIfNeeded()
        }
    }

    private func closeDescriptorsIfNeeded() {
        var descriptors: [Int32] = []
        condition.lock()
        if !descriptorsClosed {
            descriptorsClosed = true
            descriptors = [fd, quitReadFd, quitWriteFd, idleReadFd, idleWriteFd].filter { $0 >= 0 }
            fd = -1
            quitReadFd = -1
            quitWriteFd = -1
            idleReadFd = -1
            idleWriteFd = -1
        }
        condition.unlock()
        for descriptor in descriptors {
            close(descriptor)
        }
    }

    private static var pollIn: Int16 {
        Int16(POLLIN)
    }

    private static var pollHup: Int16 {
        Int16(POLLHUP)
    }

    private static func hasPollIn(_ fd: pollfd) -> Bool {
        (fd.revents & pollIn) != 0
    }

    private static func hasPollHup(_ fd: pollfd) -> Bool {
        (fd.revents & pollHup) != 0
    }

    private static func pollFds(_ pollFds: inout [pollfd], count: Int, timeout: Int32) -> Int32 {
        poll(&pollFds, nfds_t(count), timeout)
    }

    private static func readFd(_ fd: Int32, into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        read(fd, buffer, count)
    }

    private static func writeWakeByte(_ fd: Int32) {
        var byte: UInt8 = 1
        _ = withUnsafePointer(to: &byte) { pointer in
            write(fd, pointer, 1)
        }
    }

    private static func makePipe(readFd: inout Int32, writeFd: inout Int32) -> Bool {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            return false
        }
        readFd = fds[0]
        writeFd = fds[1]
        setCloseOnExec(readFd)
        setCloseOnExec(writeFd)
        setNonBlocking(readFd)
        setNonBlocking(writeFd)
        return true
    }

    @discardableResult
    private static func setNonBlocking(_ fd: Int32) -> Bool {
        guard fd >= 0 else {
            return false
        }
        let flags = fcntl(fd, F_GETFL, 0)
        if flags < 0 {
            return false
        }
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private static func setCloseOnExec(_ fd: Int32) {
        guard fd >= 0 else {
            return
        }
        let flags = fcntl(fd, F_GETFD, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
        }
    }
}
#endif
