# Connecting via SSH

Wire a terminal view to a remote host over SSH.

## Overview

SwiftTerm does not bundle an SSH library to avoid adding a heavyweight dependency.
Instead, you connect the terminal to an SSH channel by implementing the data flow
yourself. This guide describes the pattern and points to working examples.

## The Wiring Pattern

The integration between SwiftTerm and SSH has two directions:

1. **User input to SSH**: Implement ``TerminalViewDelegate/send(source:data:)``
   and write the received bytes to the SSH channel.

2. **SSH output to terminal**: When data arrives from the SSH channel, call
   ``TerminalView/feed(byteArray:)`` to deliver it to the terminal.

```
┌──────────────┐   send(data:)    ┌──────────────┐
│              │ ───────────────▶ │              │
│ TerminalView │                  │  SSH Channel  │
│              │ ◀──────────────  │              │
└──────────────┘  feed(byteArray:) └──────────────┘
```

## Example with swift-nio-ssh

Apple's [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) is a
SwiftNIO-based SSH implementation. The iOS sample application in the SwiftTerm
repository demonstrates a complete integration:

- [`UIKitSshTerminalView.swift`](https://github.com/migueldeicaza/SwiftTerm/blob/main/TerminalApp/iOSTerminal/UIKitSshTerminalView.swift)
  — subclasses the terminal view and manages the SSH lifecycle.
- [`SSHLoginView.swift`](https://github.com/migueldeicaza/SwiftTerm/blob/main/TerminalApp/iOSTerminal/SSHLoginView.swift)
  — provides a login UI for entering credentials.

The core flow in the sample:

```swift
// 1. In TerminalViewDelegate.send(), forward to SSH:
func send(source: TerminalView, data: ArraySlice<UInt8>) {
    sshChannel.write(data)
}

// 2. When SSH delivers data, feed to terminal:
sshChannel.onData { data in
    DispatchQueue.main.async {
        self.terminalView.feed(byteArray: data)
    }
}

// 3. When the terminal resizes, notify the SSH channel:
func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
    sshChannel.requestPtyResize(cols: newCols, rows: newRows)
}
```

## Terminal Size Reporting

When opening an SSH session, the server needs the initial terminal size for the
PTY allocation. After the connection is established, notify the server of size
changes through ``TerminalViewDelegate/sizeChanged(source:newCols:newRows:)``.

## Environment Variables

Use ``Terminal/getEnvironmentVariables(termName:trueColor:)`` to build an
environment suitable for the remote shell:

```swift
let env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
// Pass env when opening the SSH channel
```

## macOS vs iOS

On macOS, you can also use SSH — the only difference is that macOS also supports
local processes, so SSH is one option among several. On iOS, SSH (or another
network protocol) is the only way to connect to a shell, since iOS does not allow
spawning local processes.

## Other SSH Libraries

The wiring pattern is the same regardless of which SSH library you use.
[NMSSH](https://github.com/NMSSH/NMSSH), [Shout](https://github.com/jakeheis/Shout),
and [BlueSocket](https://github.com/Kitura/BlueSocket) with libssh2 have all been
used with SwiftTerm by the community.
