#if !os(iOS)
import Foundation
import SwiftTerm
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

fileprivate let debugMessages = false
fileprivate func debugMessage(_ x: String) {
    if debugMessages {
        fputs(x, stderr)
    }
}

class TermcastRecorder {
    private var fileHandle: FileHandle?
    private var startTime: TimeInterval = 0
    private var process: LocalProcess?
    private var initialWindowSize: winsize = winsize()
    private let encoder = JSONEncoder()
    private var timeoutTimer: DispatchSourceTimer?
    private var originalTermios: termios = termios()
    private var originalStdoutTermios: termios = termios()
    private var terminalModeSet = false
    private var stdoutModeSet = false
    private var debugMessages = false
    
    func record(to filePath: String, command: String?, timeout: Double? = nil) throws {
        debugMessage("[DEBUG] Starting recording to \(filePath)\n")
        let url = URL(fileURLWithPath: filePath)
        
        // Create the file and get handle
        FileManager.default.createFile(atPath: filePath, contents: nil)
        fileHandle = try FileHandle(forWritingTo: url)
        debugMessage("[DEBUG] File handle created\n")
        
        // Set up initial window size
        let terminalSize = getTerminalSize()
        initialWindowSize.ws_col = UInt16(terminalSize.width)
        initialWindowSize.ws_row = UInt16(terminalSize.height)
        debugMessage("[DEBUG] Terminal size: \(terminalSize.width)x\(terminalSize.height)\n")
        
        // Record start time
        startTime = Date().timeIntervalSince1970
        debugMessage("[DEBUG] Start time recorded: \(startTime)\n")
        
        // Write header
        try writeHeader(command: command)
        debugMessage("[DEBUG] Header written\n")
        
        // Set up signal handler for window resize
        // setupResizeHandler() // Temporarily disabled for debugging
        
        // Create and start the local process
        let recorder = self
        process = LocalProcess(delegate: recorder)
        debugMessage("[DEBUG] LocalProcess created\n")
        
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/bash"
        let executable = shell
        let args: [String]
        if let command = command {
            args = ["-c", command]
        } else {
            args = ["-l"]
        }
        debugMessage("[DEBUG] Executable: \(executable), Args: \(args)\n")
        process?.startProcess(executable: executable, args: args)
        debugMessage("[DEBUG] Process started\n")
        
        // Set up terminal raw mode and input forwarding
        try setupRawMode()
        try setupStdoutMode()
        setupInputForwarding()
        
        // Set up timeout timer if specified
        if let timeout = timeout {
            setupTimeoutTimer(timeout)
            debugMessage("[DEBUG] Timeout set to \(timeout) seconds\n")
        }
        
        debugMessage("[DEBUG] Entering main run loop\n")
        // Wait for process to finish
        RunLoop.main.run()
    }
    
    private func writeHeader(command: String?) throws {
        let env = ProcessInfo.processInfo.environment
        let header = AsciicastHeader(
            version: 2,
            width: Int(initialWindowSize.ws_col),
            height: Int(initialWindowSize.ws_row),
            timestamp: startTime,
            command: command,
            title: nil,
            env: [
                "SHELL": env["SHELL"] ?? "/bin/bash",
                "TERM": env["TERM"] ?? "xterm-256color"
            ]
        )
        
        let headerData = try encoder.encode(header)
        let headerLine = String(data: headerData, encoding: .utf8)! + "\n"
        fileHandle?.write(headerLine.data(using: .utf8)!)
    }
    
    private func writeEvent(_ event: AsciicastEvent) {
        do {
            let eventData = try encoder.encode(event)
            let eventLine = String(data: eventData, encoding: .utf8)! + "\n"
            fileHandle?.write(eventLine.data(using: .utf8)!)
        } catch {
            print("Error writing event: \(error)")
        }
    }
    
    private func getTerminalSize() -> (width: Int, height: Int) {
        var w = winsize()
#if os(macOS)
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
            return (width: Int(w.ws_col), height: Int(w.ws_row))
        }
#else
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w) == 0 {
            return (width: Int(w.ws_col), height: Int(w.ws_row))
        }
