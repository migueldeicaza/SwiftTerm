# ``SwiftTerm``

SwiftTerm is a VT100/Xterm terminal emulator library for Swift applications that
can be embedded into macOS, iOS applications, text-based, headless applications
or other custom scenarios.

## Overview

SwiftTerm provides a reusable, pluggable terminal emulation engine with platform-specific
front-ends for AppKit (macOS) and UIKit (iOS/visionOS). The core engine handles escape
sequence parsing, buffer management, Unicode rendering, and terminal state — while the
view layer handles input, rendering, and platform integration.

The library has been used in several commercially available SSH clients, including
[Secure Shellfish](https://apps.apple.com/us/app/secure-shellfish-ssh-files/id1336634154),
[La Terminal](https://apps.apple.com/us/app/la-terminal-ssh-client/id1629902861),
and [CodeEdit](https://github.com/CodeEditApp/CodeEdit).

SwiftTerm uses the Swift Package Manager for its build. Add the library to your
project by using the URL for this repository.

### macOS

The macOS AppKit ``TerminalView`` is a reusable `NSView` that can be connected to
any data source by implementing ``TerminalViewDelegate``. For the common case of
running a local Unix process, ``LocalProcessTerminalView`` connects the terminal
to a pseudo-terminal.

### iOS and visionOS

The UIKit ``TerminalView`` is an embeddable `UIScrollView` subclass that uses the
same ``TerminalViewDelegate`` protocol. Since iOS does not support local processes,
the typical use case is connecting the terminal to a remote host via SSH.

### Headless

``HeadlessTerminal`` runs a local process without any UI, useful for scripting,
testing, and screen-scraping terminal output.

### Features

- Unicode rendering including Emoji, combining characters, and grapheme clusters
- Colors: ANSI, 256-color, and TrueColor
- Text attributes: bold, italic, underline, strikethrough, dim/faint, blink, inverse
- Mouse event reporting (X10, SGR, UTF-8, URxvt protocols)
- Terminal resizing (local and remote-initiated)
- Hyperlink support (OSC 8)
- Graphics: Sixel, iTerm2-style inline images, and Kitty graphics protocol
- Selection and search with a built-in macOS find bar and programmable search APIs
- Thread-safe ``Terminal`` instances
- Terminal session recording and playback with `termcast`

## Topics

### Essentials

- <doc:GettingStarted>
- ``Terminal``
- ``TerminalOptions``
- ``CursorStyle``

### Views

- ``TerminalView``
- ``TerminalViewDelegate``

### Running Local Processes

- ``LocalProcess``
- ``LocalProcessDelegate``
- ``LocalProcessTerminalView``
- ``LocalProcessTerminalViewDelegate``

### Headless Usage

- <doc:HeadlessUsage>
- ``HeadlessTerminal``

### Guides

- <doc:Customization>
- <doc:GraphicsSupport>
- <doc:SSHIntegration>

### Terminal Delegate

- ``TerminalDelegate``

### Terminal Configuration

- ``TerminalOptions``
- ``CursorStyle``

### Buffer and Content Access

- ``Buffer``
- ``BufferLine``
- ``Terminal/BufferKind``

### Data Types

- ``Position``
- ``Attribute``
- ``CharData``
- ``CharacterStyle``
- ``Color``

### Selection and Search

- ``SelectionService``
- ``SearchService``
- ``SearchOptions``

### Graphics

- ``ImageSizeRequest``
- ``TerminalImage``

### Mouse Input

- ``Terminal/MouseMode``
