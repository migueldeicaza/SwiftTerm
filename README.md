
SwiftTerm
=========

SwiftTerm is a VT100/Xterm terminal emulator for Swift.

This repository contains both the terminal emulator engine, as well as
concrete implementation for macOS using AppKit's NSView.

The macOS AppKit NSView implemention (`TerminalView`) is a reusable
NSView control that can be connected to any source by implementing the
`TerminalViewDelegate`.  I anticipate that a common scenario will be
to host a local Unix command, so I have included
`LocalProcessTerminalView` which is an implementation that connects
the `TerminalView` to a Unix pseudo-terminal and runs a command there.

Both of these rely on the terminal engine (implemented in class
`Terminal`).  The engine itself does not have a user interface, nor
does it take input, nor does it know how to connect to an actual
process, those are provided by higher levels.

In the longer term, I want to provide an iOS/tvOS UIView as well as a
`View` implementation for my Swift console toolkit
[TermKit](https://github.com/migueldeicaza/TermKit)

It should be possible to connect this with an SSH client.  No attempt
to provide a convenience class exist, to avoid taking a large
dependency on one, maybe I will create a separate repository to
package an out of the box solution.

This is a work-in-progress, and a port of
[XtermSharp](https://github.com/migueldeicaza/XtermSharp), which was
itself based on xterm.js.

The terminal itself does not deal with connecting the data to to a process
or a remote server.   Data is sent to the terminal by passing a byte array
with data to the "Feed" method.

Convenience classes exist to spawn a subprocess and connecting the
terminal to a local process, and allow some customization of the
environment variables to pass to the child.

Features
========

* Supports up-to-date terminal emulation (TODO: list everything here?)
* Reusable and pluggable engine allows multiple user interfaces to be built on top of it.
* Selectin engine (with macOS support in the view)
* Supports colors
* Supports mouse events
* Supports terminal resizing operations

Status
======

Validated and up to date with XtermSharp:

* Buffer
* BufferSet
* CharData
* CharSet
* TerminalOptions
* BufferLine
* CircularList
* EscapeSequenceParser
* EscapeSequences
* Colors
* Reflows*
* Terminal - I am merging this an InputHandler, which I always hated being split
* InputHandler
* Pty
* SelectionService
* RuneExt
* selectionView

Pending:


MacView:
* autoScrollTimer.Elapsed += AutoScrollTimer_Elapsed;
* accessibilityService
* searchService

Desired:
* CharData.attribute should not be an Int32, should be a strong type
* Should replace repetitive code for cmdXXX to get the default out of [pars]


Against version: 57cf109188551c5d5e7fa7d2158448b4e8d2be64 from Feb 27, 2020

# Features

* 
