//
//  LocalProcess.swift
//  
// This file contains the supporting infrastructure to run local processes that can be connected
// to a Termianl
//
//  Created by Miguel de Icaza on 4/5/20.
//
#if !os(iOS) && !os(Windows)
import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct WeakLocalProcessReference {
    weak var value: LocalProcess?
}

private struct WeakLocalProcessDelegateReference {
    weak var value: LocalProcessDelegate?
}

private enum LocalProcessPhase {
    case idle
    case starting
    case running
    case terminating
    case exited
    case deliveryPending
}

#if canImport(Darwin) || canImport(Glibc)
/// Reaps one child without allowing its PID to become reusable before a concurrent signal.
private final class LocalProcessChildReaper: @unchecked Sendable {
    let pid: pid_t

    private let lock = NSLock()
    private var signalAllowed = true

    init(pid: pid_t) {
        self.pid = pid
    }

    func signal(_ signal: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard signalAllowed else { return }
        kill(pid, signal)
    }

    func wait() -> Int32? {
        // Two callers can wait concurrently. Both observe with waitid; the
        // lock serializes the reap, and the caller that loses the race gets nil.
        // Observe exit without reaping. The zombie keeps its PID reserved
        // until the lock protects both the final waitpid and signalAllowed.
        var info = siginfo_t()
        var waitResult: Int32
        repeat {
            waitResult = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
        } while waitResult == -1 && errno == EINTR

        lock.lock()
        guard waitResult == 0 else {
            // The PID is no longer known to refer to this child. Do not send
            // a later signal to a PID that the kernel can reuse.
            signalAllowed = false
            lock.unlock()
            return nil
        }
        defer {
            signalAllowed = false
            lock.unlock()
        }

        var status: Int32 = 0
        var waitedPID: pid_t
        repeat {
            waitedPID = waitpid(pid, &status, 0)
        } while waitedPID == -1 && errno == EINTR
        return waitedPID == pid ? status : nil
    }
}
#else
/// Reaps one child on platforms without waitid and WNOWAIT.
private final class LocalProcessChildReaper: @unchecked Sendable {
    let pid: pid_t

    private let lock = NSLock()
    private var signalAllowed = true

    init(pid: pid_t) {
        self.pid = pid
    }

    func signal(_ signal: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard signalAllowed else { return }
        kill(pid, signal)
    }

    func wait() -> Int32? {
        var status: Int32 = 0
        var waitedPID: pid_t
        repeat {
            waitedPID = waitpid(pid, &status, 0)
        } while waitedPID == -1 && errno == EINTR

        // Two callers can wait safely, but waitpid reaps before this lock can
        // disable signaling. This leaves a slightly wider PID reuse window.
        lock.lock()
        signalAllowed = false
        lock.unlock()
        return waitedPID == pid ? status : nil
    }
}
#endif

/// Mutable process resources that must change as one lifecycle transaction.
private struct LocalProcessSessionState {
    var generation: UInt64 = 0
    var phase: LocalProcessPhase = .idle
    var childfd: Int32 = -1
    var shellPid: pid_t = 0
    var reaper: LocalProcessChildReaper?
    var pipeline: TerminalIOPipeline?
    var writeChannel: DispatchIO?
#if os(macOS)
    var childMonitor: DispatchSourceProcess?
#endif
    var drainTimeout: TimeInterval = 0.5
    var killEscalationDelay: TimeInterval = 0.5
    var loggingDirectory: String?
    var logFileCounter = 0
    var debugIO = false
    var totalRead = 0
}

private struct LocalProcessCounters {
    var sendCount = 0
    var totalWritten = 0
}

/// Delegate that is invoked by the ``LocalProcess`` class in response to various
/// process-related events.
public protocol LocalProcessDelegate: AnyObject {
    /// This method is invoked on the delegate when the process has exited.
    /// Use a serial `dispatchQueue` so data and termination callbacks stay ordered.
    /// - Parameter source: the local process that terminated
    /// - Parameter exitCode: the normalized exit status from 0 through 255, or nil when the process ended because of a signal or the wait failed
    func processTerminated (_ source: LocalProcess, exitCode: Int32?)
    
    /// This method is invoked when data has been received from the local process that should be send to the terminal for processing.
    func dataReceived (slice: ArraySlice<UInt8>)

    /// This method should return the window size to report to the local process.
    func getWindowSize () -> winsize
}

/// Receives process bytes that are valid only for the duration of the call.
/// Implementations must parse the bytes synchronously.
protocol LocalProcessBorrowedDataDelegate: AnyObject {
    func dataReceivedBorrowed(_ bytes: Span<UInt8>)

