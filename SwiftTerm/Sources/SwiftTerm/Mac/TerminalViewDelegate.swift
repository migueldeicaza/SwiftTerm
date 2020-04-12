//
//  TerminalViewDelegate.swift
//  
//
//  Created by Marcin Krzyzanowski on 11/04/2020.
//

public protocol TerminalViewDelegate: class {
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
   * The provided `data` needs to be sent to the application running inside the terminal
   */
  func send (source: TerminalView, data: ArraySlice<UInt8>)

  /**
   * Invoked when the terminal has been scrolled and the new position is provided
   */
  func scrolled (source: TerminalView, position: Double)
}
