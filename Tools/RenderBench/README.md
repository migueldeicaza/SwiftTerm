# RenderBench

RenderBench drives a real, on-screen SwiftTerm `TerminalView` without a PTY or
shell. It measures the combined parser, buffer, invalidation, and UI render
path. The process exits automatically when the selected run is complete.

Build the Release executable before you collect results:

```bash
swift build -c release
```

Run one of the original synthetic scenarios:

```bash
.build/release/RenderBench --scenario dense --seconds 10
```

Add `--metal` to use the Metal renderer. Without it, RenderBench uses Core
Graphics.

## Shared vtebench workloads

List the available workloads:

```bash
.build/release/RenderBench --list-vtebench
```

Run one workload for 10 seconds:

```bash
.build/release/RenderBench --metal --vtebench dense_cells --seconds 10
```

Run all 12 workloads for 10 seconds each:

```bash
.build/release/RenderBench --metal --vtebench all --seconds 10
```

The UI mode imports the same `VTEBenchWorkloads` library as the headless
benchmark package. It uses an 80-column by 25-row terminal and repeats complete
payloads to produce samples of at least 1 MiB. Reset and setup data are outside
the measured interval.

After input stops, RenderBench waits up to two seconds for the final Core
Graphics or Metal frame presentation. Each `VTEBENCH` result line reports input
throughput, feed count, measured and final frame counts, measured render rate,
display ticks, coalescing, idle ticks, and main-queue hops. The tool then
advances to the next case or terminates. A presentation timeout produces
`settled=timeout` and exit status 3.

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