    // Lifetime checks that are intentionally not valid Swift:
    // storedBytes = bytes
    // Task { use(bytes) }
}

/**
 * This class provides the capabilities to launch a local Unix process, and connect it to a `Terminal`
 * class or subclass.
 *
 * The `MacLocalTerminalView` is an example of this, it is a subclass of the
 * `MacTerminalView` NSView, and it connects that view to the local system, providing a complete
 * terminal emulator connected to running local commands.
 *
 * When you create an instance of `LocalProcess`, you provide a delegate that is used to notify
 * your application when data is received from the lcoal process, to request the desired window size
 * that you would like to give to the child process, and when the process terminates.
 *
 * Once you create this instance, you can start a child process by calling the `startProcess` method
 * which will start the process.   You can then send data to this underlying process using the
 * `send(data:)` method, and you will receive the output on the provided delegate with the
 * `dataReceived(slice:)` method.
 *
 * Received data is dispatched via the queue that you provide in the LocalProcess constructor. If you do
 * not provide a queue, LocalProcess creates a private serial queue. Pass `DispatchQueue.main` explicitly
 * when the delegate must receive callbacks on the main queue.
 *
 * The `terminate` call will send the `SIGTERM` signal to the child process.
 *
 * The `shellPid` property has the PID for the child process, and this can be used to send signals
 * to it using the `kill` API.
 *
 * The `childfd` property has the Unix file descriptor for the primary side of the created pseudo-terminal.
 *
 * This implementation uses forkpty for pseudo-terminal support.
 */
public class LocalProcess {
    private let session = Locked(LocalProcessSessionState())
    private let counters = Locked(LocalProcessCounters())
    private let delegateReference = Locked(WeakLocalProcessDelegateReference())

    /// The current primary pseudo-terminal descriptor, or `-1` when inactive.
    public var childfd: Int32 { session.withLock { $0.childfd } }

    /// The current child process identifier, or zero when inactive.
    public var shellPid: pid_t { session.withLock { $0.shellPid } }

    /// Bounds the output drain between child exit and the termination callback.
    /// A timed-out drain can drop output that has not yet been delivered.
    public var drainTimeout: TimeInterval {
        get { session.withLock { $0.drainTimeout } }
        set { session.withLock { $0.drainTimeout = newValue } }
    }

    /// Sets the delay before deinitialization escalates from SIGTERM to SIGKILL.
    public var killEscalationDelay: TimeInterval {
        get { session.withLock { $0.killEscalationDelay } }
        set { session.withLock { $0.killEscalationDelay = newValue } }
    }

    var debugIO: Bool {
        get { session.withLock { $0.debugIO } }
        set { session.withLock { $0.debugIO = newValue } }
    }

    var sendCount: Int { counters.withLock { $0.sendCount } }
    var total: Int { counters.withLock { $0.totalWritten } }
    
    // Queue used to send the data received from the local process
    let dispatchQueue: DispatchQueue
    let directDelivery: Bool

    let writeQueue = DispatchQueue(label: "swiftterm-writer")
    /// Lets dispatch handlers find the process without capturing a
    /// non-Sendable owner or forming a retain cycle.
    private let lifecycleReference = Locked(WeakLocalProcessReference())
    
    /**
     * Initializes the LocalProcess runner and communication with the host happens via the provided
     * `LocalProcessDelegate` instance.
     * - Parameter delegate: the delegate that will receive events or request data from your application
     * - Parameter dispatchQueue: this is the queue that will be used to post data received from the
     * child process when calling the `send(dataReceived:)` delegate method. If the value is `nil`,
     * LocalProcess creates a private serial queue. Pass `DispatchQueue.main` explicitly when required.
     * - Parameter directDelivery: when true, data received by the IO pipeline is delivered inline on the
     * pipeline parse thread instead of synchronously hopping to `dispatchQueue`.
     */
    public init (delegate: LocalProcessDelegate, dispatchQueue: DispatchQueue? = nil, directDelivery: Bool = false)
    {
        self.dispatchQueue = Self.effectiveDeliveryQueue(dispatchQueue)
        self.directDelivery = directDelivery
        delegateReference.withLock { $0.value = delegate }
        lifecycleReference.withLock { $0.value = self }
    }

    /// Returns the queue used for queued process delivery.
    ///
    /// `HeadlessTerminal` resolves this once and passes the same queue to its
    /// `LocalProcess`. This keeps input registration and process output in one
    /// FIFO domain when the caller does not supply a queue.
    static func effectiveDeliveryQueue(_ queue: DispatchQueue?) -> DispatchQueue {
        queue ?? DispatchQueue(label: "org.swiftterm.local-process.delivery")
    }
    
