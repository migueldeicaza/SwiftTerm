//
//  HeadlessTerminal.swift
//  
//
//  Created by Miguel de Icaza on 4/5/20.
//
#if !os(iOS) && !os(Windows)
import Foundation

///
/// A `HeadlessTerminal` provides a terminal emulator that runs a local process, but the output does not go
/// anywhere.   You can use this to script applications and screen scrape the output for example, by accessing the
/// `terminal` from this class.
///
public class HeadlessTerminal : TerminalDelegate, LocalProcessDelegate {
    public private(set) var terminal: Terminal!
    public var process: LocalProcess!
    var onEnd: (_ exitCode: Int32?) -> ()
    var dir: String?
    private let queue: DispatchQueue?
    private let directDelivery: Bool

    /// Creates a headless terminal.
    ///
    /// Set `directDelivery` to `true` to use the same PTY delivery model as
    /// `LocalProcessTerminalView`: the IO pipeline parses each batch inline on
    /// its parse thread. The queue still receives process lifecycle callbacks.
    public init (
        queue: DispatchQueue? = nil,
        options: TerminalOptions = TerminalOptions.default,
        directDelivery: Bool = false,
        onEnd: @escaping (_ exitCode: Int32?) -> ()
    )
    {
        self.onEnd = onEnd
        self.queue = queue
        self.directDelivery = directDelivery
        terminal = ManagedFeedTerminal(delegate: self, options: options)
        process = LocalProcess(
            delegate: self,
            dispatchQueue: queue,
            directDelivery: directDelivery)
    }
    
    public func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        onEnd (exitCode)
    }
    
    public func dataReceived(slice: ArraySlice<UInt8>) {
        //print (String (bytes: slice, encoding: .utf8))
        terminal.terminalLock.withLock {
            terminal.withManagedFeed {
                terminal.feed(buffer: slice)
            }
        }
    }
    
    public func send(data: ArraySlice<UInt8>) {
        // Run the OSC 133 submission heuristic even for headless terminals: a
        // host that forwards pointer events to Terminal.handleSemanticPromptClick
        // (server-side / web embeddings) would otherwise inject clicks into a
        // running program because the buffer never leaves `armed`. The scanner
        // state is scalar and must not race `feed`. Direct delivery uses the
        // terminal lock, as TerminalView does. Queued delivery uses the
        // effective process queue and the same lock.
        let bytes = Array(data)
        if directDelivery {
            precondition(!terminal.terminalLock.isLockedByCurrentThread,
                         "HeadlessTerminal.send(data:) must not run inside a terminal callback")
            terminal.terminalLock.withLock {
                terminal.registerUserInput(bytes[...])
            }
            process.send(data: data)
            return
        }
        (queue ?? DispatchQueue.main).async { [weak self] in
            guard let terminal = self?.terminal else { return }
            terminal.terminalLock.withLock {
                terminal.registerUserInput(bytes[...])
            }
        }
        process.send(data: data)
    }

    public func send(_ text: String) {
        send (data: ([UInt8] (text.utf8))[...])
        
    }

    /// Changes scrollback size for the underlying terminal at runtime.
    /// - Parameter newScrollback: The new scrollback size in lines. Pass `nil` to disable scrollback.
    public func changeScrollback (_ newScrollback: Int?)
    {
        terminal.changeScrollback(newScrollback)
    }

    public func send(source: Terminal, data: ArraySlice<UInt8>) {
        process.send(data: data)
    }
    

    public func getWindowSize() -> winsize {
        return winsize(ws_row: UInt16(terminal.rows), ws_col: UInt16(terminal.cols), ws_xpixel: UInt16 (16), ws_ypixel: UInt16 (16))
    }
    
    public func mouseModeChanged(source: Terminal) {
    }

    public func hostCurrentDirectoryUpdated(source: Terminal) {
        dir = source.hostCurrentDirectory
    }
    public func colorChanged(source: Terminal, idx: Int) {
    }
    
    public var images: [([UInt8], Int, Int)] = []
    
    public func createImageFromBitmap (source: Terminal, bytes: inout [UInt8], width: Int, height: Int)  {
        images.append((bytes, width, height))
    }
}

#endif
