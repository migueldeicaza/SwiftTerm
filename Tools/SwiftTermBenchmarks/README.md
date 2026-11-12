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

## Ghostty terminal-stream workloads

The opt-in `ghostty_*` cases adapt the input classes from Ghostty commit
`54d162da5bea1d95399574495bde4ddb91df0784`. They measure real terminal
state updates at 120 by 80 cells. Each sample is at least 1 MiB and is fed in
64 KiB chunks. Input generation runs before measurement.

```bash
SWIFTTERM_GHOSTTY_STREAM_BENCHMARKS=1 \
swift package benchmark --target SwiftTermBenchmarks --filter 'ghostty_.*'
```

`ghostty_styled_single` and `ghostty_styled_multi` print the same text at the
same style boundaries and apply the same final style. The single case sends
three one-attribute SGR sequences; the multi case sends one three-attribute
sequence. The other cases cover continuous ASCII, UTF-8, OSC, plain lines,
heavily styled lines, and mixed style, Unicode, and OSC 8 input. `SwiftTermProfile` accepts
each case name.

The streams are deterministic Swift adaptations. Ghostty's exact benchmark
files and its 2.6 GB `out.txt` recording are not in its repository. Compare
results only with SwiftTerm runs of the same case and configuration.

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

## Code layout

A change can make a benchmark slower or faster with the same instruction
count only because functions moved in the binary. The release build does not
emit functions in source order, so code that is added anywhere in a file can
move a hot function. Two effects are known:

- **Start inside a 64-byte line.** The start offset of a hot function, such as
  `parseBorrowed`, changes how many instructions the CPU can fetch in one
  cycle. Build both sides with `-Xswiftc -Xllvm -Xswiftc -align-all-functions=6`
  to remove this effect from a comparison.
- **4 KB alias window.** When `Terminal.cmdCsiM` starts at 3584..4095 mod 4096,
  `dense_cells` is 1-4% slower. The same offset 4 KB or 16 KB higher is slow
  too, so the cause is not the page.

### Fetch-redirect stalls

The CPU front end fetches instructions before it knows the result of the
branches. To do this, it uses predictor tables that it indexes with bits of
the instruction address. An entry tells the front end "at this address there
is a taken branch to that target". When an entry is missing, or another branch
with the same index bits overwrote it, the front end fetches the wrong bytes.
Some cycles later, it finds the taken branch, stops, and restarts the fetch at
the correct target. This is a fetch redirect. During the restart, no
instructions go to the next stage, and the core loses those cycles.

A fetch redirect is not a branch misprediction. The branch direction is
correct, so no executed work is discarded, and the "Discarded" ratio in CPU
Counters does not change. It is also not an instruction cache miss: the
instructions are in the L1I.

Two functions that are 4 KB apart (or a multiple) use the same index bits.
When both have hot branches, they can push out each other's predictor entries.
The 4 KB window above is this effect. Apple does not document the predictor
index, so the partner function of `cmdCsiM` is not known.

Measured on an M3 Ultra, `dense_cells`, with `cmdCsiM` moved into the window
by dead padding:

| Event | Change |
|---|---|
| `MAP_DISPATCH_BUBBLE` | x2.1 (about +1.8% of all cycles) |
| `FETCH_RESTART` | +6..10% |
| `MAP_DISPATCH_BUBBLE_IC`, `MAP_DISPATCH_BUBBLE_ITLB` | noise, below 0.05% of cycles |
| `L1I_CACHE_MISS_DEMAND` | about 35k in 4.4 G cycles in both builds |

Thus, to move cold code out of a hot file does not reduce instruction cache
misses in these benchmarks: the hot code already fits in the L1I. A move only
changes which functions alias.

### Layout report

Before an A/B comparison, examine the code layout of both binaries:

```bash
./layout-report.py A/SwiftTermProfile B/SwiftTermProfile
```

The report shows the address, size and offsets of the hot functions, tells
if the build is aligned, and lists the functions that moved. It also tells if
`Terminal.cmdCsiM` is in the 4 KB alias window. If only one side is in the
window, a `dense_cells` cycles delta with flat instructions is probably
layout, not code. The script only reports. The comment at its top has the
measurements and their limits.

To prove that a delta is layout, add a dead padding function in front of the
moved function on the faster side, so that the function lands at the same
offset as on the slower side:

```swift
@inline(never) @_optimize(none)
public func layoutPadding(_ p: inout Int) {
    p &+= 1
    p &+= 8
    // ... about 16 bytes of code for each line
}
```

If the padded build has the same cost, the cause is the position.

### Front-end counters

The guided CPU Counters mode gives only the bottleneck ratios. To record the
front-end events, make a template in Instruments one time:

1. Select the CPU Counters template.
2. In the recording options, select manual events.
3. Add `CORE_ACTIVE_CYCLE`, `MAP_DISPATCH_BUBBLE`, `MAP_DISPATCH_BUBBLE_IC`,
   `MAP_DISPATCH_BUBBLE_ITLB`, `FETCH_RESTART` and `L1I_CACHE_MISS_DEMAND`.
   Do not add `INST_BRANCH_TAKEN`: it conflicts with this set, and the
   recording fails with "conflicting events".
4. Use File > Save as Template, for example as `FrontEnd Counters`.

Then record and export:

```bash
xcrun xctrace record --template 'FrontEnd Counters' \
    --output /tmp/dense-fe.trace --no-prompt \
    --launch -- .build/release/SwiftTermProfile dense_cells \
    --iterations 300 --warmup 4
xcrun xctrace export --input /tmp/dense-fe.trace \
    --xpath '//table[@schema="counters-profile"]' \
    --output /tmp/dense-fe.xml
```

Each `pmc-events` cell in the export has the counter deltas for one sample,
in the order of the template. Add the cells of the `SwiftTermProfile`
process to get the totals. The event names and descriptions for the CPU are
in `/usr/share/kpep/` (one plist for each CPU family, see `sysctl
hw.cpufamily`).

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
