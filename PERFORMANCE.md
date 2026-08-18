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
- `--vtebench NAME` — run one of the shared vtebench workloads through the
  real `TerminalView`; use `all` for all 12 cases. `--seconds` is the duration
  for each case.
- `--list-vtebench` — print the available vtebench workload names and exit

For example, run all vtebench workloads through the Metal UI renderer:

```bash
cd Tools/RenderBench
swift build -c release
.build/release/RenderBench --metal --vtebench all --seconds 10
```

This mode uses the same fixed 80-by-25 workloads and samples of at least 1 MiB
as the headless suite. It waits up to two seconds for the final frame
presentation, prints feed and renderer diagnostics for each case, and exits
after the selected cases finish. A presentation timeout is reported as
`settled=timeout` and makes the process exit with status 3.

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

For an analysis outside the Instruments UI, export the Time Profiler table:

```bash
xcrun xctrace export --input /path/to/profile.trace \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
    --output /tmp/time-profile.xml
```

The export uses references to deduplicate frames and complete backtraces. An
XML reader must resolve both `<frame ref=...>` and
`<tagged-backtrace ref=...>`. If the reader resolves only frame references, it
can discard approximately 60% of samples and produce an incorrect call tree.

Check the `record-waiting-threads` setting before you interpret lock costs. A
capture with `record-waiting-threads=0` contains CPU samples from running
threads only. Such a capture cannot measure blocked time or lock contention.

3. In-app measurement
---------------------

For end-to-end numbers over a real PTY, build the sample app in Release
(Debug builds SwiftTerm at `-Onone` and exaggerates Swift-level costs):

```bash
cd TerminalApp
xcodebuild -project MacTerminal.xcodeproj -scheme MacTerminal \
    -configuration Release -derivedDataPath /tmp/dd build
```

Run the fixed-work PTY benchmark from the shell that started the app:

```bash
APP=/tmp/dd/Build/Products/Release/MacTerminal.app/Contents/MacOS/MacTerminal
SWIFTTERM_PROFILE_STATS=1 \
SWIFTTERM_BASELINE=all \
SWIFTTERM_BASELINE_REPEAT=5 \
SWIFTTERM_BASELINE_LABEL=A \
"$APP"
```

`all` runs the 12 shared vtebench workloads. You can also specify one workload
name, such as `unicode`, or a legacy case: `flood`, `bidi`, `tui`, or `binary`.
Each case has one warm-up that is not reported. Each measured repetition emits
one `PTYBENCH` line and one markdown report. Each shared vtebench workload sends
100 MiB, including `unicode`.

The harness disables the normal occlusion pause for the suite. It also activates
the app, moves its window to the front, and waits for AppKit to mark the window
as visible before the warm-up. A result with no frames has `status=no_render`.
The paired driver prints `PTYBENCH_DISCARD` for that result and does not
calculate a delta. The driver fails if a pair has no valid results.

Before each workload, the harness sends RIS and disables focus, bracketed-paste,
and mouse-reporting modes. It also prefixes each shell command with Ctrl-U. This
removes terminal reports that a prior workload put on the shell input line.

Use the paired driver with two checkouts for an A/B test:

```bash
Tools/run-pty-benchmark.py \
    --a-tree /path/to/A --b-tree /path/to/B \
    --pairs 5 --repeat 1 --case all
```

The driver alternates A and B. It rebuilds and relaunches each app. It prints a
`PTYBENCH_DELTA` line for each paired result.

Each `PTYBENCH` line carries the build's Mach-O `uuid=`. Two lines with
different UUIDs come from different builds, which is the same hazard as
measuring a stale binary.

The driver also prints `PTYBENCH_OUTLIER` for a repetition more than 10% from
the median of its case and build across all pairs. A flagged result is a reason
to run the pair again, not a number to drop. **The check needs three or more
measurements for each case and build, so `--pairs 5` matters.** With fewer
pairs the check does nothing and a surprising delta stays unverified.

