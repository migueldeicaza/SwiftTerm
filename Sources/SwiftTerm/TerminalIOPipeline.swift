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
    /// The span is valid only until this method returns.
    func pipeline(_ pipeline: TerminalIOPipeline, received data: Span<UInt8>)
    /// Called on the parse thread on EOF/HUP/read error (not on shutdown()).
    func pipelineDidReachEOF(_ pipeline: TerminalIOPipeline)
}

private struct TerminalIOPipelineSinkState {
    weak var delegate: TerminalIOPipelineDelegate?
    weak var pipeline: TerminalIOPipeline?
}

/// Audited bridge from the Sendable worker to the non-Sendable delegate.
///
/// `Locked` makes weak-reference access safe. Each delivery takes temporary
/// strong references, releases the lock, and then invokes the delegate on the
/// parse thread. The sink never keeps the pipeline or its owner alive.
private final class TerminalIOPipelineSink: Sendable {
    private let state: Locked<TerminalIOPipelineSinkState>

    init(delegate: TerminalIOPipelineDelegate) {
        state = Locked(TerminalIOPipelineSinkState(delegate: delegate, pipeline: nil))
    }

    func attach(pipeline: TerminalIOPipeline) {
        state.withLock { $0.pipeline = pipeline }
    }

    func clear() {
        state.withLock {
            $0.delegate = nil
            $0.pipeline = nil
        }
    }

    func received(_ data: Span<UInt8>) {
        let target: (TerminalIOPipelineDelegate, TerminalIOPipeline)? = state.withLock {
            guard let delegate = $0.delegate, let pipeline = $0.pipeline else { return nil }
            return (delegate, pipeline)
        }
        guard let (delegate, pipeline) = target else { return }
        delegate.pipeline(pipeline, received: data)
    }

    func reachedEOF() {
        let target: (TerminalIOPipelineDelegate, TerminalIOPipeline)? = state.withLock {
            guard let delegate = $0.delegate, let pipeline = $0.pipeline else { return nil }
            return (delegate, pipeline)
        }
        guard let (delegate, pipeline) = target else { return }
        delegate.pipelineDidReachEOF(pipeline)
    }
}

/// Owns the pipeline lifecycle. Worker threads do not retain this controller.
final class TerminalIOPipeline: Sendable {
#if canImport(Darwin)
    // Darwin ptys cap master reads around 1 KiB. Four slots let gathering
    // continue while parsing without creating an unbounded queue.
    static let bufferCount = 4
    static let bufferCapacity = 65_536
#else
    static let bufferCount = 2
    static let bufferCapacity = 8_192
#endif

    private let sink: TerminalIOPipelineSink
    private let worker: TerminalIOPipelineWorker

    init(fd: Int32, delegate: TerminalIOPipelineDelegate) {
        let sink = TerminalIOPipelineSink(delegate: delegate)
        self.sink = sink
        worker = TerminalIOPipelineWorker(fd: fd, sink: sink)
        sink.attach(pipeline: self)
    }

    deinit {
        shutdown()
    }

    func start() {
        worker.start()
    }

    /// Stops the worker permanently. Calls from owner threads wait for both
    /// worker threads. A callback on the parse thread cannot wait for itself;
    /// that path clears the sink and lets thread retention finish teardown.
    func shutdown() {
        let canWait = worker.requestShutdown()
        if canWait {
            worker.waitUntilStopped()
        }
        sink.clear()
    }

    /// Deliver whatever is already readable, then stop, within `timeout`.
    /// Returns true when both worker threads have fully stopped (i.e. every
    /// buffered batch was delivered); false when the deadline expired first.
    /// Must not be called from a pipeline worker thread.
    func drainAvailableAndShutdown(timeout: TimeInterval) -> Bool {
        let deadline = uptimeDeadline(after: timeout)
        let canWait = worker.requestDrain(deadline: deadline)
        assert(canWait, "A pipeline worker cannot wait for its own completion")
        let stopped = canWait && worker.waitUntilStopped(deadline: deadline)
        // If a delegate callback exceeds the deadline, the last worker keeps
        // the pty open until that callback returns. Closing it under a live
        // read can cause the EV_VANISHED class of libdispatch crashes.
        sink.clear()
        return stopped
    }

    /// Testing hook. Only call after the stream has ended.
    func waitUntilStopped(timeout: TimeInterval) -> Bool {
        worker.waitUntilStopped(timeout: timeout)
    }
}

/// Converts a timeout into a saturating uptime deadline in nanoseconds.
private func uptimeDeadline(after timeout: TimeInterval) -> UInt64 {
    let now = DispatchTime.now().uptimeNanoseconds
    guard timeout > 0 else {
        return now
    }
    let available = UInt64.max - now
    let nanoseconds = timeout * 1_000_000_000
    guard nanoseconds < Double(available) else {
        return UInt64.max
    }
    return now + UInt64(nanoseconds)
}

