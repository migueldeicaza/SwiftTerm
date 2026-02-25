# ``HeadlessTerminal``

A terminal emulator that runs a local process without any UI.

## Overview

`HeadlessTerminal` combines a ``Terminal`` engine with a ``LocalProcess``,
providing a way to run commands and inspect their terminal output
programmatically. This is useful for scripting, testing, and automation
scenarios where you need access to the full terminal state (including colors,
cursor position, and escape sequence processing) but do not need a visual
display.

Access the underlying terminal through the ``terminal`` property to read
buffer contents, and use ``process`` to control the running subprocess.

For a detailed guide, see <doc:HeadlessUsage>.

## Topics

### Creating a Headless Terminal

- ``init(queue:options:onEnd:)``

### Terminal and Process Access

- ``terminal``
- ``process``

### Sending Data

- ``send(data:)``
- ``send(_:)``

### Runtime Configuration

- ``changeScrollback(_:)``