#endif
        return (width: 80, height: 24) // Default size
    }
    
    private func setupResizeHandler() {
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        source.setEventHandler { [weak self] in
            let newSize = self?.getTerminalSize() ?? (width: 80, height: 24)
            let currentTime = Date().timeIntervalSince1970 - (self?.startTime ?? 0)
            let resizeData = "\(newSize.width)x\(newSize.height)"
            let event = AsciicastEvent(time: currentTime, eventType: .resize, eventData: resizeData)
            self?.writeEvent(event)
            
            // Update the process window size
            var newWinsize = winsize()
            newWinsize.ws_col = UInt16(newSize.width)
            newWinsize.ws_row = UInt16(newSize.height)
            if let masterFd = self?.process?.childfd {
                _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: masterFd, windowSize: &newWinsize)
            }
        }
        signal(SIGWINCH, SIG_IGN)
        source.activate()
    }
    
    private func setupRawMode() throws {
        debugMessage("[DEBUG] Setting up raw mode for stdin\n")
        
        // Debug stdin state
        debugMessage("[DEBUG] STDIN_FILENO = \(STDIN_FILENO)\n")
        debugMessage("[DEBUG] isatty(STDIN_FILENO) = \(isatty(STDIN_FILENO))\n")
        
        let flags = fcntl(STDIN_FILENO, F_GETFL)
        debugMessage("[DEBUG] stdin fcntl flags = \(flags)\n")
        
        // Save original terminal settings
        if tcgetattr(STDIN_FILENO, &originalTermios) != 0 {
            let error = errno
            debugMessage("[DEBUG] tcgetattr failed with errno: \(error)\n")
            throw NSError(domain: "TermcastError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to get terminal attributes"])
        }
        debugMessage("[DEBUG] Original terminal settings saved\n")
        
        // Create raw mode settings
        var rawTermios = originalTermios
#if os(macOS)
        rawTermios.c_lflag &= ~(UInt(ECHO | ICANON | ISIG | IEXTEN))
        rawTermios.c_iflag &= ~(UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP))
        rawTermios.c_oflag &= ~(UInt(OPOST))
        rawTermios.c_cflag |= UInt(CS8)
#else
        rawTermios.c_lflag &= ~(UInt32(ECHO | ICANON | ISIG | IEXTEN))
        rawTermios.c_iflag &= ~(UInt32(IXON | ICRNL | BRKINT | INPCK | ISTRIP))
        rawTermios.c_oflag &= ~(UInt32(OPOST))
        rawTermios.c_cflag |= UInt32(CS8)
