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
public protocol TerminalViewDelegate: AnyObject {
    /**
     * The client code sending commands to the terminal has requested a new size for the terminal
     * Applications that support this should call the `TerminalView.getOptimalFrameSize`
     * to get the ideal frame size.
     *
     * This is needed for the rare cases where the remote client request 80 or 132 column displays,
     * it is a rare feature and you most likely can ignore this request.
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
     * Invoked in response to the user clicking on a link, which is most likely a url, but is not
     * mandatory, so custom implementations receive a string, and they can act on this as a way
     * of communciating with the host if desired.   The default implementation calls NSWorkspace.shared.open()
     * on the URL.
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
