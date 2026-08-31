# Embedding SwiftTerm

Notes for applications hosting a terminal view: threading rules, and the
callbacks where a reasonable-looking implementation costs real performance.

## Overview

SwiftTerm does its own frame scheduling. It coalesces terminal changes and
draws at the display's cadence, and on macOS it prepares and draws Metal frames
on a dedicated render thread. Most of that is invisible to a host, but three
things are worth knowing because getting them wrong is measurable.

## Do not animate a window resize from `sizeChanged`

``TerminalViewDelegate/sizeChanged(source:newCols:newRows:)`` fires when the
terminal's cell dimensions change. Applications that snap their window to whole
cells respond by resizing the window — which resizes the terminal, which calls
the delegate again.

That loop settles the moment the frame you set is the frame the terminal
already wants. **It does not settle if you animate the resize.**
`setFrame(_:display:animate:)` with `animate: true` emits a stream of
intermediate frames, each one resizing the terminal and calling back, and each
callback starting another animation.

Measured on a window-resize churn under an 80 MB flood, main-thread stall p99:

| Host's `sizeChanged` | Stall p99 |
| --- | --- |
| Sets the frame without animating | **6–17 ms** |
| Animates the frame change | 14–35 ms |

Roughly 2x, for a resize animation nobody asked for. The same measurement is in
`Docs/io-baselines.md` with the method.

### Guard by comparing, not with a flag

A re-entrancy flag is the natural way to break the loop:

```swift
// Fragile.
func sizeChanged (source: TerminalView, newCols: Int, newRows: Int) {
    if changingSize { return }
    changingSize = true
    window.setFrame(optimal, display: true, animate: true)
    changingSize = false
}
```

This only works while the callback re-enters inside the same call stack.
SwiftTerm does not promise that: during a live window drag the notification is
coalesced to one per display frame, so it arrives *after* the flag is cleared,
and the guard silently stops guarding. Compare frames instead — that works
whether the callback is synchronous or not:

```swift
func sizeChanged (source: TerminalView, newCols: Int, newRows: Int) {
    guard let window = view.window else { return }
    let optimal = terminal.getOptimalFrameSize()
    let target = CGRect(x: window.frame.minX, y: window.frame.minY,
                        width: optimal.width,
                        height: window.frame.height - view.frame.height + optimal.height)
    if abs(target.width - window.frame.width) < 0.5,
       abs(target.height - window.frame.height) < 0.5 { return }
    window.setFrame(target, display: true, animate: false)
}
```

### Why the library cannot simply fix this for you

Coalescing every frame change — not just live drags — would be a small win for
a host that follows the advice above, and costs nothing measurable. For a host
that animates, it is 10x worse, because the deferral is what disarms the
re-entrancy guard. SwiftTerm cannot tell the two apart, so it restricts
coalescing to live resizes and leaves the rest synchronous.

## Feeding and sending from other threads

``TerminalView/feed(byteArray:)`` and ``TerminalView/send(data:)`` are callable
from any thread. A host receiving input on an SSH or agent transport thread can
call `send` directly with no marshalling.

The one rule: do not call them from inside a terminal delegate callback. Those
run with the terminal lock held and these methods take it; a precondition
catches the mistake rather than deadlocking.

Ordering between concurrent callers is the caller's problem. Two threads
sending at once interleave their bytes in the pty, exactly as two processes
writing to one file descriptor would.

## Inspecting contents without mutable terminal access

Use `terminalInputStateSnapshot()` for a cheap copy of dimensions and input
modes. Use `terminalContentSnapshot(region:)` to copy either the viewport or
the live screen plus a bounded number of scrollback rows. Both return `nil`
when no terminal session is attached and are safe to call from any thread,
except inside a callback that already holds the terminal lock.

A content snapshot captures its input state, row coordinates, complete cell
text, widths and attributes in one transaction. Its `capturedRange` uses
scroll-invariant absolute row numbers; it describes only the copied window,
not all retained history. The row text is right-trimmed but retains null cells
and wide-character tails. Hosts choose their own null-cell presentation and
must not derive cell columns from Swift string indices.

## Intercepting local process output

On macOS, `LocalProcessTerminalView.setProcessOutputConsumer(_:)` opts into
owned raw output on the main actor. Install it before starting a process; a
running or winding-down process rejects configuration changes. The consumer
replaces automatic parsing and must either call `feed(byteArray:)` or retain
the bytes in its own bounded buffer before returning. Direct feeds never
re-enter the consumer, so replay can use the same parser without recapturing
itself.

Delivery is synchronous and ordered, with the parse worker supplying
backpressure. Do not wait synchronously for another output batch or process
termination from a consumer. The optional process-output notification runs on
the parse worker after the consumer returns, even if it buffered rather than
parsed the bytes. Without a consumer, background parsing continues to use the
borrowed-byte fast path.

For custom pointer routing, `sendMouseEvent` uses the negotiated terminal
encoding and delivers a response after unlocking. It deliberately bypasses
keyboard semantic-input registration; `send(data:)` is still the API for
keyboard input.

## Delegate callbacks and the terminal lock

Terminal delegate methods can fire on the parse thread with the terminal lock
held. Keep them short, and marshal anything that touches your UI to the main
thread yourself. Reading terminal state inside such a callback is fine — you
already hold the lock — but calling back into SwiftTerm APIs that take it is
not.

## Topics

### Related

- ``TerminalViewDelegate``
- ``TerminalView``
- <doc:GPURendering>
