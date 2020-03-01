
SwiftTerm
=========

SwiftTerm is a VT100/Xterm terminal emulator for Swift, the engine is
intended to be agnostic from potential front-ends and backends (for example
an AppKit front-end, a UIKit front-end, a TermKit front-end and so on;
and backends to directly spawn a child shell, or connect it to a remote
session).

This is a work-in-progress, and a port of
[XtermSharp](https://github.com/migueldeicaza/XtermSharp), which was
itself based on xterm.js.

The terminal itself does not deal with connecting the data to to a process
or a remote server.   Data is sent to the terminal by passing a byte array
with data to the "Feed" method.

Convenience classes exist to spawn a subprocess and connecting the
terminal to a local process, and allow some customization of the
environment variables to pass to the child.

Status
======

Validated and up to date with XtermSharp:

* Buffer
* BufferSet
* CharData
* TerminalOptions
* BufferLine
* CircularList
* EscapeSequenceParser
* EscapeSequences
* Colors

Pending:

* Terminal
* InputHandler
* Pty
* Reflows*
* SelectionService
* RuneExt


Against version: 57cf109188551c5d5e7fa7d2158448b4e8d2be64 from Feb 27, 2020
