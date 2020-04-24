![Swift](https://github.com/migueldeicaza/SwiftTerm/workflows/Swift/badge.svg)

SwiftTerm
=========

SwiftTerm is a VT100/Xterm terminal emulator for Swift applications that can be embedded
into macOS or iOS applications.

This repository contains both the terminal emulator engine, as well as
concrete implementation for iOS using UIKit, and macOS using AppKit.

Check the [API Documentation](https://migueldeicaza.github.io/SwiftTerm/)

The macOS AppKit NSView implemention [`TerminalView`](https://migueldeicaza.github.io/SwiftTerm/Classes/TerminalView.html) is a reusable
NSView control that can be connected to any source by implementing the
[`TerminalViewDelegate`](https://migueldeicaza.github.io/SwiftTerm/Protocols/TerminalViewDelegate.html).  
I anticipate that a common scenario will be
to host a local Unix command, so I have included
[`LocalProcessTerminalView`](https://migueldeicaza.github.io/SwiftTerm/Classes/LocalProcessTerminalView.html)
 which is an implementation that connects
the `TerminalView` to a Unix pseudo-terminal and runs a command there.

The iOS view can be connected to an SSH client.

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
itself based on [xterm.js](https://xtermjs.org).

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

GitHub issues has a list of desired features and enhancements

Resources 
========= 

* [Terminal Guide](https://terminalguide.namepad.de) - very nice and visual, but not normative
* [Xterm Control Sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h2-Mouse-Tracking)
* [https://vt100.net/docs/vt510-rm/contents.html](VT510 Video Terminal Programmer Information)

Additional and useful documents:
* [VT330/VT340 Programmer Reference Manual Volume 2: Graphics Programming](https://vt100.net/docs/vt3xx-gp/contents.html)
* [A parser for DEC’s ANSI-compatible video terminals](https://vt100.net/emu/dec_ansi_parser)
* [Codes and Standards](https://vt100.net/emu/)
* [Linux Console Docs](http://man7.org/linux/man-pages/man4/console_codes.4.html) they are a subset of vt100, but often simple to follow.
* [Sixel Graphics](https://github.com/saitoha/libsixel)

Test suites:
* [VTTest](https://invisible-island.net/vttest/) - old, but still good
* [EscTest](https://gitlab.freedesktop.org/terminal-wg/esctest) - fantastic: George Nachman, the author of iTerm, created this test suite, and it became a FreeDesktop standard.  Since then, Thomas E. Dickey, the xterm maintainer and maintainer of many text apps has contributed to this effort.

Screenshots
===========

24 Bit Color 

<img width="1246" alt="24 bit color" src="https://user-images.githubusercontent.com/36863/79060395-82181400-7c52-11ea-8f48-cd02323a8284.png">

Midnight Commander

<img width="969" alt="Screen Shot 2020-04-12 at 12 17 49 AM" src="https://user-images.githubusercontent.com/36863/79060466-49c50580-7c53-11ea-8514-bb4a31359662.png">

Solid UTF-8 support, excellent rendering:
<img width="799" alt="Screen Shot 2020-04-22 at 11 25 30 PM" src="https://user-images.githubusercontent.com/36863/80055786-95e43580-84f0-11ea-86dd-8dfb7f062b39.png">

<img width="799" alt="Screen Shot 2020-04-22 at 11 25 24 PM" src="https://user-images.githubusercontent.com/36863/80055792-9977bc80-84f0-11ea-8cac-735d4a516a80.png">

Supports hyperlinks emitted by modern apps:

<img width="674" alt="image" src="https://user-images.githubusercontent.com/36863/80055972-0b500600-84f1-11ea-9c57-41cadce67162.png">

iOS support:

<img width="981" alt="image" src="https://user-images.githubusercontent.com/36863/80056069-54a05580-84f1-11ea-8597-5a227c9c64a7.png">

Screenshots
