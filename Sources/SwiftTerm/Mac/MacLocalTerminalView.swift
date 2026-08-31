//
//  MacLocalTerminalView.swift
//
//
//  Created by Miguel de Icaza on 3/6/20.
//

#if os(macOS)
import Foundation
import AppKit

private struct WeakLocalProcessInputReference {
    weak var value: LocalProcess?
}

/// Receives an owned process-output batch instead of automatic parsing.
public typealias ProcessOutputConsumer = @MainActor @Sendable ([UInt8]) -> Void

public enum ProcessOutputConsumerError: Error {
    /// Output ownership cannot change while a process is running or draining.
    case processActive
}

/// LocalProcess calls its adapter either on its parse worker or its explicitly
/// configured main queue. Do not hold terminal, render, or process locks here.
private func deliverProcessCallbackOnMain(
    _ body: @MainActor @Sendable () -> Void
) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        DispatchQueue.main.sync { body() }
    }
}

/// Delegate for the ``LocalProcessTerminalView`` class that is used to
/// notify the user of process-related changes.
@MainActor
public protocol LocalProcessTerminalViewDelegate: AnyObject {
    /**
     * This method is invoked to notify that the terminal has been resized to the specified number of columns and rows
     * the user interface code might try to adjut the containing scroll view, or if it is a toplevel window, the window itself
     * - Parameter source: the sending instance
     * - Parameter newCols: the new number of columns that should be shown
     * - Parameter newRow: the new number of rows that should be shown
     */
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int)

    /**
     * This method is invoked when the title of the terminal window should be updated to the provided title
     * - Parameter source: the sending instance
     * - Parameter title: the desired title
     */
    func setTerminalTitle(source: LocalProcessTerminalView, title: String)

    /**
     * Invoked when the OSC command 7 for "current directory has changed" command is sent
     * - Parameter source: the sending instance
     * - Parameter directory: the new working directory
     */
    func hostCurrentDirectoryUpdate (source: TerminalView, directory: String?)

    /**
     * This method is invoked when the child process started by `startProcess` has terminated.
     * Use a serial `dispatchQueue` so data and termination callbacks stay ordered.
     * - Parameter source: the local process that terminated
     * - Parameter exitCode: the normalized exit status from 0 through 255, or nil when the process ended because of a signal or the wait failed
     */
    func processTerminated (source: TerminalView, exitCode: Int32?)
}

