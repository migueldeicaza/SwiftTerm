Performance testing
===================

SwiftTerm has three levels of performance measurement, from fastest to most
realistic:

1. **Headless feed benchmarks** — measure the terminal-emulation engine
   (parser + buffer) with no rendering. These benchmarks use the 12 default
   vtebench workloads, ported to deterministic Swift byte generators.
2. **RenderBench** — a deterministic harness that drives the real
   `TerminalView` render path with synthetic workloads. This is the primary
   tool for render-path work and for Instruments profiling.
3. **In-app measurement** — vtebench or timed `cat` runs typed into the
   MacTerminal sample app, over a real PTY and shell.

When comparing two revisions, build the second revision in a git worktree so
both binaries exist at once:

```bash
git worktree add /tmp/swiftterm-main main
# ... build the same harness in both checkouts, run them back to back ...
git worktree remove --force /tmp/swiftterm-main
```

1. Headless feed benchmarks
---------------------------

The benchmark suite is a nested package in `Tools/SwiftTermBenchmarks`. Keeping
it outside the root package preserves SwiftTerm's macOS 11 deployment target;
the benchmark framework requires macOS 13. It feeds fixed 80-by-25 vtebench
workloads into `HeadlessTerminal`. Each measured sample is at least 1 MiB.

```bash
cd Tools/SwiftTermBenchmarks
swift package benchmark --target SwiftTermBenchmarks
```

The reset and setup streams are outside the measured interval. The measured
interval contains only `Terminal.feed(byteArray:)`. Run the port validation
tests with `swift test` from the same directory.

The suite contains these vtebench cases:

- `cursor_motion`, `dense_cells`, `light_cells`, and `medium_cells`
- `scrolling` and four scrolling-region variants
- `scrolling_fullscreen`, `sync_medium_cells`, and `unicode`

The older manually timed cases remain in
`Tests/SwiftTermTests/PerformanceTest.swift` for focused experiments. Use the
nested benchmark package for repeatable A/B measurements.

2. RenderBench (render path, Instruments)
-----------------------------------------

`Tools/RenderBench` is a small SPM executable that hosts a real
`TerminalView` in an on-screen window and feeds it synthetic frames as fast
as the main run loop accepts them — no PTY, no shell, byte-identical input on
every run (fixed seed), so two builds are directly comparable.

```bash
cd Tools/RenderBench
swift build -c release
.build/release/RenderBench --seconds 10 --scenario dense
```

It prints MB/s and frames/s every second and a `TOTAL` line at the end.

Options:

- `--scenario dense` — every cell gets its own truecolor foreground and
  background (vtebench dense_cells shape; stresses attribute handling, run
  fragmentation, and color conversion)
- `--scenario medium` — a color change every 8 cells (longer runs)
- `--scenario scroll` — plain scrolling ASCII (parser + scroll + full-screen
  redraw)
- `--scenario arabic` — scrolling Arabic words (BiDi paragraph analysis,
  shaping, font fallback)
- `--seconds N` — run duration (default 15)
- `--metal` — use the Metal renderer instead of CoreGraphics

The package pins its dependency identity (`.package(name: "SwiftTerm",
path: "../..")`), so it also builds inside a worktree whose directory is not
named `SwiftTerm` — copy `Tools/RenderBench` into the worktree if the
revision under test predates it.

### Profiling with Instruments

```bash
cd Tools/RenderBench
swift build -c release
xcrun xctrace record --template 'Time Profiler' --output ~/dense.trace \
    --launch -- .build/release/RenderBench --seconds 20 --scenario dense
open ~/dense.trace
```

Each `feed` call is wrapped in an os_signpost (subsystem
`org.tirania.SwiftTerm`, category `RenderBench`), so adding the os_signpost
instrument splits main-thread time between the feed/parse side and the
AppKit draw cycles. For A/B analysis, record the same scenario from both
checkouts and diff the heaviest stacks under `buildAttributedString` and the
draw loop.

3. In-app measurement
---------------------

For end-to-end numbers over a real PTY, build the sample app in Release
(Debug builds SwiftTerm at `-Onone` and exaggerates Swift-level costs):

```bash
cd TerminalApp
xcodebuild -project MacTerminal.xcodeproj -scheme MacTerminal \
    -configuration Release -derivedDataPath /tmp/dd build
```

Then, inside the running terminal window, run vtebench:

```bash
vtebench -b benchmarks/dense_cells --max-secs 6 --dat /tmp/results.dat
```

The `.dat` file has one column per benchmark with per-sample times in ms;
more samples completed in the fixed time budget = faster. The app defaults
to the CoreGraphics renderer; flip `setUseMetal(false)` to `true` in
`TerminalApp/MacTerminal/ViewController.swift` to measure Metal (and revert
afterwards). Keep the window size identical between runs — cols × rows
changes the per-frame workload.

Methodology notes
-----------------

- **Pair your A/B runs.** Absolute numbers drift between sessions (thermal
  state, display state, background load). Run main and the branch back to
  back in the same block, and re-run any surprising result before believing
  it — a transient machine state can halve one configuration's numbers for
  minutes at a time while others look normal.
- **Interpret cat/PTY timings carefully.** `time cat file` inside a terminal
  measures how fast the terminal drains the PTY; payloads under a few MB fit
  in kernel buffering and undercount. Use payloads of 10 MB+.
- **vtebench sample distributions are bimodal** (fast PTY-buffered samples
  next to render-synced ones); compare sample counts and means, not medians,
  and treat differences under ~10% as noise.
- **What each scenario is sensitive to:** `dense` regresses when per-cell or
  per-run work is added to attribute handling (dictionary copies, bridging,
  color conversion); `scroll` when scroll/feed or full-screen redraw gets
  slower; `arabic` when BiDi paragraph analysis, shaping, or font fallback
  gets slower. A change that only moves `arabic` costs RTL users only; a
  change that moves `dense`/`scroll` costs everyone.
