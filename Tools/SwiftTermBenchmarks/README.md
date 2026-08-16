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
