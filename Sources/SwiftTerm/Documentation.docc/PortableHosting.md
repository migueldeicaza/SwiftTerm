# Building a Portable Terminal Host

Render and drive a ``Terminal`` without an AppKit or UIKit view.

## Overview

The portable APIs let a host own rendering, input routing, selection, and
scrollback while SwiftTerm continues to own terminal parsing and state. They
are useful for a custom native renderer and are the core APIs behind the WASM
browser package.

The host has two directions of data flow:

1. Feed output received from a process or remote peer into the terminal.
2. Send bytes produced by user input and terminal replies back to that peer.

Install a ``TerminalDelegate`` to receive the second direction, then create a
snapshot after each state change. The delegate callback runs while the terminal
lock is held, so it should enqueue the bytes and return rather than calling
back into the terminal.

```swift
final class Host: TerminalDelegate {
    var outbound: [[UInt8]] = []

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        outbound.append(Array(data)) // Drain this from the transport queue.
    }
}

let host = Host() // Keep the delegate alive on native builds.
let terminal = Terminal(delegate: host, options: .default)
terminal.terminalLock.withLock {
    terminal.feed(text: "Hello, terminal!\\r\\n") // Output from the peer.
}

let frame = terminal.makeRenderSnapshot(scope: .dirty)
draw(frame)
terminal.terminalLock.withLock {
    terminal.clearUpdateRange() // Only after every row in `frame` was drawn.
}
```

``TerminalRenderSnapshot`` is an owned copy. It is safe to render after
``Terminal/makeRenderSnapshot(scope:)`` returns and does not expose mutable
buffer lines or cells. A `.full` snapshot includes the complete viewport. A
`.dirty` snapshot can be `.clean`, `.partial`, or `.full`; draw every row in
``TerminalRenderSnapshot/lines`` when it is not clean. The normal dirty range
uses viewport rows, while the scroll-invariant range uses buffer rows.

For a direct native host, serialize its feed, input, render, and damage-clear
operations with the terminal lock (or a single host executor). Do not clear
damage before a frame is successfully drawn. If drawing is asynchronous, clear
its damage only when no newer terminal change needs the same range. The WASM
wrapper's generation acknowledgement provides that stronger stale-frame
protection for browser hosts.

## Rendering cells

``RenderSnapshotCell/text`` contains a complete grapheme cluster. Its width
and ``RenderSnapshotCell/widthState`` identify wide cells and their
continuations; do not render a width-zero continuation as an independent
glyph. ``RenderSnapshotRow/renderMode`` describes double-width and double-height
DEC line modes. The snapshot retains semantic attributes and colors so that a
renderer can apply its own font and drawing system.

``TerminalRenderSnapshot`` colors are RGB components, not platform color
objects. Apply ``TerminalRenderSnapshot/reverseVideo`` at the host level.
``TerminalRenderSnapshot/synchronizedOutputActive`` asks the host to defer
displaying an intermediate frame until synchronized output ends or times out.

For Kitty graphics, take a separate ``KittyGraphicsRenderSnapshot`` and follow
<doc:KittyGraphicsIntegration>. Sixel and iTerm images use the image callbacks
on ``TerminalDelegate`` for a direct native host. The Full WASM build instead
exports copied graphics snapshots; see the repository's
[WebAssembly guide](https://github.com/migueldeicaza/SwiftTerm/blob/main/Docs/wasm.md).

## Keyboard, paste, and pointer input

Use ``Terminal/sendHostKey(key:code:modifiers:eventType:text:shiftedKey:baseLayoutKey:)``
for physical keys, ``Terminal/sendHostText(_:)`` for committed text (including
IME results), and ``Terminal/sendHostTextPaste(_:allowUnsafe:)`` for paste.
Committed text follows the active keyboard modes; paste separately follows the
terminal's bracketed-paste and safety rules. Do not feed local input through
the output parser.

Use ``Terminal/sendHostMouse(action:button:modifiers:col:row:pixelX:pixelY:)``
for mouse reporting. Coordinates are zero-based and relative to the visible
viewport. Pixel positions are logical pixels, not device pixels. The return
value is false when the active terminal tracking mode filters the event.
``Terminal/hostPointerModes`` exposes the active tracking and encoding modes
so a host can choose between application mouse input, local selection, and
scrollback.

## Selection and scrollback

Create one ``SelectionService`` for the terminal. Use
``Terminal/updateSelection(_:action:column:row:mode:)`` to begin, extend,
clear, or select all; then render the visible spans from
``Terminal/selectionState(_:)`` as an overlay. Span end columns are exclusive.
``Terminal/selectionText(_:)`` extracts selected content, including selected
history and soft wraps.

``Terminal/viewportState()`` reports the current and maximum buffer-relative
top row. ``Terminal/scrollViewport(_:absolute:)`` scrolls by lines, or to an
absolute buffer row when `absolute` is true. Positive relative values scroll
down. Resizing, a buffer switch, reset, or changed selected content can clear a
selection; refresh the selection overlay after those operations.

## WebAssembly

The `Web/` TypeScript package is the supported browser and Node.js façade. It
copies frames and queues generated bytes across its ABI, so JavaScript hosts do
not need to call these Swift APIs directly. See the
[WebAssembly guide](https://github.com/migueldeicaza/SwiftTerm/blob/main/Docs/wasm.md)
and the [package README](https://github.com/migueldeicaza/SwiftTerm/blob/main/Web/README.md)
for build instructions, lifecycle rules, and a Canvas example.

## Topics

### Rendering

- ``Terminal/makeRenderSnapshot(scope:)``
- ``TerminalRenderSnapshot``
- ``RenderSnapshotScope``
- ``RenderSnapshotCell``
- ``RenderSnapshotRow``
- ``RenderSnapshotCursor``

### Host Input

- ``Terminal/sendHostKey(key:code:modifiers:eventType:text:shiftedKey:baseLayoutKey:)``
- ``Terminal/sendHostText(_:)``
- ``Terminal/sendHostTextPaste(_:allowUnsafe:)``
- ``Terminal/sendHostMouse(action:button:modifiers:col:row:pixelX:pixelY:)``
- ``TerminalMouseAction``
- ``TerminalMouseButton``
- ``Terminal/hostInputModes``
- ``Terminal/hostPointerModes``

### Viewport and Selection

- ``Terminal/viewportState()``
- ``Terminal/scrollViewport(_:absolute:)``
- ``Terminal/updateSelection(_:action:column:row:mode:)``
- ``Terminal/selectionState(_:)``
- ``Terminal/selectionText(_:)``
- ``TerminalViewportState``
- ``TerminalSelectionState``
- ``TerminalSelectionSpan``
