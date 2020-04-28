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

There is an equivalent UIKit UIVIew implementation for
[`TerminalView`](https://github.com/migueldeicaza/SwiftTerm/blob/master/SwiftTerm/Sources/SwiftTerm/iOS/iOSTerminalView.swift)
which like its NSView companion is an embeddable and reusable view
that can be connected to your application by implementing the same
TerminalViewDelegate.  Unlike the NSView case running on a Mac, where
a common scenario will be to run local commands, given that iOS does
not offer access to processes, the most common scenario will be to
wire up this terminal to a remote host.  And the safest way of
connecting to a remote system is with SSH.

The core library currently does not provide a convenient way to connect to SSH, purely
to avoid the additional dependency.   But this git module references a module that pulls
a precompiled SSH client ([Frugghi's SwiftSH](https://github.com/Frugghi/SwiftSH)), along with 
a [`UIKitSsshTerminalView`](https://github.com/migueldeicaza/SwiftTerm/blob/master/iOS/UIKitSshTerminalView.swift)
in the iOS sample that that connects the `TerminalView` for iOS to an SSH connection.  

The iOS and UIKit code share a lot of the code, that code lives under the Apple directory.

Both of these rely on the terminal engine (implemented in class
`Terminal`).  The engine itself does not have a user interface, nor
does it take input, nor does it know how to connect to an actual
process, those are provided by higher levels.

In the longer term, I want to also add a tvOS UIView, a [SwiftGtk](https://github.com/rhx/SwiftGtk) 
front-end for Linux, as well as an implementation for my Swift console toolkit
[TermKit](https://github.com/migueldeicaza/TermKit)/

This is a port of my original [XtermSharp](https://github.com/migueldeicaza/XtermSharp), which was
itself based on [xterm.js](https://xtermjs.org).  At this point, I consider SwiftTerm
to be a more advanced terminal emulator that both of those (modulo Selection/Accessibility) as
it handles UTF, Unicode and grapheme clusters better than those and has a more complete coverage of 
terminal emulation.   XtermSharp is generally attempting to keep up.

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
* AppKit, UIKit front-ends
* Local process and SSH connection support (some assembly required for the last one)
* Proper CoreText rendering can munch through the harded Unicode test suites.
* Seems pretty fast to me

Using SwiftTerm
===============

SwiftTerm uses the Swift Package Manager for its build, and you can
add the library to your project by using the url for this project or a
fork of it.

Working on SwiftTerm
====================

The iOS sample needs a conenction to somewhere to work, so I connected
it to the SwiftSH SSH client, and to make it easy, I brought it as a
framework in a submodule (I did not want to spam this module with
binaries), so you will need to check out the code like this:

```
$ git clone git@github.com:migueldeicaza/SwiftTerm.git
$ cd SwiftTerm
$ git submodule init
$ git submodule update --recursive
```

If you are using Xcode, there are two toplevel projects, one for Mac
and one for iOS.   This is needed because Xcode does not provide code
completion for iOS if you have a Mac project in the project.   So I had
to split them up.   Both projects reference the same SwiftTerm package.

You can use `swift build` to build the package, and `swift test` to
run the test suite - but be warned that the test suite expects the
directory `esctest` to be checked out to run.  You can see how I run
these on GitHub actions in the file .github/workflows/swift.yml if you
want to do this locally.

Pending Work
============

GitHub issues has a list of desired features and enhancements

Resources 
========= 

* [Terminal Guide](https://terminalguide.namepad.de) - very nice and visual, but not normative
* [Xterm Control Sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h2-Mouse-Tracking)
* [VT510 Video Terminal Programmer Information](https://vt100.net/docs/vt510-rm/contents.html])

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

# Authors

* Thanks go to the xterm.js developers that originally wrote a terminal emulator
that was licensed under a licenze that allowed for maximum reuse.   
* Marcin Krzyzanowski who masterfully improved and curated the rendering engine on AppKit/CoreText to be the glorious renderer that it is today - and for his contributions to the rendering engin
* Greg Munn that did a lot of work in XtermSharp to support the needs of Visual Studio for
Mac
* Miguel de Icaza -me- who have been looking for an excuse to write some Swift code.