private final class LocalProcessTerminalViewProcessAdapter:
    LocalProcessDelegate, LocalProcessBorrowedDataDelegate, Sendable
{
    private let renderOwner: TerminalRenderOwner
    private let frameSignal: FrameDriverSignal
    private let diagnosticsState: Locked<TerminalView.Diagnostics>
    private let outputHandler: LockedVoidCallback
    private let outputConsumer = Locked<ProcessOutputConsumer?>(nil)
    private let windowSize = Locked(winsize())
    private let inputProcess = Locked(WeakLocalProcessInputReference())
    private let terminationHandler: @MainActor @Sendable (Int32?) -> Void

    init(renderOwner: TerminalRenderOwner,
         frameSignal: FrameDriverSignal,
         diagnosticsState: Locked<TerminalView.Diagnostics>,
         outputHandler: LockedVoidCallback,
         terminationHandler: @escaping @MainActor @Sendable (Int32?) -> Void) {
        self.renderOwner = renderOwner
        self.frameSignal = frameSignal
        self.diagnosticsState = diagnosticsState
        self.outputHandler = outputHandler
        self.terminationHandler = terminationHandler
    }

    func updateWindowSize(_ value: winsize) {
        windowSize.withLock { $0 = value }
    }

    func attachInputProcess(_ process: LocalProcess) {
        inputProcess.withLock { $0.value = process }
    }

    func sendInput(_ bytes: [UInt8]) {
        inputProcess.withLock { reference in
            reference.value?.send(data: bytes[...])
        }
    }

    @MainActor
    func setOutputConsumer(_ consumer: ProcessOutputConsumer?) {
        outputConsumer.withLock { $0 = consumer }
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        let handler = terminationHandler
        deliverProcessCallbackOnMain { handler(exitCode) }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        if let consumer = outputConsumer.withLock({ $0 }) {
            let bytes = Array(slice)
            deliverProcessCallbackOnMain { consumer(bytes) }
            outputHandler.call()
            return
        }
        frameSignal.markDirty()
        let parse = Profiling.begin(.ioParse, "bytes=%d", slice.count)
        _ = renderOwner.feed(bytes: slice)
        parse.end()
        diagnosticsState.withLock { diagnostics in
            diagnostics.bytesFed += slice.count
            diagnostics.batches += 1
        }
        outputHandler.call()
        frameSignal.markDirty()
    }

    func dataReceivedBorrowed(_ bytes: Span<UInt8>) {
        if let consumer = outputConsumer.withLock({ $0 }) {
            let copy = bytes.copiedBytes()
            deliverProcessCallbackOnMain { consumer(copy) }
            outputHandler.call()
            return
        }
        frameSignal.markDirty()
        let parse = Profiling.begin(.ioParse, "bytes=%d", bytes.count)
        _ = renderOwner.feed(borrowedBytes: bytes)
        parse.end()
        diagnosticsState.withLock { diagnostics in
            diagnostics.bytesFed += bytes.count
            diagnostics.batches += 1
        }
        outputHandler.call()
        frameSignal.markDirty()
    }

    func getWindowSize() -> winsize {
        windowSize.withLock { $0 }
    }
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
 * make sure that you proxy the values in your implementation to the values set after initializing this instance.
 *
 * If you want additional control over the delegate methods implemented in this class, you can
 * subclass this and override the methods
 *
 * Terminal parsing for this view runs on the background LocalProcess IO thread. TerminalViewDelegate
 * callbacks produced by parsing are marshalled back to the main thread by TerminalView.
 */
open class LocalProcessTerminalView: TerminalView, TerminalViewDelegate {
    
    public internal(set) var process: LocalProcess!
    private var processAdapter: LocalProcessTerminalViewProcessAdapter!
    nonisolated private let processOutputHandler = LockedVoidCallback()

    public override init (frame: CGRect)
    {
        super.init (frame: frame)
        setup ()
    }

    /// Creates a local process terminal view with explicit startup options for the underlying `Terminal`
    public override init (frame: CGRect, font: NSFont? = nil, options: TerminalOptions)
    {
        super.init (frame: frame, font: font, options: options)
        setup ()
    }

    public required init? (coder: NSCoder)
    {
        super.init (coder: coder)
        setup ()
    }

    func setup ()
    {
        terminalDelegate = self
        let adapter = LocalProcessTerminalViewProcessAdapter(
            renderOwner: renderOwner,
            frameSignal: frameSignal,
            diagnosticsState: diagnosticsState,
            outputHandler: processOutputHandler,
            terminationHandler: { [weak self] exitCode in
                guard let self, let process = self.process else { return }
                self.processTerminated(process, exitCode: exitCode)
            })
        processAdapter = adapter
        // Direct delivery keeps process output on the IO parse thread. The
        // explicit main queue preserves UI lifecycle delivery.
        process = LocalProcess(
            delegate: adapter,
            dispatchQueue: .main,
            directDelivery: true)
        adapter.attachInputProcess(process)
        inputSender.replaceDelivery { [adapter] bytes in
            adapter.sendInput(bytes)
        }
        adapter.updateWindowSize(getWindowSize())
    }

    /// Installs a notification that runs on the process parse thread after an
    /// output batch is handled. With an output consumer, this means the consumer
    /// has returned, not necessarily that the bytes have been parsed. The handler
    /// receives no mutable terminal state and must return quickly.
    public func setProcessOutputHandler(_ handler: (@Sendable () -> Void)?) {
        processOutputHandler.replace(with: handler)
    }

    /// Takes ownership of process output before parsing, or restores automatic
    /// background parsing with nil. Configure this before starting a process.
    ///
    /// A consumer receives one copied batch synchronously on the main actor.
    /// It must feed the bytes or place them in its own bounded storage before
    /// returning. The parse worker waits, preserving FIFO and backpressure;
    /// consumers must not synchronously wait for process output or termination.
    /// Direct calls to feed do not invoke the consumer. With nil, the existing
    /// borrowed-byte parser path remains unchanged and makes no extra copy.
    public func setProcessOutputConsumer(_ consumer: ProcessOutputConsumer?) throws {
        guard !process.running, !process.windingDown else {
            throw ProcessOutputConsumerError.processActive
        }
        processAdapter.setOutputConsumer(consumer)
    }
    
    /**
     * The `processDelegate` is used to deliver messages and information relevant t
     */
    public weak var processDelegate: LocalProcessTerminalViewDelegate?
    
    /**
     * This method is invoked to notify the client of the new columsn and rows that have been set by the UI
     */
    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        var size = getWindowSize()
        processAdapter.updateWindowSize(size)
        guard process.updateWindowSize(&size) else { return }
        
        processDelegate?.sizeChanged (source: self, newCols: newCols, newRows: newRows)
    }
    
    public func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String (bytes: content, encoding: .utf8) {
            let pasteBoard = NSPasteboard.general
            pasteBoard.clearContents()
            pasteBoard.writeObjects([str as NSString])
        }
    }
    
    public func clipboardRead(source: TerminalView) -> Data? {
        guard let str = NSPasteboard.general.string(forType: .string) else {
            return nil
        }
        return str.data(using: .utf8)
    }
    
    /**
     * Invoke this method to notify the processDelegate of the new title for the terminal window
     */
    public func setTerminalTitle(source: TerminalView, title: String) {
        processDelegate?.setTerminalTitle (source: self, title: title)
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        processDelegate?.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }

    /**
     * Invoked when the user activates a link, override to handle the link yourself
     */
    open func requestOpenLink (source: TerminalView, link: String, params: [String:String])
    {
        openLink (link)
    }

    /**
     * This method is invoked when input from the user needs to be sent to the client
     * Implementation of the TerminalViewDelegate method
     */
    open func send(source: TerminalView, data: ArraySlice<UInt8>)
    {
        process.send (data: data)
    }
    
    /**
     * Use this method to toggle the logging of data coming from the host, or pass nil to stop
     */
    public func setHostLogging (directory: String?)
    {
        process.setHostLogging (directory: directory)
    }
    
    /// Implementation of the TerminalViewDelegate method
    open func scrolled(source: TerminalView, position: Double) {
        // noting
    }

    open func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        //
    }
    
    /**
     * Launches a child process inside a pseudo-terminal.
     * - Parameter executable: The executable to launch inside the pseudo terminal, defaults to /bin/bash
     * - Parameter args: an array of strings that is passed as the arguments to the underlying process
     * - Parameter environment: an array of environment variables to pass to the child process, if this is null, this picks a good set of defaults from `Terminal.getEnvironmentVariables`.
     * - Parameter execName: If provided, this is used as the Unix argv[0] parameter, otherwise, the executable is used as the args [0], this is used when the intent is to set a different process name than the file that backs it.
     * - Parameter currentDirectory: If provided, the process will be launched with this as the current working directory.
     */
    public func startProcess(executable: String = "/bin/bash", args: [String] = [], environment: [String]? = nil, execName: String? = nil, currentDirectory: String? = nil)
    {
        // A nil environment keeps the LocalProcess default (TERM=xterm-256color);
        // hosts that want options.termName in the child's environment pass
        // Terminal.getEnvironmentVariables(termName:) explicitly
        processAdapter.updateWindowSize(getWindowSize())
        process.startProcess(executable: executable, args: args, environment: environment, execName: execName, currentDirectory: currentDirectory)
    }

    /**
     Terminate the process.
     */
    public func terminate() {
        process.terminate()
    }

    /**
     * Implements the LocalProcessDelegate method.
     */
    open func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        processDelegate?.processTerminated(source: self, exitCode: exitCode)
    }
    
    /**
     * Implements the LocalProcessDelegate.dataReceived method
     */
    open func dataReceived(slice: ArraySlice<UInt8>) {
        feed (byteArray: slice)
    }
    
    /**
     * Implements the LocalProcessDelegate.getWindowSize method
     */
    open func getWindowSize () -> winsize
    {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let dimensions = terminalDimensions
        let pxW = Int((cellDimension?.width ?? 0) * CGFloat(dimensions.cols) * scale)
        let pxH = Int((cellDimension?.height ?? 0) * CGFloat(dimensions.rows) * scale)
        return winsize(ws_row: UInt16(dimensions.rows),
                       ws_col: UInt16(dimensions.cols),
                       ws_xpixel: UInt16(pxW), ws_ypixel: UInt16(pxH))
    }
}

#endif
