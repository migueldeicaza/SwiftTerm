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
#if false //canImport(Subprocess)
import Subprocess
import System
#endif

private struct WeakLocalProcessReference {
    weak var value: LocalProcess?
}

private struct WeakLocalProcessDelegateReference {
    weak var value: LocalProcessDelegate?
}

/// Mutable process resources that must change as one lifecycle transaction.
private struct LocalProcessSessionState {
    var childfd: Int32 = -1
    var shellPid: pid_t = 0
    var running = false
    var pipeline: TerminalIOPipeline?
    var writeChannel: DispatchIO?
    var loggingDirectory: String?
    var logFileCounter = 0
    var debugIO = false
    var totalRead = 0
#if os(macOS)
    var childMonitor: DispatchSourceProcess?
#endif
}

private struct LocalProcessCounters {
    var sendCount = 0
    var totalWritten = 0
}

private struct LocalProcessShutdownResources {
    let writeChannel: DispatchIO?
    let pipeline: TerminalIOPipeline?
    let pid: pid_t
#if os(macOS)
    let monitor: DispatchSourceProcess?
#endif

    func cancelMonitor() {
#if os(macOS)
        monitor?.cancel()
#endif
    }
}

private struct LocalProcessExitOutcome {
    let pid: pid_t
#if os(macOS)
    let monitor: DispatchSourceProcess?
#endif

    func cancelMonitor() {
#if os(macOS)
        monitor?.cancel()
#endif
    }
}

/// Marks a synchronous delegate callback that the parse worker is waiting for.
/// Shutdown from this context must not wait for that worker.
private final class LocalProcessDeliveryContext: Sendable {
    private static let key = "org.tirania.SwiftTerm.local-process-delivery"
    private let marker = UUID().uuidString

    var isCurrent: Bool {
        Thread.current.threadDictionary[Self.key] as? String == marker
    }

    func perform(_ body: () -> Void) {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[Self.key]
        dictionary[Self.key] = marker
        defer {
            if let previous {
                dictionary[Self.key] = previous
            } else {
                dictionary.removeObject(forKey: Self.key)
            }
        }
        body()
    }
}

/// Delegate that is invoked by the ``LocalProcess`` class in response to various
/// process-related events.
public protocol LocalProcessDelegate: AnyObject {
    /// This method is invoked on the delegate when the process has exited
    /// - Parameter source: the local process that terminated
    /// - Parameter exitCode: the exit code returned by the process, or nil if this was an error caused during the IO reading/writing
    func processTerminated (_ source: LocalProcess, exitCode: Int32?)
    
    /// This method is invoked when data has been received from the local process that should be send to the terminal for processing.
    func dataReceived (slice: ArraySlice<UInt8>)

    /// This method should return the window size to report to the local process.
    func getWindowSize () -> winsize
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
 * This implementation uses swift-subprocess with openpty/login_tty for pseudo-terminal support.
 */
public class LocalProcess {
    private let session = Locked(LocalProcessSessionState())
    private let counters = Locked(LocalProcessCounters())
    private let lifecycleLock = NSLock()
    private let delegateReference = Locked(WeakLocalProcessDelegateReference())
    private let deliveryContext = LocalProcessDeliveryContext()

    /// The current primary pseudo-terminal descriptor, or `-1` when inactive.
    public var childfd: Int32 { session.withLock { $0.childfd } }

    /// The current child process identifier, or zero when inactive.
    public var shellPid: pid_t { session.withLock { $0.shellPid } }

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
    
