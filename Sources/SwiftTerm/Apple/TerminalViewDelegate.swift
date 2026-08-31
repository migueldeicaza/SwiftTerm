//
//  TerminalViewDelegate.swift
//  
//
//  Created by Miguel de Icaza on 4/15/20.
//
#if os(iOS) || os(visionOS) || os(macOS)
import Foundation

/// Delegate used by ``TerminalView`` to notify the user of events happening
/// in it.
@MainActor
public protocol TerminalViewDelegate: AnyObject {
    /**
     * The client code sending commands to the terminal has requested a new size for the terminal
     * Applications that support this should call the `TerminalView.getOptimalFrameSize`
     * to get the ideal frame size.
     *
     * This is needed for the rare cases where the remote client request 80 or 132 column displays,
     * it is a rare feature and you most likely can ignore this request.
     *
     * ### If you resize a window here, do not animate it
     *
     * Resizing the window in response to this callback is a feedback loop: the
     * new frame resizes the terminal, which calls this method again. It settles
     * immediately when the frame you set is the one the terminal already wants.
     *
     * Animating that resize does not settle. `NSWindow.setFrame(_:display:animate:)`
     * with `animate: true` emits a stream of intermediate frames, each of which
     * resizes the terminal and calls back here, and each callback starts another
     * animation. Measured on a resize under load, main-thread stall p99 was
     * 14–35 ms animated against 6–17 ms not — before anything else was changed.
     *
     * Guard the callback by comparing frames rather than with a re-entrancy
     * flag. A `changingSize`-style flag only stops the loop while the callback
     * re-enters inside the same call stack, and SwiftTerm does not promise that:
     * during a live drag this notification is coalesced to one per display
     * frame and arrives after your flag has been cleared.
     *
     * ```swift
     * func sizeChanged (source: TerminalView, newCols: Int, newRows: Int) {
     *     guard let window = view.window else { return }
     *     let optimal = terminal.getOptimalFrameSize()
     *     let target = CGRect(x: window.frame.minX, y: window.frame.minY,
     *                         width: optimal.width,
     *                         height: window.frame.height - view.frame.height + optimal.height)
     *     // Idempotent: nothing to do when the window is already the right size.
     *     if abs(target.width - window.frame.width) < 0.5,
     *        abs(target.height - window.frame.height) < 0.5 { return }
     *     window.setFrame(target, display: true, animate: false)
     * }
     * ```
     *
     * See <doc:Embedding> for more information.
     */
    func sizeChanged (source: TerminalView, newCols: Int, newRows: Int)
  
    /**
     * Request to change the title of the terminal.
     */
    func setTerminalTitle(source: TerminalView, title: String)
  
    /**
     * Invoked when the OSC command 7 for "current directory has changed" command is sent
     */
    func hostCurrentDirectoryUpdate (source: TerminalView, directory: String?)
    
    /**
     * Request that date be sent to the application running inside the terminal.
     * - Parameter data: Slice of data that should be sent
     */
    func send (source: TerminalView, data: ArraySlice<UInt8>)
  
    /**
     * Invoked when the terminal has been scrolled and the new position is provided
     * - Parameter position: the relative position that the code was scrolled to, a value between 0 and 1
     */
    func scrolled (source: TerminalView, position: Double)
    
    /**
     * Invoked when the user activates a link (click on macOS, tap on iOS/visionOS).
     *
     * Explicit OSC 8 links can provide key/value metadata in `params`. Implicit URL
     * detection uses an empty `params` dictionary.
     *
     * On macOS, a default implementation opens the URL via `NSWorkspace.shared.open`.
     * On iOS/visionOS, implement this method to decide how to handle navigation.
     * - Parameter source: the terminalview that called this method
     * - Parameter link: the string that was encoded as a link by the client application, typically a url,
     * but could be anything, and could be used to communicate by the embedded application and the host
     * - Parameter params: the specification allows for key/value pairs to be provided, this contains the
     * key and value pairs that were provided
     */
    func requestOpenLink (source: TerminalView, link: String, params: [String:String])
    
    /**
     * This method will be invoked when the host beeps.
     */
    func bell (source: TerminalView)
    
    /**
     * This method is invoked when the client application has issued a OSC 52
     * to put data on the clipboard.
     *
     * - Parameters:
     *  - source: identifies the instance of the terminal that sent this request
     *  - content: the data to place on the clipboard
     * The default implementation does nothing.
     */
    func clipboardCopy(source: TerminalView, content: Data)
    
    /**
     * This method is invoked when the client application has issued an OSC 52
     * query to read the clipboard contents.
     *
     * Returning the clipboard data allows the terminal application to read it;
     * returning `nil` denies the request.  The host may use this callback to
     * prompt the user for confirmation before providing clipboard data.
     *
     * The default implementation returns `nil` (denying the request for security).
     *
     * - Parameter source: identifies the instance of the terminal that sent this request
     * - Returns: the current clipboard contents, or `nil` to deny the request
     */
    func clipboardRead(source: TerminalView) -> Data?

    /// Requests typed clipboard data from the host.
    func kittyClipboardRead(
        source: TerminalView,
        request: KittyClipboardReadRequest,
        completion: @escaping @Sendable (KittyClipboardReadResult) -> Void
    )

    /// Requests one atomic typed clipboard update from the host.
    func kittyClipboardWrite(
        source: TerminalView,
        request: KittyClipboardWriteRequest,
        completion: @escaping @Sendable (KittyClipboardWriteResult) -> Void
    )

    /// Returns whether the view can send and later serve Kitty paste events.
    func kittyClipboardPasteEventsSupported(source: TerminalView) -> Bool
    
    /**
     * This method is invoked when the client application (iTerm2) has issued a OSC 1337 and
     * SwiftTerm did not handle a handler for it.
     *
     * The default implementaiton does nothing.
     */
    func iTermContent (source: TerminalView, content: ArraySlice<UInt8>)
    
    /**
     * This method is invoked when there are visual changes in the terminal buffer if
     * the `notifyUpdateChanges` variable is set to true.
     */
    func rangeChanged (source: TerminalView, startY: Int, endY: Int)

}
#endif
