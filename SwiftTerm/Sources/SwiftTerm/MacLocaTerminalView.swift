//
//  MacLocalTerminalView.swift
//
//
//  Created by Miguel de Icaza on 3/6/20.
//

#if os(OSX)
import Foundation

public protocol LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int)

    func setTerminalTitle(source: LocalProcessTerminalView, title: String)

    /**
     * Only valid `LocalProcessTerminalView`
     */
    func processTerminated (source: TerminalView)
}


/**
 * `LocalProcessTerminalView` is an AppKit NSView that can be used to host a local process
 * the process is launched inside a pseudo-terminal.
 *
 * Call the `startProcess` to launch the underlying process inside a pseudo terminal.
 *
 * Note: instances of `LocalProcessTerminalView` will set the `TerminalView`'s `delegate`
 * property and capture and consume the messages.   The messages that are most likely needed for
 * consumer applications are reposted to the `LocalProcessTerminalViewDelegate` in
 * `processDelegate`.   If you override the `delegate` directly, you might inadvertently break
 * the internal working of `LocalProcessTerminalView`.   If you must change the `delegate`
 * make sure that you proxy the values in your implementation to the values set after initializing this instance
 */
public class LocalProcessTerminalView: TerminalView, TerminalViewDelegate {
    var readBuffer: [UInt8] = Array.init (repeating: 0, count: 8192)
    var childfd: Int32 = -1
    var shellPid: pid_t = 0
    
    public override init (frame: CGRect)
    {
        super.init (frame: frame)
        setup (rect: frame)
    }
    
    public required init? (coder: NSCoder)
    {
        super.init (coder: coder)
        setup (rect: self.bounds)
    }

    func setup ()
    {
        delegate = self
    }
    
    /**
     * The `processDelegate` is used to deliver messages and information relevant t
     */
    public var processDelegate: LocalProcessTerminalViewDelegate?
    
    /**
     * This method is invoked to notify the client of the new columsn and rows that have been set by the UI
     */
    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard running else {
            return
        }
        var size = getWindowSize()
        let _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: childfd, windowSize: &size)
        
        processDelegate?.sizeChanged (source: self, newCols: newCols, newRows: newRows)
    }
    
    /**
     * Invoke this method to notify the processDelegate of the new title for the terminal window
     */
    public func setTerminalTitle(source: TerminalView, title: String) {
        processDelegate?.setTerminalTitle (source: self, title: title)
    }

    /**
     * This method is invoked when input from the user needs to be sent to the client
     */
    public func send(source: TerminalView, data: ArraySlice<UInt8>) 
    {
        guard running else {
            return
        }
        data.withUnsafeBytes { ptr in
            let ddata = DispatchData(bytes: ptr)
            DispatchIO.write(toFileDescriptor: childfd, data: ddata, runningHandlerOn: DispatchQueue.main, handler: childProcessWrite)
        }
    }
    
    // Just a debugging aid
    var x = 0
    func childProcessRead (data: DispatchData, errno: Int32)
    {
        if data.count == 0 {
            childfd = -1
            running = false
            processDelegate?.processTerminated(source: self)
            return
        }
        var b: [UInt8] = Array.init(repeating: 0, count: data.count)
        print ("Got: \(b.count)")
        b.withUnsafeMutableBufferPointer({ ptr in
            let _ = data.copyBytes(to: ptr)
            print ("data count is: \(data.count)")
            do {
                let dataCopy = Data (ptr)
                try dataCopy.write(to: URL.init(fileURLWithPath: "/tmp/log-\(x)"))
                x += 1
            } catch {
                // Ignore write error
                print ("Got error: \(error)")
            }
        })
        feed (byteArray: b[...])
        
        DispatchIO.read(fromFileDescriptor: childfd, maxLength: readBuffer.count, runningHandlerOn: DispatchQueue.main, handler: childProcessRead)
    }
    
    public func scrolled(source: TerminalView, position: Double) {
        // noting
    }
    

    func childProcessWrite (dispatchData: DispatchData?, errno: Int32)
    {
        if errno != 0 {
            print ("Error writing to the child")
        }
    }
    
    func getWindowSize () -> winsize
    {
        let f: CGRect = self.frame
        return winsize(ws_row: UInt16(terminal.rows), ws_col: UInt16(terminal.cols), ws_xpixel: UInt16 (f.width), ws_ypixel: UInt16 (f.height))
    }
    
    var running: Bool = false
    /**
     * Launches a child process inside a pseudo-terminal
     * - Parameter executable: The executable to launch inside the pseudo terminal, defaults to /bin/bash
     * - Parameter args: an array of strings that is passed as the arguments to the underlying process
     * - Parameter environment: an array of environment variables to pass to the child process.
     */
    public func startProcess(executable: String = "/bin/bash", args: [String] = [], environment: [String] = [])
     {
        if running {
            return
        }
        var size = getWindowSize ()
    
        var shellArgs = args
        shellArgs.insert(executable, at: 0)
        if let (shellPid, childfd) = PseudoTerminalHelpers.fork(andExec: executable, args: shellArgs, env: environment, desiredWindowSize: &size) {
            running = true
            self.childfd = childfd
            self.shellPid = shellPid
            DispatchIO.read(fromFileDescriptor: childfd, maxLength: readBuffer.count, runningHandlerOn: DispatchQueue.main, handler: childProcessRead)
        }
    }
}

#endif
