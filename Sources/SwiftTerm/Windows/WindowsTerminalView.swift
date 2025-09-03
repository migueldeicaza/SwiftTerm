//
//  WindowsTerminalView.swift
//  SwiftTerm
//
//  Windows-specific terminal view implementation
//  This provides the foundation for Windows UI integration
//
//  Created for Windows port - Issue #136
//

#if os(Windows)
import Foundation

/**
 * WindowsTerminalView provides a Windows-specific implementation for rendering
 * terminal content and handling user input. This is the foundation for integrating
 * SwiftTerm with Windows UI frameworks such as Win32, UWP, or WinUI.
 *
 * This class serves as the bridge between the platform-agnostic Terminal engine
 * and the Windows-specific rendering and input handling systems.
 */
public class WindowsTerminalView {
    
    /// The underlying terminal engine that handles escape sequences and terminal state
    public private(set) var terminal: Terminal
    
    /// Terminal options containing configuration like dimensions and scrollback
    private let options: TerminalOptions
    
    /**
     * Initializes a new Windows terminal view with the specified options
     * - Parameter options: Terminal configuration options
     */
    public init(options: TerminalOptions = TerminalOptions()) {
        self.options = options
        self.terminal = Terminal(
            delegate: nil, // Will be set by the UI framework integration
            options: options
        )
    }
    
    /**
     * Resizes the terminal to the specified dimensions
     * - Parameter cols: Number of columns
     * - Parameter rows: Number of rows
     */
    public func resize(cols: Int, rows: Int) {
        terminal.resize(cols: cols, rows: rows)
    }
    
    /**
     * Sends input data to the terminal (typically from keyboard input)
     * - Parameter data: The input data to send to the terminal
     */
    public func send(data: ArraySlice<UInt8>) {
        terminal.send(data: data)
    }
    
    /**
     * Feeds output data to the terminal for processing (typically from a process)
     * - Parameter data: The output data to process
     */
    public func feed(data: ArraySlice<UInt8>) {
        terminal.feed(data: data)
    }
    
    /**
     * Gets the current buffer contents for rendering
     * - Returns: The current terminal buffer
     */
    public func getBuffer() -> Buffer {
        return terminal.buffer
    }
    
    /**
     * Gets the current cursor position
     * - Returns: The cursor position as (x, y) coordinates
     */
    public func getCursorPosition() -> (x: Int, y: Int) {
        return (x: terminal.buffer.x, y: terminal.buffer.y)
    }
    
    /**
     * Gets the terminal dimensions
     * - Returns: The terminal dimensions as (cols, rows)
     */
    public func getSize() -> (cols: Int, rows: Int) {
        return (cols: terminal.cols, rows: terminal.rows)
    }
}

/**
 * Protocol for Windows-specific terminal delegates that handle rendering and input
 */
public protocol WindowsTerminalDelegate: AnyObject {
    
    /**
     * Called when the terminal content needs to be refreshed
     * - Parameter startRow: The starting row that needs refresh
     * - Parameter endRow: The ending row that needs refresh
     */
    func refresh(startRow: Int, endRow: Int)
    
    /**
     * Called when the terminal is resized
     * - Parameter cols: New number of columns
     * - Parameter rows: New number of rows
     */
    func sizeChanged(cols: Int, rows: Int)
    
    /**
     * Called when the cursor position changes
     * - Parameter x: New cursor X position
     * - Parameter y: New cursor Y position
     */
    func cursorMoved(x: Int, y: Int)
}

#endif