/// Owns raw storage, file descriptors, and the condition-protected ring.
///
/// This is the one low-level unchecked boundary. The condition protects all
/// mutable metadata and descriptor closure. The gather thread writes only the
/// head slot. The parse thread reads only the tail slot. A slot changes owner
/// only while the condition is locked.
private final class TerminalIOPipelineWorker: @unchecked Sendable {
    private enum RunPhase: Equatable {
        case streaming
        case draining(deadline: UInt64)
        case quitting
    }

    // A short read below one tty-queue-sized refill is treated as interactive
    // trickle and delivered immediately.
    private static let bridgeThreshold = 1024
    // Saturated streams get a bounded spin before sleeping, which bridges the
    // producer's microsecond refill gaps without penalizing interactive output.
    private static let bridgeSpinMax = 16
    private static let bridgePollTimeoutMs: Int32 = 1
    // Per-batch bridge budget, well under a display frame.
    private static let gatherBudgetNs: UInt64 = 3_000_000

    private let sink: TerminalIOPipelineSink
    private var fd: Int32
    private var controlReadFd: Int32 = -1
    private var controlWriteFd: Int32 = -1
    private var idleReadFd: Int32 = -1
    private var idleWriteFd: Int32 = -1

    private let storage: UnsafeMutablePointer<UInt8>
    private let condition = NSCondition()

    // Buffer contents are never locked: each slot is owned by exactly one stage
    // at a time. This condition protects only ring metadata. With one gather
    // and one parse thread, the wait predicates are mutually exclusive (parse
    // waits only while count == 0, gather only while count == bufferCount). The
    // third waiter in waitUntilStopped exists only in a non-streaming phase, so
    // signal() remains equivalent to separate condvars on the streaming hot path.
    private var lens = Array(repeating: 0, count: TerminalIOPipeline.bufferCount)
    private var head = 0
    private var tail = 0
    private var count = 0
    private var bridging = false
    private var done = false
    private var runPhase: RunPhase = .streaming
    private var remainingThreads = 0
    private var descriptorsClosed = false
    private var started = false
    private var wakePipesReady = false
#if DEBUG
    private enum SlotState {
        case free
        case filled
        case parsing
    }
    private var slotStates = Array(
        repeating: SlotState.free,
        count: TerminalIOPipeline.bufferCount)
#endif
    private let workerMarker = UUID().uuidString
    private static let workerMarkerKey = "org.tirania.SwiftTerm.io-worker"

    init(fd: Int32, sink: TerminalIOPipelineSink) {
        self.fd = fd
        self.sink = sink
        self.storage = UnsafeMutablePointer<UInt8>.allocate(
            capacity: TerminalIOPipeline.bufferCount * TerminalIOPipeline.bufferCapacity)
        let controlPipeReady = Self.makePipe(readFd: &controlReadFd, writeFd: &controlWriteFd)
        let idlePipeReady = Self.makePipe(readFd: &idleReadFd, writeFd: &idleWriteFd)
        wakePipesReady = controlPipeReady && idlePipeReady
    }

    deinit {
        condition.lock()
        let threadsFinished = remainingThreads == 0
        condition.unlock()
        precondition(threadsFinished, "TerminalIOPipeline storage released before worker completion")
        closeDescriptorsIfNeeded()
        storage.deallocate()
    }

    func start() {
        condition.lock()
        if started {
            condition.unlock()
            return
        }
        started = true
        remainingThreads = 2
        condition.unlock()

        guard wakePipesReady, Self.setNonBlocking(fd) else {
            // No threads were spawned, so nobody else will deliver EOF or
            // run the thread-exit accounting; do both here so the owner
            // still learns the stream is dead and waiters can finish.
            condition.lock()
            done = true
            remainingThreads = 0
            condition.broadcast()
            condition.unlock()
            closeDescriptorsIfNeeded()
            sink.reachedEOF()
            return
        }

        let gatherThread = Thread { [self] in
            runAsWorker(gatherMain)
        }
        let parseThread = Thread { [self] in
            ProfilingOwner.markCurrentThread(as: .parse)
            runAsWorker(parseMain)
        }
        gatherThread.name = "swiftterm-io-gather"
        parseThread.name = ProfilingOwner.parseThreadName
#if canImport(Darwin)
        gatherThread.qualityOfService = .userInitiated
        parseThread.qualityOfService = .userInitiated
#endif
        gatherThread.start()
        parseThread.start()
    }

    /// Requests permanent shutdown. Returns `false` on a worker thread because
    /// that thread cannot wait for its own completion.
    func requestShutdown() -> Bool {
        condition.lock()
        runPhase = .quitting
        if controlWriteFd >= 0 {
            Self.writeWakeByte(controlWriteFd)
        }
        condition.broadcast()
        let shouldClose = !started
        condition.unlock()
        if shouldClose {
            closeDescriptorsIfNeeded()
        }
        return !isCurrentWorker
    }

