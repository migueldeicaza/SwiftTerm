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
the first draw. This state models a frame gate that has no valid owner.

The terminal model continues to accept dense, colored output. The first pane
is black. After about one second, SwiftTerm replaces the failed renderer and
presents a colored frame.

The process prints `RECOVERED` only if the renderer becomes healthy, a drawable
is presented, and Metal remains enabled. It exits with a nonzero status if a
condition fails. Recovery does not call `setUseMetal(false)` or
`setUseMetal(true)`.

The `stalled-frame` scenario requires a debug build. Other scenarios also
support release builds.
