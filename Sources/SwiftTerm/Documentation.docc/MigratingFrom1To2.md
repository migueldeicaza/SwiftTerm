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

SwiftTerm 2.0 does not expose a `Terminal` from `TerminalView`. `Terminal` and
its buffers are mutable. Parsing, rendering, and input can occur on different
threads. A raw terminal reference could outlive the lock that protects it.
It could also change state without a new view snapshot and redraw.

The internal `withTerminal` helper is not a replacement public API. A closure
cannot prevent callers from saving the `Terminal`, `Buffer`, or `BufferLine`.
It must not call an API that takes the terminal lock again. Use the view's
copied reads and command entry points. They own the locking, copying, and
render updates.

### Read terminal data

Use the narrowest read API that gives the data you need:

| Need | API | Result |
| --- | --- | --- |
| Grid size | ``TerminalView/terminalDimensions`` | A copied `TerminalDimensions` value with columns and rows. |
| Status or visible screen | ``TerminalView/terminalStateSnapshot()`` | A copied ``TerminalViewStateSnapshot``. It includes dimensions, cursor state, viewport row, palette state, and visible rows. |
| Text from the active, normal, or alternate buffer | ``TerminalView/getBufferAsData(kind:encoding:)`` | A copied `Data` value. Select the required ``Terminal/BufferKind``. |
| A terminal event outside the displayed content | `TerminalView.observeOscEvents(_:)` | A copied ``TerminalOscEvent`` goes to an `@Sendable` handler. Retain its ``TerminalOscObservation`` token for the required lifetime. |

`TerminalView.observeOscEvents(_:)` is for passive observation, such as OSC 9,
99, or 777 desktop notifications that the view does not display. It preserves
normal OSC handling. Its handler runs asynchronously. Do not use it for a
response that must change parser behavior. If an application owns a
``Terminal`` directly, it can instead use
``Terminal/observeOscEvents(_:)`` or
``Terminal/registerOscHandler(code:handler:)``.

### Send data and change terminal state

The direction of the data determines the API:

| Operation | API | Use |
| --- | --- | --- |
| Receive bytes or text from the process or remote peer | ``TerminalView/feed(byteArray:)`` or ``TerminalView/feed(text:)`` | Parse output and update the display. These APIs are safe from another thread. |
| Keep a sendable input handle for a background transport | ``TerminalView/feedSender`` | Store its `TerminalFeedSender` when the transport must not retain the view. Call `feed` with received output. |
| Send user input to the process or remote peer | ``TerminalView/send(data:)`` | Send bytes through ``TerminalViewDelegate/send(source:data:)``. The host delegate writes them to its transport. |
| Paste application-provided text | ``TerminalView/pasteText(_:)`` | Call this main-actor API. It applies bracketed paste and paste safety rules. Do not use `send(data:)` unless the content is typed input. |
| Perform DECSTR | ``TerminalView/softReset()`` | Reset terminal modes through the normal parser path. |
| Perform RIS | ``TerminalView/resetToInitialState()`` | Reset the terminal to its initial state through the normal parser path. |

``TerminalViewDelegate`` callbacks also give the host the view and copied event
values such as a title or a resize. The `source` argument is a `TerminalView`,
not a `Terminal`. Keep delegate callbacks short. Do not call `feed` or `send`
from a callback that runs with the terminal lock held.

For an application that needs direct ownership of a terminal without a view,
use ``HeadlessTerminal``. ``HeadlessTerminal/terminal`` remains public because
the application, rather than a view, owns its lifecycle and rendering.

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
3. Replace Terminal access patterns with the matching view read or command API.
4. Review all ``LocalProcess`` and ``HeadlessTerminal`` initializer references.
5. Rebuild all modules that link to SwiftTerm.
6. Run tests that send and receive process data.

## Topics

### Related APIs

- ``Terminal/registerOscHandler(code:handler:)``
- ``TerminalView/terminalDimensions``
- ``TerminalView/terminalStateSnapshot()``
- ``TerminalView/getBufferAsData(kind:encoding:)``
- ``TerminalView/feedSender``
- ``TerminalView/send(data:)``
- ``TerminalView/pasteText(_:)``
- ``TerminalView/softReset()``
- ``TerminalView/resetToInitialState()``
- ``Terminal/observeOscEvents(_:)``
- ``TerminalOscEvent``
- ``TerminalOscObservation``
- ``LocalProcess``
- ``LocalProcessDelegate``
- ``HeadlessTerminal``