#endif
        rawTermios.c_cc.16 = 1  // VMIN
        rawTermios.c_cc.17 = 0  // VTIME
        
        // Apply raw mode settings
        if tcsetattr(STDIN_FILENO, TCSAFLUSH, &rawTermios) != 0 {
            let error = errno
            debugMessage("[DEBUG] tcsetattr failed with errno: \(error)\n")
            throw NSError(domain: "TermcastError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to set raw mode"])
        }
        
        // Verify raw mode was set
        var verifyTermios = termios()
        if tcgetattr(STDIN_FILENO, &verifyTermios) == 0 {
            debugMessage("[DEBUG] Verified c_lflag after raw mode: \(verifyTermios.c_lflag)\n")
        }
        
        terminalModeSet = true
        debugMessage("[DEBUG] Raw mode set successfully\n")
    }
    
    private func setupStdoutMode() throws {
        debugMessage("[DEBUG] Setting up stdout mode to mirror pty\n")
        
        // Save original stdout settings
        if tcgetattr(STDOUT_FILENO, &originalStdoutTermios) != 0 {
            debugMessage("[DEBUG] Warning: Failed to get stdout terminal attributes\n")
            return
        }
        
        // Wait a moment for the process to be fully started
        usleep(100000) // 100ms
        
        // Get the pty file descriptor from the process
        guard let masterFd = process?.childfd else {
            debugMessage("[DEBUG] Warning: Could not get master pty fd\n")
            return
        }
        
        // Get terminal settings from the pty
        var ptyTermios = termios()
        if tcgetattr(masterFd, &ptyTermios) != 0 {
            debugMessage("[DEBUG] Warning: Failed to get pty terminal attributes\n")
            return
        }
        
        debugMessage("[DEBUG] Got pty terminal settings, c_oflag = \(ptyTermios.c_oflag)\n")
        
        // Apply pty output settings to stdout
        var newStdoutTermios = originalStdoutTermios
        newStdoutTermios.c_oflag = ptyTermios.c_oflag  // Copy output processing flags
        
        if tcsetattr(STDOUT_FILENO, TCSANOW, &newStdoutTermios) != 0 {
            debugMessage("[DEBUG] Warning: Failed to set stdout terminal attributes\n")
            return
        }
        
        stdoutModeSet = true
        debugMessage("[DEBUG] Stdout mode set to mirror pty successfully\n")
    }
    
    private func setupInputForwarding() {
        // Read from stdin and forward to process using blocking read in background thread
        debugMessage("[DEBUG] Setting up input forwarding...\n")
        debugMessage("[DEBUG] Testing stdin readability...\n")
        
        let testFlags = fcntl(STDIN_FILENO, F_GETFL)
        debugMessage("[DEBUG] Initial stdin flags: \(testFlags)\n")
        
        DispatchQueue.global().async { [weak self] in
            debugMessage("[DEBUG] Input forwarding thread started (NEW VERSION)\n")
            
            var loopCount = 0
            while true {
                loopCount += 1
                if loopCount % 1000 == 0 {
                    debugMessage("[DEBUG] Input loop iteration \(loopCount)\n")
                }
                
                // Use blocking read with a timeout by setting stdin to non-blocking temporarily
                let originalFlags = fcntl(STDIN_FILENO, F_GETFL)
                _ = fcntl(STDIN_FILENO, F_SETFL, originalFlags | O_NONBLOCK)
                
                var buffer = [UInt8](repeating: 0, count: 1)
                let bytesRead = read(STDIN_FILENO, &buffer, buffer.count)
                
                // Restore blocking mode
                _ = fcntl(STDIN_FILENO, F_SETFL, originalFlags)
                
                if bytesRead > 0 {
                    debugMessage("[DEBUG] Read \(bytesRead) bytes from stdin\n")
                    let data = Array(buffer[0..<bytesRead])
                    let inputString = String(bytes: data, encoding: .utf8) ?? ""
                    debugMessage("[DEBUG] Input received: \(inputString.debugDescription) (byte: \(data[0]))\n")
                    
                    // Send to process
                    self?.process?.send(data: data[...])
                    debugMessage("[DEBUG] Sent \(data.count) bytes to process\n")
                    
                    // Record input event
                    let currentTime = Date().timeIntervalSince1970 - (self?.startTime ?? 0)
                    let event = AsciicastEvent(time: currentTime, eventType: .input, eventData: inputString)
                    self?.writeEvent(event)
                    debugMessage("[DEBUG] Recorded input event\n")
                } else if bytesRead == -1 {
                    let error = errno
                    if error == EAGAIN || error == EWOULDBLOCK {
                        // No data available, sleep briefly
                        usleep(10000) // 10ms
                        continue
                    } else {
                        debugMessage("[DEBUG] Read error: \(error)\n")
                        break
                    }
                } else {
                    // EOF
                    debugMessage("[DEBUG] EOF on stdin\n")
                    break
                }
            }
            debugMessage("[DEBUG] Input forwarding thread ended\n")
        }
    }
    
    private func setupTimeoutTimer(_ timeout: Double) {
        timeoutTimer = DispatchSource.makeTimerSource(queue: .main)
        timeoutTimer?.schedule(deadline: .now() + timeout, repeating: .never)
        timeoutTimer?.setEventHandler { [weak self] in
            debugMessage("\nRecording timeout reached. Terminating...\n")
            self?.terminateRecording()
        }
        timeoutTimer?.activate()
    }
    
    private func terminateRecording() {
        debugMessage("[DEBUG] Terminating recording...\n")
        restoreTerminalMode()
        process?.terminate()
        fileHandle?.closeFile()
        timeoutTimer?.cancel()
        exit(0)
    }
    
    private func restoreTerminalMode() {
        if terminalModeSet {
            debugMessage("[DEBUG] Restoring original stdin terminal mode\n")
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
            terminalModeSet = false
        }
        if stdoutModeSet {
            debugMessage("[DEBUG] Restoring original stdout terminal mode\n")
            tcsetattr(STDOUT_FILENO, TCSAFLUSH, &originalStdoutTermios)
            stdoutModeSet = false
        }
    }
}

extension TermcastRecorder: LocalProcessDelegate {
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        debugMessage("[DEBUG] Process terminated with exit code: \(exitCode ?? -1)\n")
        restoreTerminalMode()
        timeoutTimer?.cancel()
        fileHandle?.closeFile()
        exit(exitCode ?? 0)
    }
    
    func dataReceived(slice: ArraySlice<UInt8>) {
        let currentTime = Date().timeIntervalSince1970 - startTime
        let outputString = String(bytes: slice, encoding: .utf8) ?? ""
        debugMessage("[DEBUG] Output received: \(outputString.debugDescription)\n")
        let event = AsciicastEvent(time: currentTime, eventType: .output, eventData: outputString)
        writeEvent(event)
        
        // Also write to stdout for live display
        print(outputString, terminator: "")
        fflush(stdout)
    }
    
    func getWindowSize() -> winsize {
        return initialWindowSize
    }
}
#endif
