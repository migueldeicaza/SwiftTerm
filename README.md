[![Swift](https://github.com/migueldeicaza/SwiftTerm/actions/workflows/swift.yml/badge.svg)](https://github.com/migueldeicaza/SwiftTerm/actions/workflows/swift.yml)


SwiftTerm
=========

SwiftTerm is a VT100/Xterm terminal emulator library for Swift applications that can be 
embedded into macOS, iOS applications, text-based, headless applications or other 
custom scenarios. It has been used in several commercially available SSH clients, including 
[Secure Shellfish](https://apps.apple.com/us/app/secure-shellfish-ssh-files/id1336634154), 
 [La Terminal](https://apps.apple.com/us/app/la-terminal-ssh-client/id1629902861) and [CodeEdit](https://github.com/CodeEditApp/CodeEdit)

Check the [API Documentation](https://migueldeicaza.github.io/SwiftTermDocs/documentation/swiftterm/)

This repository contains both a terminal emulator engine that is UI agnostic, as well as
front-ends for this engine for iOS using UIKit, and macOS using AppKit.   A curses-based
terminal emulator (to emulate an xterm inside a console application) is available as
part of the [TermKit](https://github.com/migueldeicaza/TermKit) library. 

**Sample Code** There are a couple of minimal sample apps for Mac and iOS showing how to 
use the library inside the `TerminalApp` directory.   

* The sample Mac app has much of the functionality of MacOS' Terminal.app, but without the configuration UI.   
* The sample iOS application uses an SSH library to connect to a remote system (as there is no native shell 
on iOS to run), and the sample happens to be hardcoded to my home machine, you can change that in the source
code. 

**Companion App** [SwiftTermApp](https://github.com/migueldeicaza/SwiftTermApp)
builds an actual iOS app that uses this library and is more complete than the
testing apps in this module and provides a proper configuration UI.


This is a port of my original
[XtermSharp](https://github.com/migueldeicaza/XtermSharp), which was itself
based on [xterm.js](https://xtermjs.org).  At this point, I consider SwiftTerm
to be a more advanced terminal emulator than both of those (modulo
Selection/Accessibility) as it handles UTF, Unicode and grapheme clusters better
than those and has a more complete coverage of terminal emulation.   XtermSharp
is generally attempting to keep up.

Features
========

* Pretty decent terminal emulation, on or better than XtermSharp and xterm.js (and more comprehensive in many ways)
* Unicode rendering (including Emoji, and combining characters and emoji)
* Reusable and pluggable engine allows multiple user interfaces to be built on top of it.
* Selection engine (with macOS support in the view)
* Supports colors (ANSI, 256, TrueColor)
* Supports mouse events
* Supports terminal resizing operations (controlled by remote host, or locally)
* [Hyperlinks](https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda) in terminal output
* AppKit, UIKit front-ends; ncurses front-end [provided separately](https://github.com/migueldeicaza/TermKit)
* Local process and SSH connection support (some assembly required for the last one)
* Proper CoreText rendering can munch through the hardened Unicode test suites.
* Sixel graphics (Use img2sixel to test)
* iTerm2-style graphic rendering (Use imgcat to test)
* Fuzzed and abused
* Seems pretty fast to me

# SwiftTerm library

The SwiftTerm library itself contains the source code for both
the engine and the front-ends.  The front-ends are conditionally
compiled based on the target platform.

The engine is in this directory, while code for macOS lives under `Mac`, and
code for iOS, lives under `iOS`.    Given that those two share a lot of common 
traits, the shared code is under `Apple`.

## Using SwiftTerm

SwiftTerm uses the Swift Package Manager for its build, and you can
add the library to your project by using the url for this project or a
fork of it.

## MacOS NSView 
The macOS AppKit NSView implementation [`TerminalView`](https://migueldeicaza.github.io/SwiftTermDocs/documentation/swiftterm/terminalview) is a reusable
NSView control that can be connected to any source by implementing the
[`TerminalViewDelegate`](https://migueldeicaza.github.io/SwiftTermDocs/documentation/swiftterm/terminalviewdelegate).  
I anticipate that a common scenario will be
to host a local Unix command, so I have included
[`LocalProcessTerminalView`](https://migueldeicaza.github.io/SwiftTermDocs/documentation/swiftterm/localprocessterminalview)
 which is an implementation that connects
the `TerminalView` to a Unix pseudo-terminal and runs a command there.

## iOS UIView
There is an equivalent UIKit UIView implementation for
[`TerminalView`](https://migueldeicaza.github.io/SwiftTermDocs/documentation/swiftterm/terminalview)
which like its NSView companion is an embeddable and reusable view
that can be connected to your application by implementing the same
TerminalViewDelegate.  Unlike the NSView case running on a Mac, where
a common scenario will be to run local commands, given that iOS does
not offer access to processes, the most common scenario will be to
wire up this terminal to a remote host.  And the safest way of
connecting to a remote system is with SSH.

## Shared Code between MacOS and iOS

The iOS and UIKit code share a lot of the code, that code lives under the Apple directory.

## Using SSH
The core library currently does not provide a convenient way to connect to SSH, purely
to avoid the additional dependency.   But this git module references a module that pulls
a precompiled SSH client ([Frugghi's SwiftSH](https://github.com/migueldeicaza/SwiftSH)), along with 
a [`UIKitSsshTerminalView`](https://github.com/migueldeicaza/SwiftTerm/blob/main/TerminalApp/iOSTerminal/UIKitSshTerminalView.swift)
in the iOS sample that that connects the `TerminalView` for iOS to an SSH connection.  

Working on SwiftTerm
====================

If you are using Xcode, there are two toplevel projects, one for Mac
and one for iOS in the TerminalApp directory, one called "iOSTerminal.xcodeproj"
and one called "MacTerminal.xcodeproj".  

This is needed because Xcode does not provide code completion for iOS if you 
have a Mac project in the project.   So I had to split them up.   Both 
projects reference the same SwiftTerm package.

When working with these projects, if you choose the terminal application
it will run this one.   To run the test suite, select the 'SwiftTerm' target
instead, and you can use 'SwiftTermFuzz' to run the fuzzer.

You can use `swift build` to build the package, and `swift test` to
run the test suite - but be warned that the test suite expects the
directory `esctest` to be checked out to run.  You can see how I run
these on GitHub actions in the file `.github/workflows/swift.yml` if you
want to do this locally.

If using Xcode, you can select the "SwiftTerm" project, and then use Command-U 
to run the test suite.

Pending Work
============

GitHub issues has a list of desired features and enhancements

Long Term Plans
===============

In the longer term, I want to also add a tvOS UIView, a
[SwiftGtk](https://github.com/rhx/SwiftGtk) front-end for Linux.

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

Sixel support:

<img width="770" alt="image" src="https://user-images.githubusercontent.com/36863/115647346-97a62c00-a2f1-11eb-929a-f9d942cc0c09.png">

<img width="568" alt="image" src="https://user-images.githubusercontent.com/36863/115647706-4e0a1100-a2f2-11eb-9bba-2a82503bca33.png">


Resources 
========= 

* [Digital's VT100 User Guide](https://geoffg.net/Downloads/Terminal/VT100_User_Guide.pdf)
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

# Authors

* Thanks go to the [xterm.js](https://xtermjs.org/) developers that originally wrote a terminal emulator
that was licensed under a license that allowed for maximum reuse.   
* [Marcin Krzyzanowski](https://krzyzanowskim.com) who masterfully improved and curated the rendering engine on AppKit/CoreText to be the glorious renderer that it is today - and for his contributions to the rendering engine
* Greg Munn that did a lot of work in XtermSharp to support the needs of Visual Studio for
Mac
* [Anders Borum](https://github.com/palmin) has contributed reliability fixes, the sixel parser and changes required to put SwiftTerm to use in production.
* [Miguel de Icaza](https://tirania.org/) -me- who have been looking for an excuse to write some Swift code.