    /**
     * Sends the array slice to the local process using DispatchIO
     * - Parameter data: The range of bytes to send to the child process
     */
    public func send (data: ArraySlice<UInt8>)
    {
        guard let sendState = session.withLock({ state
            -> (channel: DispatchIO, debug: Bool)? in
            guard state.phase == .running || state.phase == .terminating,
                  let channel = state.writeChannel else {
                return nil
            }
            return (channel, state.debugIO)
        }) else { return }
        let copy = counters.withLock { counters -> Int in
            defer { counters.sendCount += 1 }
            return counters.sendCount
        }
        let counters = counters
        let session = session

        data.withUnsafeBytes { ptr in
            let ddata = DispatchData(bytes: ptr)
            let copyCount = ddata.count
            if sendState.debug {
                print ("[SEND-\(copy)] Queuing data to client: \(data) ")
            }

            sendState.channel.write(offset: 0, data: ddata, queue: writeQueue, ioHandler: { done, _, errno in
                if done {
                    let written = counters.withLock { counters -> Int in
                        counters.totalWritten += copyCount
                        return counters.totalWritten
                    }
                    if session.withLock({ $0.debugIO }) {
                        print ("[SEND-\(copy)] completed bytes=\(written)")
                    }
                }
                if errno != 0 {
                    print ("Error writing data to the child, errno=\(errno)")
                }
            })
        }

    }
    /// Indicates if the child process is currently running.
    public var running: Bool {
        session.withLock {
            $0.phase == .running || $0.phase == .terminating || $0.phase == .exited
        }
    }

    deinit {
#if os(macOS)
        let resources = session.withLock { state -> (
            pipeline: TerminalIOPipeline?,
            writeChannel: DispatchIO?,
            reaper: LocalProcessChildReaper?,
            monitor: DispatchSourceProcess?,
            killEscalationDelay: TimeInterval
        ) in
            let resources = (
                state.pipeline,
                state.writeChannel,
                state.reaper,
                state.childMonitor,
                state.killEscalationDelay
            )
            state = LocalProcessSessionState()
            return resources
        }
#else
        let resources = session.withLock { state -> (
            pipeline: TerminalIOPipeline?,
            writeChannel: DispatchIO?,
            reaper: LocalProcessChildReaper?,
            killEscalationDelay: TimeInterval
        ) in
            let resources = (
                state.pipeline,
                state.writeChannel,
                state.reaper,
                state.killEscalationDelay
            )
            state = LocalProcessSessionState()
            return resources
        }
#endif

        resources.writeChannel?.close(flags: [])
        if let pipeline = resources.pipeline {
            // A synchronous join can deadlock when the last owner releases the
            // process on the delivery queue while parsing waits in queue.sync.
            DispatchQueue.global(qos: .utility).async {
                pipeline.shutdown()
            }
        }
#if os(macOS)
        // Deinit cancels the source before detached reaping. The exit event may
        // not have fired, and reaping while the source is armed can crash when
        // libdispatch tries to re-arm the vanished knote.
        resources.monitor?.cancel()
#endif

        if let reaper = resources.reaper {
            reaper.signal(SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + resources.killEscalationDelay
            ) {
                reaper.signal(SIGKILL)
            }
            Self.startChildWaiter {
                _ = reaper.wait()
            }
        }
    }

    /// Starts a dedicated waiter so a blocking waitpid does not occupy a
    /// shared libdispatch worker.
    private static func startChildWaiter(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = "swiftterm-child-reaper"
        thread.start()
    }

    static func exitCode(fromWaitStatus status: Int32?) -> Int32? {
        guard let status, status & 0x7f == 0 else { return nil }
        return (status >> 8) & 0xff
    }

