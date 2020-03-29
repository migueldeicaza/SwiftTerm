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
 * Generally, for the `LocalProcessTerminalView` to be useful, you will want to disable the sandbox
 * for your application, otherwise the underlying shell will not have access to much - not the majority of
 * commands, not assorted places on the file systems and so on.   For this, you need to disable for your
 * target in "Signing and Capabilities" the sandbox entirely.
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
    var debugIO = false
    
    public override init (frame: CGRect)
    {
        super.init (frame: frame)
        setup ()
    }
    
    public required init? (coder: NSCoder)
    {
        super.init (coder: coder)
        setup ()
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
    var count = 0
    var total = 0
    public func send(source: TerminalView, data: ArraySlice<UInt8>) 
    {
        guard running else {
            return
        }
        var copy = count
        count += 1
        data.withUnsafeBytes { ptr in
            let ddata = DispatchData(bytes: ptr)
            if debugIO {
                print ("[SEND-\(copy)] Queuing data to client: \(data) ")
            }

            //DispatchIO.write(toFileDescriptor: childfd, data: ddata, runningHandlerOn: DispatchQueue.main, handler: childProcessWrite)
            DispatchIO.write(toFileDescriptor: childfd, data: ddata, runningHandlerOn: DispatchQueue.global(), handler:  { dd, errno in
                self.total += copy
                if self.debugIO {
                    print ("[SEND-\(copy)] completed bytes=\(self.total)")
                }
                if errno != 0 {
                    print ("Error writing data to the child")
                }
            })
        }
    }
    
    
    var x = 0   // Just a debugging aid
    var totalRead = 0
    func childProcessRead (data: DispatchData, errno: Int32)
    {
        if debugIO {
            totalRead += data.count
            print ("[READ] count=\(data.count) received from host total=\(totalRead)")
        }
        
        if data.count == 0 {
            childfd = -1
            running = false
            processDelegate?.processTerminated(source: self)
            return
        }
        var b: [UInt8] = Array.init(repeating: 0, count: data.count)
        b.withUnsafeMutableBufferPointer({ ptr in
            let _ = data.copyBytes(to: ptr)
            #if false
            do {
                let dataCopy = Data (ptr)
                try dataCopy.write(to: URL.init(fileURLWithPath: "/Users/miguel/Downloads/Logs/log-\(x)"))
                x += 1
            } catch {
                // Ignore write error
                print ("Got error while logging data dump to /tmp/log-\(x): \(error)")
            }
            #endif
        })
        feed (byteArray: b[...])
        //print ("All data processed \(data.count)")
        DispatchIO.read(fromFileDescriptor: childfd, maxLength: readBuffer.count, runningHandlerOn: DispatchQueue.main, handler: childProcessRead)
    }
    
    public func scrolled(source: TerminalView, position: Double) {
        // noting
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
     * - Parameter environment: an array of environment variables to pass to the child process, if this is null, this picks a good set of defaults from `Terminal.getEnvironmentVariables`.
     */
    public func startProcess(executable: String = "/bin/bash", args: [String] = [], environment: [String]? = nil)
     {
        if running {
            return
        }
        var size = getWindowSize ()
    
        var shellArgs = args
        shellArgs.insert(executable, at: 0)
        
        var env: [String]
        if environment == nil {
            env = Terminal.getEnvironmentVariables(termName: "xterm-color")
        } else {
            env = environment!
        }
        
        if let (shellPid, childfd) = PseudoTerminalHelpers.fork(andExec: executable, args: shellArgs, env: env, desiredWindowSize: &size) {
            running = true
            self.childfd = childfd
            self.shellPid = shellPid
            DispatchIO.read(fromFileDescriptor: childfd, maxLength: readBuffer.count, runningHandlerOn: DispatchQueue.main, handler: childProcessRead)
        }
    }
}

#endif
