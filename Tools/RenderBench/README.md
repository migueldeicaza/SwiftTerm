# RenderBench

RenderBench puts a real SwiftTerm terminal view in a macOS window. It feeds
deterministic terminal data without a shell or a PTY.

## Reproduce a stalled Metal renderer

Run this command:

```sh
cd Tools/RenderBench
swift run RenderBench --scenario stalled-frame --seconds 10
```

The scenario uses a debug-only fault. It holds the Metal frame permit before
the first draw. This state models a command buffer whose completion handler did
not release the permit.

The terminal model continues to accept dense, colored output. Each output
update requests a display. Each draw enters the semaphore refusal path and
returns before it creates a command buffer. The pane stays black because no
completion handler can consume `pendingRedraw`.

The process prints the number of accepted updates. The window must remain black
for the full run. A renderer fix must let a later draw present the colored
terminal data without a call to `setUseMetal(false)` and `setUseMetal(true)`.

The `stalled-frame` scenario requires a debug build. Other scenarios also
support release builds.
