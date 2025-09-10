//
//  WindowsTerminalApplication.swift
//  SwiftTerm
//
//  Windows application framework for SwiftTerm
//  This provides the foundation for creating Windows terminal applications
//  using various UI frameworks (Win32, UWP, WinUI, etc.)
//
//  Created for Windows port - Issue #136
//

#if os(Windows)
import Foundation

/**
 * WindowsTerminalApplication serves as the main application class for
 * Windows-based SwiftTerm applications. It provides the foundation for
 * integrating with various Windows UI frameworks.
 */
public class WindowsTerminalApplication {
    
    /// The main terminal view
    public private(set) var terminalView: WindowsTerminalView
    
    /// Process manager for running local processes
    public private(set) var processManager: WindowsProcess?
    
    /// Application configuration
    private let configuration: WindowsTerminalConfiguration
    
    /**
     * Initializes a new Windows terminal application
     * - Parameter configuration: Application configuration options
     */
    public init(configuration: WindowsTerminalConfiguration = WindowsTerminalConfiguration()) {
        self.configuration = configuration
        self.terminalView = WindowsTerminalView(options: configuration.terminalOptions)
    }
    
    /**
     * Starts the terminal application
     */
    public func start() {
        print("Starting SwiftTerm Windows Application")
        print("Configuration: \(configuration)")
        
        // TODO: Initialize Windows-specific UI framework
        // This might involve:
        // - Setting up Win32 window
        // - Initializing UWP/WinUI components
        // - Creating rendering context
        
        // Start a default process if configured
        if configuration.autoStartProcess {
            startDefaultProcess()
        }
    }
    
    /**
     * Stops the terminal application
     */
    public func stop() {
        print("Stopping SwiftTerm Windows Application")
        
        // Terminate any running process
        processManager?.terminate()
        processManager = nil
        
        // TODO: Cleanup Windows-specific resources
    }
    
    /**
     * Starts the default shell process
     */
    public func startDefaultProcess() {
        let executable = configuration.defaultShell ?? WindowsProcessUtilities.getDefaultShell()
        
        processManager = WindowsProcess(delegate: self)
        processManager?.startProcess(
            executable: executable,
            args: configuration.shellArgs,
            environment: configuration.environment,
            workingDirectory: configuration.workingDirectory
        )
    }
    
    /**
     * Handles keyboard input from the UI
     * - Parameter input: The keyboard input data
     */
    public func handleKeyboardInput(_ input: String) {
        if let data = input.data(using: .utf8) {
            if let process = processManager {
                process.send(data: data[...])
            } else {
                // Send to terminal for processing escape sequences, etc.
                terminalView.send(data: data[...])
            }
        }
    }
    
    /**
     * Gets the current terminal content for rendering
     * - Returns: Terminal buffer for rendering
     */
    public func getTerminalContent() -> Buffer {
        return terminalView.getBuffer()
    }
}

// MARK: - WindowsProcessDelegate

extension WindowsTerminalApplication: WindowsProcessDelegate {
    
    public func processTerminated(_ source: WindowsProcess, exitCode: Int32?) {
        print("Process terminated with exit code: \(exitCode ?? -1)")
        processManager = nil
        
        // TODO: Handle process termination
        // - Show termination message
        // - Offer to restart process
        // - Close application if configured
    }
    
    public func dataReceived(slice: ArraySlice<UInt8>) {
        // Feed process output to the terminal for processing
        terminalView.feed(data: slice)
    }
    
    public func getWindowSize() -> (rows: Int, cols: Int, xpixel: Int, ypixel: Int) {
        let size = terminalView.getSize()
        return (rows: size.rows, cols: size.cols, xpixel: 0, ypixel: 0)
    }
}

// MARK: - Configuration

/**
 * Configuration options for Windows terminal applications
 */
public struct WindowsTerminalConfiguration {
    
    /// Terminal options (dimensions, scrollback, etc.)
    public var terminalOptions: TerminalOptions
    
    /// Default shell to launch
    public var defaultShell: String?
    
    /// Arguments to pass to the shell
    public var shellArgs: [String]
    
    /// Environment variables for the shell
    public var environment: [String: String]?
    
    /// Working directory for the shell
    public var workingDirectory: String?
    
    /// Whether to automatically start a process on launch
    public var autoStartProcess: Bool
    
    /// UI Framework to use (for future extensibility)
    public var uiFramework: WindowsUIFramework
    
    public init(
        terminalOptions: TerminalOptions = TerminalOptions(),
        defaultShell: String? = nil,
        shellArgs: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        autoStartProcess: Bool = true,
        uiFramework: WindowsUIFramework = .win32
    ) {
        self.terminalOptions = terminalOptions
        self.defaultShell = defaultShell
        self.shellArgs = shellArgs
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.autoStartProcess = autoStartProcess
        self.uiFramework = uiFramework
    }
}

/**
 * Supported Windows UI frameworks
 */
public enum WindowsUIFramework {
    case win32      // Traditional Win32 API
    case uwp        // Universal Windows Platform
    case winui      // WinUI 3
    case wpf        // Windows Presentation Foundation (if supported by Swift)
}

extension WindowsTerminalConfiguration: CustomStringConvertible {
    public var description: String {
        return """
        WindowsTerminalConfiguration(
          terminalOptions: \(terminalOptions.cols)x\(terminalOptions.rows),
          defaultShell: \(defaultShell ?? "default"),
          autoStartProcess: \(autoStartProcess),
          uiFramework: \(uiFramework)
        )
        """
    }
}

#endif