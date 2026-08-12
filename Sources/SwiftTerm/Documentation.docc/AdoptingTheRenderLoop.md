# Adopting the render loop

What changes for an application moving to the branch where SwiftTerm prepares
and draws frames off the main thread.

## Overview

On macOS, a terminal using the GPU renderer now prepares and submits its frames
on a dedicated render thread, driven by the display link. The main thread
captures view state, signals the loop, and applies the AppKit side effects the
loop hands back. Main-thread stall p99 under a flood drops from roughly 7–19 ms
to 0.03–0.12 ms.

**No API was removed and nothing became illegal.** Most applications need to
change nothing. The list below is what is worth checking, in the order it is
likely to matter.

## 1. `setNeedsDisplay` does not force a terminal repaint

If your code calls `setNeedsDisplay` on the terminal view to refresh it after
changing terminal state directly — a soft reset, a palette swap, a renderer
toggle — **that call does nothing.** `TerminalView.draw(_:)` returns
immediately whenever a GPU renderer is attached, and frames come from the frame
driver instead.

This was already true whenever Metal was enabled. It matters more now because
Metal is the default on macOS.

```swift
// Before: silently does nothing under a GPU renderer.
terminal.getTerminal().softReset()
terminal.setNeedsDisplay(terminal.bounds)

// After:
terminal.getTerminal().softReset()
terminal.requestRedraw()
```

``TerminalView/requestRedraw()`` is safe from any thread. Output fed through
``TerminalView/feed(byteArray:)`` never needs it — that path marks the frame
itself.

## 2. Metal is on by default, on a new surface

``TerminalView/setUseMetal(_:)`` is unchanged. What changed is what you get:
a `CAMetalLayer` this view owns, drawn from the render loop, rather than an
`MTKView` drawn from AppKit's display cycle.

- ``TerminalView/usesMetalLayerSurface`` and
  ``TerminalView/setUsesMetalLayerSurface(_:)`` select the surface at runtime.
  Setting it while Metal is running rebuilds the surface in place.
- ``TerminalView/isUsingRenderLoop`` reports whether frames are actually being
  prepared off the main thread.
- `SWIFTTERM_METAL_LAYER=0` in the environment starts on the old `MTKView`
  surface. That is the rollback if you hit something; please report it.

`MTKView` remains the only surface on iOS.

## 3. You can call `send` and `feed` from any thread

``TerminalView/send(data:)`` used to assert it was on the main thread. It no
longer does: it takes the terminal lock around the state it mutates. An SSH or
agent transport can call it directly.

If you marshal input to the main thread only to satisfy that old contract, you
can stop.

The one rule: do not call it from inside a terminal delegate callback. Those
run with the lock held, and a precondition catches the mistake rather than
deadlocking.

## 4. `sizeChanged` may arrive a frame later than the resize

During a live window drag, SwiftTerm coalesces resizes to one per display
frame. Your ``TerminalViewDelegate/sizeChanged(source:newCols:newRows:)`` is
therefore called after the drag step that caused it, not inside it.

That breaks the re-entrancy guard applications write when they resize a window
from this callback:

```swift
// Fragile: `changingSize` is already false when the callback arrives.
if changingSize { return }
changingSize = true
window.setFrame(optimal, display: true, animate: true)
changingSize = false
```

Compare frames instead of using a flag, and do not animate the resize —
animating it is a measurable performance problem in its own right. <doc:Embedding>
has the numbers and a correct implementation.

Applications that do not resize a window from `sizeChanged` — anything with a
fixed layout, or SwiftUI-driven sizing — are unaffected.

## 5. Delegate callbacks and your own threads

Unchanged, but easier to get wrong now that more of SwiftTerm is concurrent:
terminal delegate methods can fire on the parse thread with the terminal lock
held. Capture what you need and hop to the main queue yourself. Do not call
back into SwiftTerm APIs that take the lock.

## 6. What you get for free

No action needed for any of these:

- Frames continue while the main thread is busy.
- Input-to-glyph latency roughly halved; the old 150 ms post-input special case
  is gone.
- The terminal stops drawing entirely when occluded, miniaturised, or the
  application is hidden.
- The synchronized-output safety valve fires even while the main thread is
  blocked, so an application that sets DECSET 2026 and never clears it can no
  longer wedge the display.

## Topics

### Related

- <doc:Embedding>
- <doc:GPURendering>
- ``TerminalView/requestRedraw()``
- ``TerminalView/setUsesMetalLayerSurface(_:)``
