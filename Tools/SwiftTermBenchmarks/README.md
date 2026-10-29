# SwiftTerm benchmarks

This nested Swift package measures `HeadlessTerminal` with the 12 default
[vtebench](https://github.com/alacritty/vtebench) workloads. The generators use
a fixed 80-column by 25-row terminal. Each measured sample contains at least
1 MiB and repeats only complete workload payloads, as vtebench does.

The reset and setup streams run before measurement. The measured region
contains only calls to `Terminal.feed(byteArray:)`.

Run all benchmarks in a Release build:

```bash
cd Tools/SwiftTermBenchmarks
swift package benchmark --target SwiftTermBenchmarks
```

List the benchmark command options:

```bash
swift package benchmark help
```

Run the workload-port tests:

```bash
swift test
```

## Kitty image snapshots

The `kitty_snapshot_empty` and `kitty_snapshot_3mb` cases measure snapshot
creation. Image upload and terminal setup run before measurement. Each sample
contains 1,000 snapshot calls to reduce clock resolution error. Divide raw
sample times by 1,000 to calculate time per call.

Regenerate these two baselines after this batching change. Older baselines
measure one call per sample, so their raw times cannot be compared directly.

## Headless Instruments profiling

Build the direct profiling executable once, then launch the binary under
Instruments. The measured loop uses fixed work and has no UI, PTY, benchmark
controller, or build process:

```bash
swift build -c release --product SwiftTermProfile
xcrun xctrace record --template 'Time Profiler' --output /tmp/medium.trace \
    --launch -- .build/release/SwiftTermProfile medium_cells --iterations 800
```

Use the same iteration count for both revisions. The executable prints total
bytes, elapsed time, and MiB/s when it exits.

Export and summarize the CPU table with:

```bash
xcrun xctrace export --input /tmp/medium.trace \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
    --output /tmp/medium-time-profile.xml
./analyze-time-profile.py /tmp/medium-time-profile.xml --root Terminal.feed
```

The summarizer resolves deduplicated frame, backtrace, and sample-weight
references before it calculates self and inclusive time.

To attribute a function to its immediate callers, add `--callers-of`:

```bash
./analyze-time-profile.py /tmp/medium-time-profile.xml \
    --root Terminal.feed --callers-of repairWideSeam
```

The CPU Counters template also runs without a UI:

```bash
xcrun xctrace record --template 'CPU Counters' \
    --output /tmp/medium-counters.trace --no-prompt \
    --launch -- .build/release/SwiftTermProfile medium_cells \
    --iterations 500 --warmup 4
xcrun xctrace export --input /tmp/medium-counters.trace \
    --xpath '//table[@schema="MetricTable"]' \
    --output /tmp/medium-counter-metrics.xml
./analyze-cpu-counters.py /tmp/medium-counter-metrics.xml
```

The analyzer reports total cycles and duration-weighted bottleneck ratios from
the guided CPU Counters mode. Xcode 27 does not expose a command-line catalog
of manual hardware event names, so use only event configurations that the
installed Instruments package verifies.

To count seam checks and completed repairs exactly, build a counter-enabled
binary. Use this binary for event frequency only; the counter lock changes
throughput:

```bash
swift build -c release --product SwiftTermProfile \
    -Xswiftc -DSWIFTTERM_SEAM_COUNTER
.build/release/SwiftTermProfile medium_cells --iterations 1 --warmup 1
.build/release/SwiftTermProfile unicode --iterations 1 --warmup 1
.build/release/SwiftTermProfile hardening_wide_seam_overwrite_edit \
    --iterations 1 --warmup 1
```

Rebuild without `-DSWIFTTERM_SEAM_COUNTER` before measuring throughput.

## Hardening workloads

The benchmark executable also includes focused hardening workloads. They test
ASCII and wide-character seams, horizontal margins, bounded OSC input, and
short title OSC commands. The short OSC cases use whole input and one-byte
chunks to detect prefix and per-feed costs.
They are separate from the 12 vtebench workloads. This keeps the default
vtebench set and external `all` selections unchanged.

Run the focused cases with:

```bash
SWIFTTERM_HARDENING_BENCHMARKS=1 \
swift package benchmark --target SwiftTermBenchmarks --filter 'hardening_.*'
```

## OSC 8 hyperlink workloads

Ten opt-in cases measure OSC 8 links. No vtebench workload sends OSC 8, so
the default suite does not run the hyperlink code. Run the cases with:

```bash
SWIFTTERM_OSC8_BENCHMARKS=1 \
swift package benchmark --target SwiftTermBenchmarks --filter 'osc8_.*'
```

The filter is a regular expression that must match the whole name.
`--filter osc8_` selects no case.

| Case | Work |
| --- | --- |
| `osc8_parse_implicit` | Link start `8;;URI` and link end `8;;`, with `BEL`, and no text |
| `osc8_parse_explicit` | The same with `8;id=bench;URI` |
| `osc8_parse_long_uri` | The same with a URI of 1,020 bytes |
| `osc8_stream` | `linked text` in a link, then `CR LF`, so the screen scrolls |
| `osc8_stream_plain` | The same text and line endings without a link (control) |
| `osc8_cell_churn` | One link written again to every cell of the screen |
| `osc8_redraw_same` | A full-screen redraw, as tmux sends it, with the same 10 links |
| `osc8_distinct_lines` | A new link on each line; the lines scroll into scrollback |
| `osc8_dense` | A new link in each cell; 60,000 links in one payload |
| `osc8_lookup` | Read the link of each of the 2,000 cells (one pass for each iteration) |

The first six cases follow the `osc-parser`, `terminal-stream`, and
`hyperlink-map` benchmarks in Ghostty. These differences apply:

- SwiftTerm has no separate OSC body parser. The `osc8_parse_*` cases feed
  complete sequences through the VT parser. They measure the VT parser, not
  an OSC body parser. The bytes load before the timed region.
- SwiftTerm keeps the link code in the cell, and has no cell-to-link map.
  `osc8_lookup` uses `getCharData(col:row:)` and `getPayload()`, and
  `osc8_cell_churn` overwrites cells with the same link. The `entries` and
  `load-percent` parameters of Ghostty do not apply.
- The terminal is 80 by 25 with 500 lines of scrollback, not 120 by 80.

`osc8_redraw_same`, `osc8_distinct_lines`, and `osc8_dense` test link reuse and
link release. The links in `osc8_distinct_lines` and `osc8_dense` are more than
the screen and scrollback keep, so a repeated sample does not find them in use.
A run makes more than 65,534 links, which is the limit of link codes.

After each case, the benchmark checks that the last link of the payload
resolves and that the link is closed. A terminal that runs out of link codes
prints text without its link and is faster. The check stops the run in that
condition. Revisions before the OSC 8 atom reuse change fail this check, so
compare these cases only with revisions that include the change.

`SwiftTermProfile` also runs the `osc8_*` feed cases and does the same link
check. `osc8_lookup` is available only in the benchmark package.

Run the same workloads through an on-screen `TerminalView` with `RenderBench`:

```bash
cd ../RenderBench
swift build -c release
.build/release/RenderBench --metal --vtebench all --seconds 10
```

Use `--vtebench NAME` to run one case. The UI runner waits for the final frame,
prints renderer diagnostics, and exits when the run is complete.

The `medium_cells` and `sync_medium_cells` resources are captured Vim sessions
from vtebench. The remaining payloads are Swift ports of the vtebench workload
generators.

## Design credit

SwiftTerm's I/O pipeline, packed-cell storage, and Metal renderer design were
inspired by [Ghostty](https://ghostty.org), the terminal emulator project
started by [Mitchell Hashimoto](https://mitchellh.com). The SwiftTerm
implementations are independent Swift adaptations for this codebase.

## vtebench credit and license

This package uses work from
[alacritty/vtebench](https://github.com/alacritty/vtebench), written by
Christian Duerr, Joe Wilm, and other vtebench contributors. The port is based
on revision `ead80032e57dee2e75f0b51f2ea67528647d9944`.

vtebench is available under the MIT license or the Apache License 2.0. See
`LICENSE`, `VTEBENCH-NOTICE.md`, and `Licenses/` for details and full license
texts.