`SWIFTTERM_BASELINE=quick` and `--case quick` run the five scrolling cases and
`unicode`, about 22 s of benchmark time. Use it for routine A/B work and the
full twelve cases before landing.

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

Choosing the right instrument
-----------------------------

Each level answers a different question. Using the wrong one is the most common
way to get a confident wrong answer.

| Change you are making | Instrument | Metric |
| --- | --- | --- |
| Parser, buffer, or anything per-byte | Headless suite (1) | `p0` wall clock |
| Lock, threading, or *when* work runs | PTY benchmark (3) | `lock_wait_parse_total`, `frame_refresh_p99` |
| Render path | RenderBench (2) | MB/s |

The headless suite sees the whole engine range. RenderBench feeds from
`DispatchQueue.main.async`, so nothing contends for `terminalLock` and it
cannot measure lock work at all. The PTY benchmark is the only level with the
shipping thread topology.

CPU profile reference
---------------------

The detailed analysis is in `docs/io-cpu-profile.md`. The source trace used a
Release build of Tecolot at `new-io` commit `6b51164`. It ran for 63.6 seconds
on macOS 27.0 on a Mac Studio and recorded 51.7 seconds of CPU time. Treat the
results as a case study, not as universal percentages.

### Workload phases

The trace has two different phases:

- During streaming, `swiftterm-io-reader` used approximately 98% of one CPU
  core. The main thread used approximately 10%, and `swiftterm-io-gather` used
  approximately 3%. In this phase, parse cost set the throughput limit.
- During the final glyph storm, CoreAnimation render workers used 8.2 seconds
  of CPU in approximately four seconds of wall-clock time. The workers spent
  most of that time making glyph bitmaps from outlines. The variable font also
  increased the outline extraction cost.

Use the phase data to select the optimization target. Parser changes cannot
remove a glyph-rasterization hitch. Renderer changes cannot increase throughput
when the parse thread saturates one core.

### Parse-thread costs in the source trace

The parse thread used 34,061 ms of CPU. Runtime and row-clear overhead used
71.2% of that time:

| Cost | CPU | Share of parse thread |
| --- | ---: | ---: |
| ARC retain, release, weak, and unowned operations | 14,798 ms | 43.4% |
| Swift exclusivity checks | 3,385 ms | 9.9% |
| Blank-row clear | 5,559 ms | 16.3% |
| Allocation and deallocation | 503 ms | 1.5% |
| **Total** | **24,245 ms** | **71.2%** |

`Terminal.scroll(isWrapped:)` used 15,062 ms inclusive, or 44% of the parse
thread. Its important costs were full-width row clears, selection updates when
no selection was active, and one delegate notification for each scrolled row.

The ARC result had a specific cause. A single `weak` reference gives an object
a side table for the rest of the object's life. On the measured system, a
retain-and-release pair took 3.49 ns with an inline reference count and 32.38 ns
with a side table. `unowned` did not create a side table, but each safe
`unowned` read added an atomic liveness check.

### Measured changes from the profile work

The detailed report records these completed A/B results:

| Change | Relevant result |
| --- | ---: |
| Remove all weak references that gave `Terminal` and `Buffer` side tables | +21.0% scroll-heavy flood; +7.3% wide lines |
| Use lifetime-safe `unowned(unsafe)` parser back-references | approximately +2% flood |
| Use a non-weak selection registry and an active-selection guard | +9.0% scroll-heavy and in-place-scroll cases |
| Clear recycled rows only through their high-water mark | +34% flood; -2.6% 4,000-character lines; no change for in-place scroll |

Do not add these percentages together. The measurements used different
baselines, and absolute performance changed between sessions. Use the results
to select cases for a new paired A/B test.

The high-water-mark result also corrected an earlier assumption. A vectorized
fill did not improve a 5,000-row scrollback ring. The clear was limited by
memory bandwidth. Reducing the number of cleared cells produced the gain.
`CharData` had a 24-byte stride in that analysis, so unnecessary full-row
writes were expensive.

### Remaining profile-led work

The source profile identifies these items for new measurements:

1. Coalesce the per-row `scrolled` callback into one notification for each
   `feed` call.
2. Measure unchecked exclusivity in Release builds, and remove redundant
   `BufferLine.bump()` calls from the scroll path where tests permit the
   change.
3. Cache `GlyphSlotFit` by font, glyph, and column width. The uncached CoreText
   metric queries used 940 ms across the trace.
4. After the cache change, snap `GlyphSlotFit.dx` to the device pixel grid and
   measure glyph rasterization again. Different subpixel phases can create
   different CoreGraphics bitmap-cache entries.

Do not infer lock behavior from this source trace. It excluded waiting threads.
Use the PTY benchmark and its lock statistics for lock and scheduling work.

### The PTY has a transport ceiling of about 290 MiB/s

A Darwin PTY returns 1,024 bytes per `read()` — 819,200 reads for 800 MiB. The
terminal batches them, but the kernel calls remain. Measured on one machine:

| Path | Throughput |
| --- | ---: |
| `cat` to `/dev/null` | ~16,000 MiB/s |
| `cat` through a pipe | ~3,300-3,600 MiB/s |
| `cat` through a PTY | 283-297 MiB/s |
| `light_cells` in the PTY benchmark | 291-298 MiB/s |

The last two agree, so that case measures the PTY and not the engine. The
headless suite runs the same workload at about 1,050 MiB/s, so the transport
hides 3.6x of engine headroom.

**A case is transport-bound when `lock_hold_parse_total / elapsed` falls below
about 90%.** The `PTYBENCH` line prints both fields, so test this per run
instead of remembering which cases are affected. Today `light_cells` (33%) and
`scrolling_fullscreen` are transport-bound and the other ten cases are not, but
each engine improvement moves more cases over the line.

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
- **Size each case so it runs for about three seconds.** Noise scales with how
  short a case is, not with the machine. With one shared 100 MiB budget, two
  runs of the same build differed by 11.4% on `light_cells` (0.36 s) and by
  0.0% on `scrolling_bottom_small_region` (3.54 s). Per-case budgets took the
  median spread from about 2.25% to about 0.29%, or 8x more resolving power,
  for 10 s more suite time. The budgets are calibrated to today's speeds; a
  case that becomes much faster needs a larger one.
- **Calibrate before you trust a null result.** An instrument that cannot see a
  known change produces null results for free. Six consecutive experiments
  measured null before the harness was tested against a change of known size.
  Use a landed change with a recorded number for this.
- **A profile share is not a throughput share.** Removing 9-14 percentage
  points of parse-thread samples produced 3% more throughput. Profile share
  overstates recoverable throughput by three to four times. A 5% line in a
  profile is worth about 1.5% if you delete all of it, so budget before you
  start.
- **Never justify work from an inclusive percentage.** Split self time from
  inclusive time first. One task was specified from a function that showed
  4-5% inclusive but had *zero* self time — all of it was a runtime call
  underneath. The instruction it set out to delete was not what the profile
  measured, so the change could not have worked.
- **Relaunch the app after every build.** macOS keeps a running process on the
  old inode, so a benchmark can silently measure the previous binary. The same
  mistake makes an Instruments trace unsymbolicatable, because the recorded
  image UUID no longer matches anything on disk. Compare the `uuid=` field
  between two `PTYBENCH` lines to detect it.
- **The PTY benchmark needs a visible window.** A locked or sleeping display
  makes every result `status=no_render`, and retrying does not help. A stale
  app instance from an earlier session can hold the key window as well, so end
  leftover `MacTerminal` processes first. When no display is available, use the
  headless suite, which needs no window.
- **What each scenario is sensitive to:** `dense` regresses when per-cell or
  per-run work is added to attribute handling (dictionary copies, bridging,
  color conversion); `scroll` when scroll/feed or full-screen redraw gets
  slower; `arabic` when BiDi paragraph analysis, shaping, or font fallback
  gets slower. A change that only moves `arabic` costs RTL users only; a
  change that moves `dense`/`scroll` costs everyone.