    /// Requests a bounded drain of bytes that are already readable from the
    /// pty. The parse worker delivers gathered batches until the deadline.
    func requestDrain(deadline: UInt64) -> Bool {
        condition.lock()
        if runPhase == .streaming {
            runPhase = .draining(deadline: deadline)
        }
        if controlWriteFd >= 0 {
            Self.writeWakeByte(controlWriteFd)
        }
        condition.broadcast()
        let shouldClose = !started
        if shouldClose {
            done = true
        }
        condition.unlock()
        if shouldClose {
            closeDescriptorsIfNeeded()
        }
        return !isCurrentWorker
    }

    /// Waits without a timeout. The owner uses this during explicit teardown.
    func waitUntilStopped() {
        condition.lock()
        while remainingThreads > 0 {
            condition.wait()
        }
        condition.unlock()
    }

    /// Testing hook. Only call after the stream has ended (shutdown() or EOF).
    func waitUntilStopped(timeout: TimeInterval) -> Bool {
        waitUntilStopped(deadline: uptimeDeadline(after: timeout))
    }

    /// Waits until both workers stop or the uptime deadline expires.
    func waitUntilStopped(deadline: UInt64) -> Bool {
        condition.lock()
        while remainingThreads > 0 {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline {
                condition.unlock()
                return false
            }
            _ = condition.wait(until: Date(
                timeIntervalSinceNow: Double(deadline - now) / 1_000_000_000))
        }
        condition.unlock()
        return true
    }

    private var isCurrentWorker: Bool {
        Thread.current.threadDictionary[Self.workerMarkerKey] as? String == workerMarker
    }

    private func runAsWorker(_ body: () -> Void) {
        let dictionary = Thread.current.threadDictionary
        dictionary[Self.workerMarkerKey] = workerMarker
        defer { dictionary.removeObject(forKey: Self.workerMarkerKey) }
        body()
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
                if case .draining(let deadline) = runPhase {
                    let now = DispatchTime.now().uptimeNanoseconds
                    if now >= deadline {
                        condition.unlock()
                        return
                    }
                    _ = condition.wait(until: Date(
                        timeIntervalSinceNow: Double(deadline - now) / 1_000_000_000))
                } else {
                    condition.wait()
                }
            }
            if done && count == 0 {
                notifyEOF = runPhase == .streaming
                condition.unlock()
                if notifyEOF {
                    sink.reachedEOF()
                }
                return
            }
            if case .draining(let deadline) = runPhase,
               DispatchTime.now().uptimeNanoseconds >= deadline {
                condition.unlock()
                return
            }
            slot = tail
            length = lens[slot]
#if DEBUG
            precondition(slotStates[slot] == .filled, "Parse thread selected a slot that is not filled")
            slotStates[slot] = .parsing
#endif
            condition.unlock()