    private func childDidExit(generation: UInt64, status: Int32?) {
        let drain = session.withLock { state -> (
            pipeline: TerminalIOPipeline?,
            timeout: TimeInterval
        )? in
            guard state.generation == generation,
                  state.phase == .running || state.phase == .terminating else {
                return nil
            }
            state.phase = .exited
            state.shellPid = 0
            state.childfd = -1
            // Keep the pipeline published during the drain. The receive path
            // uses identity to accept every buffered batch from this pipeline.
            return (state.pipeline, state.drainTimeout)
        }
        guard let drain else { return }

        _ = drain.pipeline?.drainAvailableAndShutdown(timeout: drain.timeout)
        let exitCode = Self.exitCode(fromWaitStatus: status)

        let teardown = session.withLock { state -> (
            accepted: Bool,
            writeChannel: DispatchIO?
        ) in
            guard state.generation == generation, state.phase == .exited else {
                return (false, nil)
            }
            state.pipeline = nil
            state.reaper = nil
            let writeChannel = state.writeChannel
            state.writeChannel = nil
            state.phase = .deliveryPending
            return (true, writeChannel)
        }
        guard teardown.accepted else { return }
        teardown.writeChannel?.close(flags: [])

        let lifecycleReference = lifecycleReference
        dispatchQueue.async {
            lifecycleReference.withLock { $0.value }?.finishTermination(
                generation: generation,
                exitCode: exitCode)
        }
    }

    private func finishTermination(generation: UInt64, exitCode: Int32?) {
        let shouldDeliver = session.withLock { state -> Bool in
            guard state.generation == generation,
                  state.phase == .deliveryPending else {
                return false
            }
            state.phase = .idle
            return true
        }
        guard shouldDeliver else { return }
        let delegate = delegateReference.withLock { $0.value }
        delegate?.processTerminated(self, exitCode: exitCode)
    }
    
    /**
     * Launches a child process inside a pseudo-terminal
     * - Parameter executable: The executable to launch inside the pseudo terminal, defaults to /bin/bash
     * - Parameter args: an array of strings that is passed as the arguments to the underlying process
     * - Parameter environment: an array of environment variables to pass to the child process, if this is null, this picks a good set of defaults from `Terminal.getEnvironmentVariables`.
     * - Parameter execName: If provided, this is used as the Unix argv[0] parameter, otherwise, the executable is used as the args [0], this is used when the intent is to set a different process name than the file that backs it.
     */
    public func startProcess(executable: String = "/bin/bash", args: [String] = [], environment: [String]? = nil, execName: String? = nil, currentDirectory: String? = nil)
     {
        startProcessWithForkpty(executable: executable, args: args, environment: environment, execName: execName, currentDirectory: currentDirectory)
    }

    private func startProcessWithForkpty(executable: String, args: [String], environment: [String]?, execName: String?, currentDirectory: String?) {
        let admitted = session.withLock { state -> Bool in
            guard state.phase == .idle else { return false }
            state.phase = .starting
            return true
        }
        guard admitted else { return }

        let delegate = delegateReference.withLock { $0.value }
        var size = delegate?.getWindowSize () ?? winsize()
    
        var shellArgs = args
        if let firstArgName = execName {
            shellArgs.insert (firstArgName, at: 0)
        } else {
            shellArgs.insert(executable, at: 0)
        }
        
        var env: [String]
        if environment == nil {
            env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        } else {
            env = environment!
        }

        guard let (shellPid, childfd) = PseudoTerminalHelpers.fork(
            andExec: executable,
            args: shellArgs,
            env: env,
            currentDirectory: currentDirectory,
            desiredWindowSize: &size
        ) else {
            session.withLock { state in
                if state.phase == .starting {
                    state.phase = .idle
                }
            }
            return
        }

        let launch = session.withLock { state -> (
            generation: UInt64,
            reaper: LocalProcessChildReaper
        ) in
            state.generation &+= 1
            state.phase = .running
            state.shellPid = shellPid
            state.childfd = childfd
            let reaper = LocalProcessChildReaper(pid: shellPid)
            state.reaper = reaper
            return (state.generation, reaper)
        }

        let writeFd = dup(childfd)
        let writeChannel: DispatchIO?
        if writeFd >= 0 {
            writeChannel = DispatchIO(type: .stream, fileDescriptor: writeFd, queue: writeQueue, cleanupHandler: { _ in
                close(writeFd)
            })
        } else {
            // The read pipeline owns childfd. A DispatchIO channel on the
            // same descriptor can retain a kevent after the pipeline
            // closes it and make libdispatch abort with EV_VANISHED.
            // Keep the read side alive and disable input for this rare
            // file-descriptor-pressure failure.
            writeChannel = nil
        }
        session.withLock { $0.writeChannel = writeChannel }

        let pipeline = TerminalIOPipeline(fd: childfd, delegate: self)
        session.withLock { $0.pipeline = pipeline }
        pipeline.start()

#if os(macOS)
        let childMonitor: DispatchSourceProcess? = DispatchSource.makeProcessSource(
            identifier: shellPid, eventMask: .exit, queue: dispatchQueue)
        session.withLock { $0.childMonitor = childMonitor }
        if let childMonitor {
            // Install the handler before activating the source. NOTE_EXIT is
            // delivered at most once. If a fast child's event arrives before
            // the handler is set, it is dropped and never delivered again.
            // Also resume the pre-10.12 source because it starts suspended.
            let lifecycleReference = lifecycleReference
            let reaper = launch.reaper
            let generation = launch.generation
            childMonitor.setEventHandler {
                Self.startChildWaiter {
                    let status = reaper.wait()
                    let process = lifecycleReference.withLock { $0.value }
                    let monitor = process?.session.withLock { state -> DispatchSourceProcess? in
                        guard state.generation == generation else { return nil }
                        let monitor = state.childMonitor
                        state.childMonitor = nil
                        return monitor
                    }
                    // Normal exit reaps first, then cancels the source. Reaping
                    // destroys the knote that the process source watches.
                    monitor?.cancel()
                    process?.childDidExit(generation: generation, status: status)
                }
            }
            if #available(macOS 10.12, *) {
                childMonitor.activate()
            } else {
                childMonitor.resume()
            }
        }
#else
        let lifecycleReference = lifecycleReference
        let reaper = launch.reaper
        let generation = launch.generation
        Self.startChildWaiter {
            let status = reaper.wait()
            let process = lifecycleReference.withLock { $0.value }
            process?.childDidExit(generation: generation, status: status)
        }
#endif
    }

    public func terminate() {
        let reaper = session.withLock { state -> LocalProcessChildReaper? in
            switch state.phase {
            case .running:
                state.phase = .terminating
                return state.reaper
            case .terminating:
                return state.reaper
            default:
                return nil
            }
        }
        reaper?.signal(SIGTERM)
    }
    
    /**
     * Use this method to toggle the logging of data coming from the host, or pass nil to stop
     * - Parameter directory: location where the log files will be stored.
     */
    public func setHostLogging (directory: String?)
    {
        session.withLock { state in
            state.loggingDirectory = directory
            state.logFileCounter = 0
        }
    }

    /// Applies a window size only while the published pty descriptor is live.
    /// EOF and teardown take the same session lock before invalidating it.
    @discardableResult
    func updateWindowSize(_ size: inout winsize) -> Bool {
        session.withLock { state in
            guard state.phase == .running || state.phase == .terminating,
                  state.childfd >= 0 else { return false }
            _ = PseudoTerminalHelpers.setWinSize(
                masterPtyDescriptor: state.childfd, windowSize: &size)
            return true
        }
    }
}

