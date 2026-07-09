# Terminal IO: next steps (Phase 2 — off-main parsing)

Status of Phase 1: `LocalProcess` reads the pty through
`TerminalIOPipeline`, a Swift port of Ghostty's two-stage gather/parse design
(`ghostty/src/termio/Exec.zig`): a gather thread drains the kernel pty queue
into a ring of 4×64 KiB buffers (with spin/poll "bridging" of kernel refill
gaps for saturated streams), and a parse thread delivers batches to the
delegate. Ring-slot availability is the backpressure: ring full → gather stops
reading → kernel pty queue fills → child blocks in `write()`.

Phase 2 Stage A is complete: terminal state is protected by a single terminal
lock, delegate callbacks that need UI work are marshalled to the main thread,
and `MacLocalTerminalView` opts in to off-main parsing with
`LocalProcess(delegate:dispatchQueue:directDelivery: true)`. The default
`LocalProcess` initializer behavior is unchanged: without `directDelivery`,
`dataReceived` is still delivered by synchronously hopping to the provided
dispatch queue.

Remaining Phase 2 work is Stage B: render from deep-copy snapshots so draw no
longer reads live terminal state under the lock. This is Ghostty's full model
(`termio/Termio.zig` `processOutput`, `renderer/generic.zig` `updateFrame`).

## 1. Stage A complete: Terminal lock + parse on the IO thread

- `Terminal` owns `terminalLock`, and `TerminalView.feed` acquires it before
  calling `terminal.feed(buffer:)`/`terminal.feed(text:)`.
- `MacLocalTerminalView` constructs `LocalProcess(delegate: self,
  directDelivery: true)`, so the pipeline parse thread calls
  `dataReceived(slice:)` inline and parsing runs on the IO thread.
- Public `TerminalView.feed` remains background-callable. `withTerminal(_:)`
  is the synchronized accessor for view/client reads and mutations.
- `TerminalViewDelegate` callbacks that touch UI are captured and hopped to
  the main thread; hot callbacks are coalesced through the display path.
- `LocalProcessDelegate.dataReceived` threading contract:
  - default mode (`directDelivery == false`): delivered on the configured
    `dispatchQueue`, preserving existing users and `HeadlessTerminal`;
  - direct mode (`directDelivery == true`): delivered inline on the
    `TerminalIOPipeline` parse thread, with EOF handling still async-hopped
    through the configured queue.

## 2. Stage B remaining: Renderer snapshotting (both renderers)

- Renderers stop reading live terminal state during draw. A snapshot step
  takes the lock briefly and copies out: dirty rows (reuse the existing
  `getUpdateRange`/`scrollInvariantRefreshStart/End` bookkeeping,
  `Terminal.swift:5021+`), cursor position/style, selection, scroll position.
  Release the lock, then build CTLines / vertex buffers from the copy —
  Ghostty's rule: keep the critical section minimal, defer expensive work to
  after unlock (`generic.zig` `updateFrame` vs `endUpdate`).
- CoreGraphics `updateDisplay`/`drawTerminalContents` and the Metal path
  (`queueMetalDisplay`, `Sources/SwiftTerm/Apple/Metal/`) both consume the
  same snapshot type, unifying `queuePendingDisplay`/`queueMetalDisplay`
  into one cadence driver: `CVDisplayLink` on macOS / existing `CADisplayLink`
  on iOS (Ghostty: renderer thread, 8 ms timer, render-vs-draw split).
- The 60 fps `asyncAfter` coalescing in `queuePendingDisplay` is subsumed by
  the display-link cadence; the ≤150 ms `displayImmediately` interactive echo
  fast path becomes "snapshot + draw now" (its `userInputLock` was already
  built for cross-thread reads).

## 3. Synchronized output (DECSET 2026)

Stage A keeps this flag-based (`synchronizedOutputActive` + 1 s safety timer)
and now mutates the flag under the terminal lock. Stage B snapshotting should
skip snapshot updates while the flag is set so renderers keep showing the last
snapshot.

## 4. Public API contract

`LocalProcess.init(delegate:dispatchQueue:directDelivery:)` is the opt-in for
off-main parsing. Existing calls compile unchanged because `directDelivery`
defaults to `false`.

## 5. Optional / later

- Writer-side small-message optimization (Ghostty: ≤38-byte inline messages,
  pooled 64-byte write buffers) if profiling shows allocation pressure in
  `send` — the write path is off the hot path, so only with evidence.
- Consider parsing directly from the ring slot (avoid the copy in the parse
  thread) once delivery no longer needs an `ArraySlice<UInt8>` with delegate
  lifetime — requires the Phase 2 consumer to finish with the slot before
  freeing it, i.e. restores Ghostty's exact ownership model.
- Renderer QoS adaptation (Ghostty: user_interactive focused, utility when
  invisible) once rendering is on its own cadence.
