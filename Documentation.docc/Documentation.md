# ``SwiftTerm``

SwiftTerm is a VT100/Xterm terminal emulator library for Swift applications that
can be embedded into macOS, iOS applications, text-based, headless applications
or other custom scenarios. 

For convenience, the documentation on this site merges both the core, AppKit and
UIKit APIs.

The SwiftTerm repository contains both the core terminal emulator, as well as
macOS and iOS front-ends as well as samples for both platforms.   The TermKit
module contains a sample showing how to embed the terminal application into
a text-mode framework. It has been used in several commercially available
SSH clients, including Secure Shellfish, La Terminal and CodeEdit

The sample Mac app has much of the functionality of MacOS' Terminal.app, but without the configuration UI.

## Features

* Pretty decent terminal emulation, on or better than XtermSharp and xterm.js
  (and more comprehensive in many ways)
* Unicode rendering (including Emoji, and combining characters and emoji)
* Reusable and pluggable engine allows multiple user interfaces to be built on
  top of it.
* Selection engine (with macOS support in the view)
* Supports colors (ANSI, 256, TrueColor)
* Supports mouse events
* Supports terminal resizing operations (controlled by remote host, or locally)
* [Hyperlinks](https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda) in terminal output
* AppKit, UIKit front-ends;  ncruses front-end [provided separately](https://github.com/migueldeicaza/TermKit)
* Local process and SSH connection support (some assembly required for the last
  one)
* Proper CoreText rendering can munch through the hardened Unicode test suites.
* Sixel graphics (Use img2sixel to test)
* iTerm2-style graphic rendering (Use imgcat to test)
* Fuzzed and abused
* Seems pretty fast to me

## Overview

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


<!--@START_MENU_TOKEN@-->Text<!--@END_MENU_TOKEN@-->

## Topics

### <!--@START_MENU_TOKEN@-->Group<!--@END_MENU_TOKEN@-->

- <!--@START_MENU_TOKEN@-->``Symbol``<!--@END_MENU_TOKEN@-->
