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
#if canImport(Subprocess)
import Subprocess
import System
#endif

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
 * Received data is dispatched via the queue that you provide in the LocalProcess constructor, if none
 * is provided, this will default to `DispatchQueue.main`.  Generally, this is a good default, but if you
 * have your own main loop or a different dispatching system, you will need to pass your own (for example,
 * the `HeadlessTerminal` implementation in the test suite does this.
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
    let readSize = 128*1024
    
    /* The file descriptor used to communicate with the child process */
    public private(set) var childfd: Int32 = -1
    
    /* The PID of our subprocess */
    public private(set) var shellPid: pid_t = 0
    var debugIO = false
    
    /* number of sent requests */
    var sendCount = 0
    var total = 0

    weak var delegate: LocalProcessDelegate?
    
    // Queue used to send the data received from the local process
    var dispatchQueue: DispatchQueue
    
    // The queue we use to read, it feels more interactive if we
    // read here and then post to the main thread.   Otherwise it feels
    // chunky.
    var readQueue: DispatchQueue
    
    var io: DispatchIO?
    
    #if canImport(Subprocess)
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
     * child process when calling the `send(dataReceived:)` delegate method.  If the value provided is `nil`,
     * then this will default to `DispatchQueue.main`
     */
    public init (delegate: LocalProcessDelegate, dispatchQueue: DispatchQueue? = nil)
    {
        self.delegate = delegate
        self.dispatchQueue = dispatchQueue ?? DispatchQueue.main
        self.readQueue = DispatchQueue(label: "sender")
    }
    
    /**
     * Sends the array slice to the local process using DispatchIO
     * - Parameter data: The range of bytes to send to the child process
     */
    public func send (data: ArraySlice<UInt8>)
    {
        guard running else {
            return
        }
        let copy = sendCount
        sendCount += 1
        data.withUnsafeBytes { ptr in
            let ddata = DispatchData(bytes: ptr)
            let copyCount = ddata.count
            if debugIO {
                print ("[SEND-\(copy)] Queuing data to client: \(data) ")
            }

            DispatchIO.write(toFileDescriptor: childfd, data: ddata, runningHandlerOn: DispatchQueue.global(qos: .userInitiated), handler:  { dd, errno in
                self.total += copyCount
                if self.debugIO {
                    print ("[SEND-\(copy)] completed bytes=\(self.total)")
                }
                if errno != 0 {
                    print ("Error writing data to the child, errno=\(errno)")
                }
            })
        }

    }
    
    /* Used to generate the next file name counter */
    var logFileCounter = 0
    
    #if canImport(Subprocess)
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
    
    /* Total number of bytes read */
    var totalRead = 0
    func childProcessRead (done: Bool, data: DispatchData?, errno: Int32) {
        guard let data else {
            return
        }
        if debugIO {
            totalRead += data.count
            print ("[READ] count=\(data.count) received from host total=\(totalRead)")
        }
        
        if data.count == 0 {
            childfd = -1
            if running {
                running = false
                // delegate.processTerminated (self, exitCode: nil)
            }
            return
        }
        var b: [UInt8] = Array.init(repeating: 0, count: data.count)
        b.withUnsafeMutableBufferPointer({ ptr in
            let _ = data.copyBytes(to: ptr)
            if let dir = loggingDir {
                let path = dir + "/log-\(logFileCounter)"
                do {
                    let dataCopy = Data (ptr)
                    try dataCopy.write(to: URL.init(fileURLWithPath: path))
                    logFileCounter += 1
                } catch {
                    // Ignore write error
                    print ("Got error while logging data dump to \(path): \(error)")
                }
            }
        })
        dispatchQueue.sync {
            delegate?.dataReceived(slice: b[...])
        }
        io?.read(offset: 0, length: readSize, queue: readQueue, ioHandler: childProcessRead)
    }

#if os(macOS)
    var childMonitor: DispatchSourceProcess?
#endif

    func processTerminated ()
    {
        var n: Int32 = 0
        waitpid (shellPid, &n, WNOHANG)
        delegate?.processTerminated(self, exitCode: n)
        running = false
    }
    
    /// Indicates if the child process is currently running
    public private(set) var running: Bool = false
    
    /**
     * Launches a child process inside a pseudo-terminal
     * - Parameter executable: The executable to launch inside the pseudo terminal, defaults to /bin/bash
     * - Parameter args: an array of strings that is passed as the arguments to the underlying process
     * - Parameter environment: an array of environment variables to pass to the child process, if this is null, this picks a good set of defaults from `Terminal.getEnvironmentVariables`.
     * - Parameter execName: If provided, this is used as the Unix argv[0] parameter, otherwise, the executable is used as the args [0], this is used when the intent is to set a different process name than the file that backs it.
     */
    public func startProcess(executable: String = "/bin/bash", args: [String] = [], environment: [String]? = nil, execName: String? = nil, currentDirectory: String? = nil)
     {
        if running {
            return
        }
        
        #if canImport(Subprocess)
        startProcessWithSubprocess(executable: executable, args: args, environment: environment, execName: execName, currentDirectory: currentDirectory)
        #else
        startProcessWithForkpty(executable: executable, args: args, environment: environment, execName: execName, currentDirectory: currentDirectory)
        #endif
    }
    
    #if canImport(Subprocess)
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
            io = DispatchIO(type: .stream, fileDescriptor: master, queue: dispatchQueue, cleanupHandler: { _ in })
            guard let io else {
                return
            }
            io.setLimit(lowWater: 1)
            io.setLimit(highWater: readSize)
            io.read(offset: 0, length: readSize, queue: readQueue, ioHandler: childProcessRead)
            
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
                        environment: .custom(env),
                        workingDirectory: currentDirectory.map { System.FilePath($0) },
                        platformOptions: options,
                        input: .fileDescriptor(slaveFileDescriptor, closeAfterSpawningProcess: true),
                        output: .fileDescriptor(slaveFileDescriptor, closeAfterSpawningProcess: false),
                        error: .fileDescriptor(slaveFileDescriptor, closeAfterSpawningProcess: false)
                    )
                    
                    // Process completed
                    await MainActor.run {
                        self.running = false
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
                        self.running = false  
                        self.delegate?.processTerminated(self, exitCode: nil)
                    }
                    print("Failed to start process with swift-subprocess: \(error)")
                }
            }
            
        } catch {
            running = false
            delegate?.processTerminated(self, exitCode: nil)
            print("Failed to create pseudo-terminal: \(error)")
        }
    }
    #endif
    
    private func startProcessWithForkpty(executable: String, args: [String], environment: [String]?, execName: String?, currentDirectory: String?) {
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
#if os(macOS)
            childMonitor = DispatchSource.makeProcessSource(identifier: shellPid, eventMask: .exit, queue: dispatchQueue)
            if let cm = childMonitor {
                if #available(macOS 10.12, *) {
                    cm.activate()
                } else {
                    // Fallback on earlier versions
                }
                cm.setEventHandler(handler: { [weak self] in self?.processTerminated () })
            }
#endif
            running = true
            self.childfd = childfd
            self.shellPid = shellPid
            io = DispatchIO(type: .stream, fileDescriptor: childfd, queue: dispatchQueue, cleanupHandler: { x in })
            guard let io else {
                return
            }
            io.setLimit(lowWater: 1)
            io.setLimit(highWater: readSize)
            io.read(offset: 0, length: readSize, queue: readQueue, ioHandler: childProcessRead)
        }
    }

    public func terminate()
    {
        #if canImport(Subprocess)
        if let task = subprocessTask {
            task.cancel()
            subprocessTask = nil
        }
        
        // Close file descriptors
        if masterFd != -1 {
            close(masterFd)
            masterFd = -1
        }
        if slaveFd != -1 {
            close(slaveFd)
            slaveFd = -1
        }
        #endif
        
        if shellPid != 0 {
            kill(shellPid, SIGTERM)
        }
        
        running = false
    }
    
    var loggingDir: String? = nil
    
    /**
     * Use this method to toggle the logging of data coming from the host, or pass nil to stop
     * - Parameter directory: location where the log files will be stored.
     */
    public func setHostLogging (directory: String?)
    {
        loggingDir = directory
    }
}
#endif
