//
//  main.swift
//  WindowsTerminalApp
//
//  Simple Windows console application demonstrating SwiftTerm integration
//  This serves as a basic example and foundation for more complex Windows
//  terminal applications.
//
//  Created for Windows port - Issue #136
//

#if os(Windows)
import Foundation
import SwiftTerm

/**
 * Simple Windows console application that demonstrates SwiftTerm usage
 * This is a minimal implementation that runs in a Windows console window
 * and provides basic terminal functionality.
 */
class SimpleWindowsTerminalApp {
    
    private let terminalApp: WindowsTerminalApplication
    private var running = true
    
    init() {
        // Configure the terminal application
        var config = WindowsTerminalConfiguration()
        config.terminalOptions.cols = 80
        config.terminalOptions.rows = 24
        config.autoStartProcess = false // We'll handle input manually for this demo
        
        self.terminalApp = WindowsTerminalApplication(configuration: config)
    }
    
    func run() {
        print("SwiftTerm Windows Console Demo")
        print("==============================")
        print("This is a simple demonstration of SwiftTerm on Windows")
        print("Type 'quit' to exit")
        print("")
        
        // Start the terminal application
        terminalApp.start()
        
        // Simple input loop for demonstration
        while running {
            print("> ", terminator: "")
            
            if let input = readLine() {
                if input.lowercased() == "quit" {
                    running = false
                    break
                }
                
                // Process the input through the terminal
                processInput(input)
            }
        }
        
        // Cleanup
        terminalApp.stop()
        print("Application terminated.")
    }
    
    private func processInput(_ input: String) {
        // Send input to terminal for processing
        terminalApp.handleKeyboardInput(input + "\r\n")
        
        // For demonstration, echo back some information about the terminal state
        let buffer = terminalApp.getTerminalContent()
        let cursor = terminalApp.terminalView.getCursorPosition()
        let size = terminalApp.terminalView.getSize()
        
        print("Terminal state:")
        print("  Input: '\(input)'")
        print("  Cursor: (\(cursor.x), \(cursor.y))")
        print("  Size: \(size.cols)x\(size.rows)")
        print("  Buffer lines: \(buffer.lines.count)")
        print("")
    }
}

// Main entry point for Windows
@main
struct WindowsTerminalMain {
    static func main() {
        let app = SimpleWindowsTerminalApp()
        app.run()
    }
}

#else

// Placeholder for non-Windows platforms
@main
struct WindowsTerminalMain {
    static func main() {
        print("WindowsTerminalApp is only available on Windows platform")
        exit(1)
    }
}

#endif