    #if false //canImport(Subprocess)
    // Swift Subprocess related properties
    private var subprocessTask: Task<Void, Error>?
    private var masterFd: Int32 = -1
    private var slaveFd: Int32 = -1
    #endif
    
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
            guard state.running, let channel = state.writeChannel else {
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
    
    #if false //canImport(Subprocess)
    // Create pseudo-terminal pair using openpty
    private func createPseudoTerminal() throws -> (master: Int32, slave: Int32) {
        var master: Int32 = -1
        var slave: Int32 = -1
        
        let result = openpty(&master, &slave, nil, nil, nil)
        guard result == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
        
        return (master: master, slave: slave)
    }
    
    // Set up login tty for the slave side
    private func setupLoginTty(slaveFd: Int32) throws {
        let result = login_tty(slaveFd)
        guard result == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
    }
    #endif

    func childStopped(cancelProcessMonitor: Bool = true,
                      ifCurrentPipeline expectedPipeline: TerminalIOPipeline? = nil) {
#if os(macOS)
        let monitor = session.withLock { state -> DispatchSourceProcess? in
            if let expectedPipeline, state.pipeline !== expectedPipeline {
                return nil
            }
            state.running = false
            guard cancelProcessMonitor else { return nil }
            defer { state.childMonitor = nil }
            return state.childMonitor
        }
        monitor?.cancel()
#else
        session.withLock { state in
            if let expectedPipeline, state.pipeline !== expectedPipeline {
                return
            }
            state.running = false
        }
#endif
    }

    /// Indicates if the child process is currently running.
    public var running: Bool { session.withLock { $0.running } }

    private func stopPipeline(_ pipeline: TerminalIOPipeline?) {
        guard let pipeline else { return }
        if deliveryContext.isCurrent {
            // The parse worker is synchronously waiting for this delegate
            // callback. Let the callback return before another thread joins
            // the worker; backpressure and callback ordering stay unchanged.
            DispatchQueue.global(qos: .utility).async {
                pipeline.shutdown()
            }
        } else {
            pipeline.shutdown()
        }
    }

    private func takeResourcesForShutdown()
        -> LocalProcessShutdownResources
    {
        session.withLock { state in
#if os(macOS)
            let resources = LocalProcessShutdownResources(
                writeChannel: state.writeChannel,
                pipeline: state.pipeline,
                pid: state.shellPid,
                monitor: state.childMonitor
            )
#else
            let resources = LocalProcessShutdownResources(
                writeChannel: state.writeChannel,
                pipeline: state.pipeline,
                pid: state.shellPid
            )
#endif
            state.writeChannel = nil
            state.pipeline = nil
            state.childfd = -1
            state.shellPid = 0
            state.running = false
#if os(macOS)
            state.childMonitor = nil
#endif
            return resources
        }
    }

    deinit {
        let resources = takeResourcesForShutdown()
        resources.cancelMonitor()
        resources.writeChannel?.close(flags: [])
        stopPipeline(resources.pipeline)
    }

    func processTerminated ()
    {
        let outcome: LocalProcessExitOutcome? = session.withLock { state in
            guard state.shellPid != 0 else { return nil }
#if os(macOS)
            let result = LocalProcessExitOutcome(
                pid: state.shellPid,
                monitor: state.childMonitor
            )
#else
            let result = LocalProcessExitOutcome(pid: state.shellPid)
#endif
            state.shellPid = 0
            state.running = false
#if os(macOS)
            state.childMonitor = nil
#endif
            return result
        }
        guard let outcome else { return }
        var n: Int32 = 0
        waitpid(outcome.pid, &n, WNOHANG)
        outcome.cancelMonitor()
        let delegate = delegateReference.withLock { $0.value }
        deliveryContext.perform {
            delegate?.processTerminated(self, exitCode: n)
        }
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
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let canStart = session.withLock { !$0.running && $0.shellPid == 0 }
        if !canStart { return }
        
        #if false //canImport(Subprocess)
        startProcessWithSubprocess(executable: executable, args: args, environment: environment, execName: execName, currentDirectory: currentDirectory)
        #else
        startProcessWithForkpty(executable: executable, args: args, environment: environment, execName: execName, currentDirectory: currentDirectory)
        #endif
    }
    
    #if false //canImport(Subprocess)
    private func startProcessWithSubprocess(executable: String, args: [String], environment: [String]?, execName: String?, currentDirectory: String?) {
        do {
            var size = delegate?.getWindowSize () ?? winsize()
            
            // Create pseudo-terminal pair using openpty
            let (master, slave) = try createPseudoTerminal()
            self.masterFd = master
            self.slaveFd = slave
            self.childfd = master
            
            // Set window size on the master fd
            _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: master, windowSize: &size)
            
            // Prepare environment
            var env: [String: String] = [:]
            let envArray = environment ?? Terminal.getEnvironmentVariables(termName: "xterm-256color")
            for envVar in envArray {
                let components = envVar.split(separator: "=", maxSplits: 1)
                if components.count == 2 {
                    env[String(components[0])] = String(components[1])
                }
            }
            
            // Create FileDescriptor instances for swift-subprocess
            let slaveFileDescriptor = System.FileDescriptor(rawValue: slave)
            
            // Mark as running and set up I/O for reading from master fd first
            running = true
            // Capture FD values for cleanup handler to close them safely after DispatchIO is done
            let masterToClose = master
            let slaveToClose = slave
            io = DispatchIO(type: .stream, fileDescriptor: master, queue: dispatchQueue, cleanupHandler: { _ in
                // Close file descriptors after DispatchIO has finished with them
                // This prevents EV_VANISHED crash by ensuring proper cleanup order
                close(masterToClose)
                close(slaveToClose)
            })
            guard let io else {
                return
            }
            io.setLimit(lowWater: 1)
            io.setLimit(highWater: readSize)
            io.read(offset: 0, length: readSize, queue: readQueue) { [weak self] done, data, errno in
                self?.childProcessRead(done: done, data: data, errno: errno)
            }

            // Start subprocess with swift-subprocess asynchronously
            Task {
                do {
                    // Start subprocess with swift-subprocess, using the slave side of the pty
                    // The subprocess will automatically handle the pseudo-terminal setup when using FileDescriptor I/O
                    var options = PlatformOptions()
                    options.preSpawnProcessConfigurator = { spawnAttr, fileAttr in
                        var flags: Int16 = 0
                        posix_spawnattr_getflags(&spawnAttr, &flags)
                        posix_spawnattr_setflags(&spawnAttr, flags | Int16(POSIX_SPAWN_SETSID))
                        
                    }
                    let result = try await Subprocess.run(
                        .name(executable),
                        arguments: Arguments(executablePathOverride: execName ?? executable, remainingValues: Array(args)),
                        environment: .custom(Dictionary(uniqueKeysWithValues: env.map { (Environment.Key(stringLiteral: $0.key), $0.value) })),
                        workingDirectory: currentDirectory.map { System.FilePath($0) },
                        platformOptions: options,
                        input: .fileDescriptor(slaveFileDescriptor, closeAfterSpawningProcess: true),
                        output: .fileDescriptor(slaveFileDescriptor, closeAfterSpawningProcess: false),
                        error: .fileDescriptor(slaveFileDescriptor, closeAfterSpawningProcess: false)
                    )
                    
                    // Process completed
                    await MainActor.run {
                        childStopped()
                        let exitCode: Int32?
                        switch result.terminationStatus {
                        case .exited(let code):
                            exitCode = code
                        default:
                            exitCode = nil
                        }
                        self.delegate?.processTerminated(self, exitCode: exitCode)
                    }

                } catch {
                    await MainActor.run {
                        childStopped()
                        self.delegate?.processTerminated(self, exitCode: nil)
                    }
                    print("Failed to start process with swift-subprocess: \(error)")
                }
            }
            
        } catch {
            childStopped()
            delegate?.processTerminated(self, exitCode: nil)
            print("Failed to create pseudo-terminal: \(error)")
        }
    }
    #endif
    