extension LocalProcess: TerminalIOPipelineDelegate {
    func pipeline(_ pipeline: TerminalIOPipeline, received data: Span<UInt8>) {
        let delivery = session.withLock { state
            -> (debugTotal: Int?, logPath: String?)? in
            guard state.pipeline === pipeline else { return nil }
            let debugTotal: Int?
            if state.debugIO {
                state.totalRead += data.count
                debugTotal = state.totalRead
            } else {
                debugTotal = nil
            }
            let logPath: String?
            if let directory = state.loggingDirectory {
                logPath = directory + "/log-\(state.logFileCounter)"
                state.logFileCounter += 1
            } else {
                logPath = nil
            }
            return (debugTotal, logPath)
        }
        guard let delivery else { return }
        if let debugTotal = delivery.debugTotal {
            print("[READ] count=\(data.count) received from host total=\(debugTotal)")
        }

        if let path = delivery.logPath {
            let ownedData = Data(data.copiedBytes())
            do {
                try ownedData.write(to: URL(fileURLWithPath: path))
            } catch {
                print("Got error while logging data dump to \(path): \(error)")
            }
        }

        let delegate = delegateReference.withLock { $0.value }
        if directDelivery,
           let borrowedDelegate = delegate as? LocalProcessBorrowedDataDelegate {
            borrowedDelegate.dataReceivedBorrowed(data)
            return
        }

        // Queued and compatibility delivery must own the bytes before this
        // callback returns and the ring slot becomes reusable.
        let copy = data.copiedBytes()
        if directDelivery {
            delegate?.dataReceived(slice: copy[...])
        } else {
            let delegateReference = delegateReference
            dispatchQueue.sync {
                let delegate = delegateReference.withLock { $0.value }
                delegate?.dataReceived(slice: copy[...])
            }
        }
    }

    func pipelineDidReachEOF(_ pipeline: TerminalIOPipeline) {
        session.withLock { state in
            guard state.pipeline === pipeline else { return }
            // The worker closes the descriptor after this callback. Publish
            // invalidation while it still holds its descriptor.
            state.childfd = -1
        }
    }
}
#endif