            precondition(length > 0)
            precondition(length <= TerminalIOPipeline.bufferCapacity)
            let base = unsafe storage.advanced(
                by: slot * TerminalIOPipeline.bufferCapacity)
            // The ring owns this initialized slot until release(slot:) runs.
            let input = unsafe UnsafeBufferPointer(start: base, count: length)
            let data = unsafe input.span
            defer { release(slot: slot) }
            // Spans the whole delivery, which for direct delivery includes the
            // parse. The gap between consecutive IO.Batch intervals is the
            // pipeline's idle time and is what a starved parse stage looks
            // like in a trace.
            let batch = Profiling.begin(.ioBatch, "bytes=%d", length)
            sink.received(data)
            batch.end("bytes=%d", length)
        }
    }

    private func release(slot: Int) {
        let shouldWakeGather: Bool
        condition.lock()
#if DEBUG
        precondition(slot == tail, "Parse thread released a different slot")
        precondition(slotStates[slot] == .parsing, "Ring slot was released twice")
        precondition(count > 0, "Ring count underflow")
        slotStates[slot] = .free
#endif
        lens[slot] = 0
        tail = (tail + 1) % TerminalIOPipeline.bufferCount
        count -= 1
        shouldWakeGather = count == 0 && bridging && idleWriteFd >= 0
        signalRingTransition()
        condition.unlock()

        if shouldWakeGather {
            Self.writeWakeByte(idleWriteFd)
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
            pollfd(fd: controlReadFd, events: Self.pollIn, revents: 0),
            pollfd(fd: idleReadFd, events: Self.pollIn, revents: 0)
        ]

        while true {
            let slot: Int
            condition.lock()
            while count == TerminalIOPipeline.bufferCount {
                switch runPhase {
                case .streaming:
                    condition.wait()
                case .draining(let deadline):
                    let now = DispatchTime.now().uptimeNanoseconds
                    if now >= deadline {
                        condition.unlock()
                        return
                    }
                    _ = condition.wait(until: Date(
                        timeIntervalSinceNow: Double(deadline - now) / 1_000_000_000))
                case .quitting:
                    condition.unlock()
                    return
                }
            }
            // Capture the phase while the lock is already held, so the read
            // loop below stays lock-free on the streaming hot path. A phase
            // change during the fill is caught at the next EAGAIN, slot-full
            // wait, or control-pipe wake — one slot fill at most.
            let drainDeadline: UInt64?
            switch runPhase {
            case .streaming:
                drainDeadline = nil
            case .draining(let deadline):
                if DispatchTime.now().uptimeNanoseconds >= deadline {
                    condition.unlock()
                    return
                }
                drainDeadline = deadline
            case .quitting:
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
                    if let drainDeadline,
                       DispatchTime.now().uptimeNanoseconds >= drainDeadline {
                        fatal = true
                        break
                    }
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
                    // Draining means "what is already readable": stop at the
                    // first EAGAIN. A quit or drain requested mid-fill is
                    // caught by the control pipe in the poll paths below.
                    if drainDeadline != nil {
                        fatal = true
                        break
                    }
                    if total < Self.bridgeThreshold {
                        break
                    }
                    if spins < Self.bridgeSpinMax {
                        spins += 1
                        continue
                    }

                    let now = DispatchTime.now().uptimeNanoseconds
                    if let start = bridgeStart {
                        if now - start >= Self.gatherBudgetNs {
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

                    let pollResult = Self.pollFds(&pollFds, count: pollFds.count, timeout: Self.bridgePollTimeoutMs)
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
                        // This consumes the control-pipe wake byte, so it
                        // must act on the phase change here: falling through
                        // to the blocking poll would sleep forever on a wake
                        // that was already drained. Read the phase after
                        // draining the pipe, so a request whose byte was
                        // consumed is never missed. Draining stops at what
                        // was read; the partial buffer is published below.
                        drainControlPipe()
                        if currentRunPhase() != .streaming {
                            fatal = true
                            break
                        }
                        continue
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
#if DEBUG
                precondition(slot == head, "Gather thread published a different slot")
                precondition(slotStates[slot] == .free, "Gather thread filled a slot that is not free")
                slotStates[slot] = .filled
#endif
                lens[head] = total
                head = (head + 1) % TerminalIOPipeline.bufferCount
                count += 1
                signalRingTransition()
                condition.unlock()
            }

            if fatal {
                return
            }
            if total == TerminalIOPipeline.bufferCapacity {
                continue
            }

            waitForInput: while true {
                let pollResult = Self.pollFds(&pollFds, count: 2, timeout: -1)
                if pollResult < 0 && errno == EINTR {
                    continue
                }
                if pollResult < 0 {
                    return
                }
                if Self.hasPollIn(pollFds[1]) {
                    // Drain the pipe before reading the phase, so a request
                    // whose wake byte was just consumed is never missed.
                    drainControlPipe()
                    switch currentRunPhase() {
                    case .quitting:
                        return
                    case .draining:
                        break waitForInput
                    case .streaming:
                        continue waitForInput
                    }
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

    /// Wakes the worker that can make progress after a ring transition. A
    /// non-streaming phase can also have a completion waiter on this condition.
    private func signalRingTransition() {
        if runPhase == .streaming {
            condition.signal()
        } else {
            condition.broadcast()
        }
    }

    private func clearBridging() {
        condition.lock()
        bridging = false
        condition.unlock()
    }

    private func currentRunPhase() -> RunPhase {
        condition.lock()
        let phase = runPhase
        condition.unlock()
        return phase
    }

    private func drainControlPipe() {
        drainWakePipe(controlReadFd)
    }

    private func drainIdlePipe() {
        drainWakePipe(idleReadFd)
    }

    private func drainWakePipe(_ readFd: Int32) {
        guard readFd >= 0 else {
            return
        }
        var trash = [UInt8](repeating: 0, count: 16)
        trash.withUnsafeMutableBytes { pointer in
            guard let base = pointer.baseAddress else {
                return
            }
            while true {
                let n = Self.readFd(readFd, into: base, count: pointer.count)
                if n < pointer.count {
                    break
                }
            }
        }
    }

    private func threadDidExit() {
        var shouldClose = false
        condition.lock()
        precondition(remainingThreads > 0, "TerminalIOPipeline worker count underflow")
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
            descriptors = [fd, controlReadFd, controlWriteFd, idleReadFd, idleWriteFd].filter { $0 >= 0 }
            fd = -1
            controlReadFd = -1
            controlWriteFd = -1
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
