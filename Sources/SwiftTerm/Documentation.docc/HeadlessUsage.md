# Headless Terminal Usage

Run a terminal emulator without a UI for scripting, testing, and automation.

## Overview

``HeadlessTerminal`` pairs a ``Terminal`` engine with a ``LocalProcess``, letting
you run commands and inspect the terminal output programmatically. There is no view
involved — the terminal state lives entirely in memory.

## Basic Usage

Create a ``HeadlessTerminal`` with an `onEnd` callback, start a process, and wait
for it to finish:

```swift
import SwiftTerm

let semaphore = DispatchSemaphore(value: 0)

let headless = HeadlessTerminal(
    options: TerminalOptions(cols: 80, rows: 24)
) { exitCode in
    semaphore.signal()
}

headless.process.startProcess(
    executable: "/usr/bin/env",
    args: ["ls", "-la"]
)

semaphore.wait()
```

## Reading Terminal Output

After the process completes, the terminal buffer contains exactly what a user
would see on screen. You can extract it as text:

```swift
let data = headless.terminal.getBufferAsData()
let text = String(data: data, encoding: .utf8) ?? ""
```

Or access individual lines and cells:

```swift
let terminal = headless.terminal!
for row in 0..<terminal.rows {
    if let line = terminal.getLine(row: row) {
        let text = line.translateToString(trimRight: true)
        print("Row \(row): \(text)")
    }
}
```

## Copying a Frame for a Custom Renderer

When a headless process needs to drive a renderer, use an owned render snapshot
instead of retaining mutable buffer lines. A `.full` frame includes the visible
grid; `.dirty` includes only changed rows. Draw the snapshot after it returns,
then clear terminal damage only after the draw succeeds.

```swift
let terminal = headless.terminal!
let frame = terminal.makeRenderSnapshot(scope: .dirty)
draw(frame)
terminal.terminalLock.withLock {
    terminal.clearUpdateRange()
}
```

See <doc:PortableHosting> for cell-width rules, semantic input, pointer input,
selection, and scrollback support in a custom host.

## Sending Input

Send keystrokes or text to the running process through the terminal:

```swift
// Send a string
headless.send("hello\n")

// Send raw bytes (e.g., control characters)
headless.send(data: [0x03][...])  // Ctrl-C
```

## Custom Terminal Size

Pass a ``TerminalOptions`` with the desired dimensions. Applications running in
the terminal will see this size and format their output accordingly:

```swift
let options = TerminalOptions(cols: 132, rows: 50, scrollback: 5000)
let headless = HeadlessTerminal(options: options) { _ in }
```

## Dispatch Queue

By default, process I/O is dispatched on a private queue. You can provide your
own queue for integration with existing concurrency patterns:

```swift
let queue = DispatchQueue(label: "com.example.terminal")
let headless = HeadlessTerminal(queue: queue, options: .default) { _ in }
```

## Terminal Session Recording with Termcast

SwiftTerm includes `termcast`, a command-line tool for recording and playing back
terminal sessions in the [asciinema](https://asciinema.org/) `.cast` format. It
uses `LocalProcess` and the terminal engine under the hood.

### Recording

```bash
swift run termcast record session.cast
swift run termcast record -c "top -l 5" top-demo.cast
swift run termcast record --timeout 30 timed.cast
```

### Playback

```bash
swift run termcast playback session.cast
```

## Use Cases

- **Integration testing**: Verify that a CLI tool produces expected output,
  including colors and cursor positioning.
- **Screen scraping**: Run a TUI application and read specific cells from the
  buffer to extract structured data.
- **Automation**: Drive interactive programs by sending input and reading output.
- **CI pipelines**: Capture terminal output in a format that preserves formatting.
