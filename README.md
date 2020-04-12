![Swift](https://github.com/migueldeicaza/SwiftTerm/workflows/Swift/badge.svg)

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

* Pretty decent terminal emulation, on or better than XtermSharp and xterm.js (and more comprehensive in many ways)
* Unicode rendering (including Emoji, and combining characters and emoji)
* Reusable and pluggable engine allows multiple user interfaces to be built on top of it.
* Selection engine (with macOS support in the view)
* Supports colors (ANSI, 256, TrueColor)
* Supports mouse events
* Supports terminal resizing operations (controled by remote host, or locally)
* [Hyperlinks](https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda) in terminal output

Pending Work
============

I have not ported the Accessibility or Search service, scrolling is
currently disabled, and I am not crazy about the selection
implementation.

Currently the attributes are limited to the standard xterm-colors, so
I need to complete that work.

I would also like to introduce logging of the various events raised by the
parser and rename some of them with their DEC names.

For a list of wish-list items, check the GitHub issues.

Screenshots
===========

24 Bit Color 

<img width="1246" alt="24 bit color" src="https://user-images.githubusercontent.com/36863/79060395-82181400-7c52-11ea-8f48-cd02323a8284.png">

Midnight Commander

<img width="969" alt="Screen Shot 2020-04-12 at 12 17 49 AM" src="https://user-images.githubusercontent.com/36863/79060466-49c50580-7c53-11ea-8514-bb4a31359662.png">


Screenshots
