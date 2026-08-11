# Terminal IO: next steps

Phase 2 Stages A and B are complete.

Stage A moved terminal parsing to the IO thread. `TerminalIOPipeline` gathers
PTY data into bounded ring buffers, and `Terminal` protects live state with
`terminalLock`. `MacLocalTerminalView` uses direct delivery so parsing does not
need a synchronous main-thread hop.

Stage B separated terminal mutation from rendering. `TerminalSnapshot` copies
the visible state during a short lock hold. Core Graphics and Metal then shape,
cache, and draw from the snapshot without the terminal lock. `FrameDriver`
coalesces parse-thread changes, submits frames at the display cadence, pauses
after eight idle ticks, and preserves the 150 ms interactive-input fast path.
Synchronized output keeps the last completed snapshot visible until output is
unfrozen.

## Future work

- Move Metal encoding off the main thread after snapshot publication uses a
  double buffer with explicit ownership between the producer and renderer.
- Split render preparation from draw submission in the Ghostty model. This can
  make frame preparation independent of the platform display callback.
- Consider direct parsing from ring slots if profiling shows that the current
  batch copy is material. This change needs an explicit slot-lifetime contract.
- Consider writer-side small-message storage and renderer QoS changes only when
  measurements show a need.

The public `LocalProcess.init(delegate:dispatchQueue:directDelivery:)` contract
does not change. Direct delivery remains opt-in.
