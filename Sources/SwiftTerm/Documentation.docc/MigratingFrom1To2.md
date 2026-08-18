# Migrating from SwiftTerm 1.0 to 2.0

Update code that uses APIs that SwiftTerm 2.0 removes or replaces.

This guide describes the new SwiftTerm 2.0 API. To use the SwiftTerm 1.x API,
use the [`v1.x` branch](https://github.com/migueldeicaza/SwiftTerm/tree/v1.x) or a
[tagged 1.x release](https://github.com/migueldeicaza/SwiftTerm/tags).

## Overview

SwiftTerm 2.0 removes direct access to the escape sequence parser. It also adds
a `directDelivery` parameter to the ``LocalProcess`` and ``HeadlessTerminal``
initializers.

Most initializer call sites continue to compile because `directDelivery` has a
default value. You must change code that accesses the parser directly. You must
also change code that stores an initializer as a function value.

First, update the Swift Package Manager dependency:

```swift
.package(
    url: "https://github.com/migueldeicaza/SwiftTerm.git",
    from: "2.0.0"
)
```

## Replace direct parser access

SwiftTerm 1.0 made `EscapeSequenceParser` public and exposed it through
`Terminal.parser`. SwiftTerm 2.0 makes the parser type internal and the
property private. External code can no longer name `EscapeSequenceParser` or
access `Terminal.parser`. Register custom OSC handlers through
``Terminal/registerOscHandler(code:handler:)``.

Use this SwiftTerm 1.0 code as a reference:

```swift
terminal.parser.oscHandlers[123] = { data in
    guard let command = String(bytes: data, encoding: .utf8) else {
        return
    }
    print(command)
}
```

Replace it with this SwiftTerm 2.0 code:

```swift
terminal.registerOscHandler(code: 123) { data in
    guard let command = String(bytes: data, encoding: .utf8) else {
        return
    }
    print(command)
}
```

`registerOscHandler(code:handler:)` is also available in SwiftTerm 1.0. You can
make this change before you update the package dependency.

SwiftTerm 2.0 also removes these public parser type aliases:

- `EscapeSequenceParser.OscHandler`
- `EscapeSequenceParser.OscHandlerFallback`
- `EscapeSequenceParser.ApcHandler`
- `EscapeSequenceParser.ApcHandlerFallback`

Declare an application type alias if you store an OSC handler:

```swift
typealias OSCHandler = (ArraySlice<UInt8>) -> Void
```

SwiftTerm 2.0 does not provide public APIs for direct parser access, APC handler
registration, or fallback handler registration.

## Replace direct Terminal access from `TerminalView`

SwiftTerm 1.0 exposed the underlying terminal through ``TerminalView/getTerminal()``
so callers could mutate or query `Terminal` state directly.

SwiftTerm 2.0 removed those entry points from the public surface to keep
terminal mutation behind `Sendable` boundaries that are concurrency-safe.
Use terminal snapshots and command entry points instead:

- ``TerminalView/terminalDimensions`` for copied `cols`/`rows`
- ``TerminalView/terminalStateSnapshot()`` for status/diagnostic reads
- ``TerminalView/getBufferAsData(kind:encoding:)`` for text snapshots
- ``TerminalView/send(data:)`` / ``TerminalView/feed(byteArray:)`` /
  ``TerminalView/feed(text:)`` for parser-safe input
- ``TerminalView/softReset()`` and ``TerminalView/resetToInitialState()``

If you need terminal-level behavior inside UI callbacks, use the ``Terminal``
instance passed to ``TerminalViewDelegate`` methods such as
the `source` argument. For direct terminal ownership APIs, use
``HeadlessTerminal`` where ``HeadlessTerminal/terminal`` remains public.

Example migration:

```swift
// SwiftTerm 1.0
let terminal = terminalView.getTerminal()
terminal.feed(text: "\u{1b}[2J")

// SwiftTerm 2.0
terminalView.feed(text: "\u{1b}[2J")
let size = terminalView.terminalDimensions
```

## Update LocalProcess initializer references

SwiftTerm 1.0 has `LocalProcess.init(delegate:dispatchQueue:)`. SwiftTerm 2.0
replaces it with `LocalProcess.init(delegate:dispatchQueue:directDelivery:)`.
The new `directDelivery` parameter is a Boolean value. Its default value is
`false`.

An ordinary initializer call does not require a change:

```swift
let process = LocalProcess(delegate: delegate, dispatchQueue: queue)
```

Set `directDelivery` to `false` to preserve SwiftTerm 1.0 delivery behavior:

```swift
let process = LocalProcess(
    delegate: delegate,
    dispatchQueue: queue,
    directDelivery: false
)
```

With `false`, ``LocalProcessDelegate/dataReceived(slice:)`` runs on the
specified dispatch queue. If you pass `nil`, SwiftTerm uses a private serial
queue. Pass `DispatchQueue.main` explicitly if the delegate updates the UI.
This queue-default change does not require a source change, but it changes
callback delivery for code that omitted `dispatchQueue`. With `true`, the
method runs directly on the thread that parses I/O data. Set `true` only if the
delegate can safely receive calls from the I/O thread.

The new initializer is a different API declaration even though the parameter
has a default value. If you store the initializer as a function value, use the
new initializer reference and add the Boolean argument:

```swift
let makeProcess =
    LocalProcess.init(delegate:dispatchQueue:directDelivery:)

let process = makeProcess(delegate, queue, false)
```

You can also use a wrapper function that passes `directDelivery: false`. If you
distribute a compiled framework that links to SwiftTerm, rebuild the framework
against SwiftTerm 2.0.

## Update HeadlessTerminal initializer references

SwiftTerm 1.0 has `HeadlessTerminal.init(queue:options:onEnd:)`. SwiftTerm 2.0
replaces it with
`HeadlessTerminal.init(queue:options:directDelivery:onEnd:)`. The new
`directDelivery` parameter is a Boolean value. Its default value is `false`.

Calls that use an `onEnd` trailing closure continue to compile:

```swift
let terminal = HeadlessTerminal(options: options) { exitCode in
    handleExit(exitCode)
}
```

Use `directDelivery: false` to preserve queued delivery. Set it to `true` to
parse process output directly on the thread that parses I/O data. Update stored
initializer references and wrapper functions to include the new parameter:

```swift
let makeTerminal =
    HeadlessTerminal.init(queue:options:directDelivery:onEnd:)

let terminal = makeTerminal(queue, options, false, handleExit)
```

When `queue` is `nil`, `HeadlessTerminal` and its ``LocalProcess`` share one
private serial queue. Input registration and queued process output therefore
use the same FIFO delivery domain. Pass `DispatchQueue.main` explicitly if the
callbacks must run on the main queue.

## Verify the migration

Before you release the updated application:

1. Search for `EscapeSequenceParser`, `.parser`, `oscHandlers`,
   and `getTerminal`.
2. Replace direct OSC handler registration with
   ``Terminal/registerOscHandler(code:handler:)``.
3. Replace Terminal access patterns using terminal snapshots or delegate callbacks.
4. Review all ``LocalProcess`` and ``HeadlessTerminal`` initializer references.
5. Rebuild all modules that link to SwiftTerm.
6. Run tests that send and receive process data.

## Topics

### Related APIs

- ``Terminal/registerOscHandler(code:handler:)``
- ``TerminalView/terminalDimensions``
- ``TerminalView/terminalStateSnapshot()``
- ``TerminalView/getBufferAsData(kind:encoding:)``
- ``TerminalView/send(data:)``
- ``LocalProcess``
- ``LocalProcessDelegate``
- ``HeadlessTerminal``