    private func startProcessWithForkpty(executable: String, args: [String], environment: [String]?, execName: String?, currentDirectory: String?) {
        // A restart after the previous child exited may leave the prior
        // session's channels alive; release them so the dup()'d write fd is
        // not leaked and the old pipeline winds down.
        let previous = session.withLock { state -> (DispatchIO?, TerminalIOPipeline?) in
            defer {
                state.writeChannel = nil
                state.pipeline = nil
                state.childfd = -1
            }
            return (state.writeChannel, state.pipeline)
        }
        previous.0?.close(flags: [])
        stopPipeline(previous.1)

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

        if let (shellPid, childfd) = PseudoTerminalHelpers.fork(andExec: executable, args: shellArgs, env: env, currentDirectory: currentDirectory, desiredWindowSize: &size) {
            // Publish process state before arming the exit source below. The
            // source's event handler (installed just below) can be invoked
            // synchronously by activate() when the child has already exited,
            // and processTerminated() reads self.shellPid (a 0 here makes
            // waitpid(0, ...) target the caller's process group, which never
            // matches the setsid child). Setting the process state first
            // keeps that early callback correct.
            session.withLock { state in
                state.running = true
                state.childfd = childfd
                state.shellPid = shellPid
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
#if os(macOS)
            let childMonitor: DispatchSourceProcess? = DispatchSource.makeProcessSource(
                identifier: shellPid, eventMask: .exit, queue: dispatchQueue)
            session.withLock { $0.childMonitor = childMonitor }
            if let cm = childMonitor {
                // Install the handler before activating the source. NOTE_EXIT
                // is delivered at most once; if the source is activated first
                // and a fast-exiting child's exit fires before the handler is
                // set, the event is dropped and never redelivered, so
                // processTerminated() never runs — the child is not reaped and
                // callers waiting on exit hang. Also resume() on the pre-10.12
                // path, which previously did nothing (the source is created
                // suspended, so without resume it never starts).
                let lifecycleReference = lifecycleReference
                cm.setEventHandler(handler: {
                    let process = lifecycleReference.withLock { $0.value }
                    process?.processTerminated()
                })
                if #available(macOS 10.12, *) {
                    cm.activate()
                } else {
                    cm.resume()
                }
            }
#endif
            let pipeline = TerminalIOPipeline(fd: childfd, delegate: self)
            session.withLock { $0.pipeline = pipeline }
            pipeline.start()
        }
    }

    public func terminate()
    {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        #if false //canImport(Subprocess)
        if let task = subprocessTask {
            task.cancel()
            subprocessTask = nil
        }

        // Set FD markers to -1 (actual FDs are closed by DispatchIO cleanup handler)
        masterFd = -1
        slaveFd = -1
        #endif

        let resources = takeResourcesForShutdown()
        resources.cancelMonitor()
        resources.writeChannel?.close(flags: [])
        stopPipeline(resources.pipeline)
        if resources.pid != 0 {
            kill(resources.pid, SIGTERM)
        }
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
            guard state.running, state.childfd >= 0 else { return false }
            _ = PseudoTerminalHelpers.setWinSize(
                masterPtyDescriptor: state.childfd, windowSize: &size)
            return true
        }
    }
}

extension LocalProcess: TerminalIOPipelineDelegate {
    func pipeline(_ pipeline: TerminalIOPipeline, received data: [UInt8]) {
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
            print ("[READ] count=\(data.count) received from host total=\(debugTotal)")
        }

        if let path = delivery.logPath {
            do {
                try Data(data).write(to: URL.init(fileURLWithPath: path))
            } catch {
                // Ignore write error
                print ("Got error while logging data dump to \(path): \(error)")
            }
        }

        let delegate = delegateReference.withLock { $0.value }
        if directDelivery {
            delegate?.dataReceived(slice: data[...])
        } else {
            let deliveryContext = deliveryContext
            let delegateReference = delegateReference
            dispatchQueue.sync {
                deliveryContext.perform {
                    let delegate = delegateReference.withLock { $0.value }
                    delegate?.dataReceived(slice: data[...])
                }
            }
        }
    }

    func pipelineDidReachEOF(_ pipeline: TerminalIOPipeline) {
        let wasRunning = session.withLock { state -> Bool? in
            guard state.pipeline === pipeline else { return nil }
            // The worker closes the descriptor after this callback. Publish
            // invalidation while it still holds its descriptor.
            state.childfd = -1
            return state.running
        }
        guard let wasRunning else { return }
        let lifecycleReference = lifecycleReference
        dispatchQueue.async {
            guard let process = lifecycleReference.withLock({ $0.value }),
                  wasRunning else { return }
            process.childStopped(
                cancelProcessMonitor: false,
                ifCurrentPipeline: pipeline)
        }
    }
}
#endif
