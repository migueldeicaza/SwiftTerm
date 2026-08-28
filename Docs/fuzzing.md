# Fuzzing SwiftTerm

SwiftTerm has deterministic Ghostty corpus tests and a live libFuzzer target.
The corpus tests reproduce known inputs. The live fuzzer changes inputs to find
new failures.

## Requirements

The live fuzzer needs a Swift 6.2 or later toolchain from swift.org. The
downloadable toolchains provide the `swift` toolchain name that the Makefile
uses by default.

## Replay the Ghostty corpora

Run all 4,001 imported Ghostty inputs through a headless terminal:

```sh
swift test --filter GhosttyFuzzCorpusTests
```

The `run-fuzzer-ghostty` Make target runs the same command:

```sh
make run-fuzzer-ghostty
```

Print the archive and input name before each replay:

```sh
SWIFTTERM_FUZZ_TRACE=1 swift test --filter GhosttyFuzzCorpusTests
```

Run the corpus tests and the fuzz regression tests together:

```sh
swift test --filter GhosttyFuzz
```

The `run-fuzzer-ghostty2` Make target runs the same command.

## Build the live fuzzer

Build the instrumented `SwiftTermFuzz` product:

```sh
make build-fuzzer
```

The build command uses `TOOLCHAINS=swift`. Set a different toolchain name if
necessary:

```sh
make build-fuzzer TOOLCHAINS=my-swift-toolchain
```

## Run the live fuzzer

Create a corpus directory and start libFuzzer:

```sh
mkdir -p /tmp/swifterm-live-corpus

./.build/debug/SwiftTermFuzz \
    /tmp/swifterm-live-corpus \
    -rss_limit_mb=40480
```

Press Control-C to stop the fuzzer.

`make run-fuzzer` starts 12 workers and uses
`../SwiftTermFuzzerCorpus`. Inputs in that directory must use the selector
format in the next section.

## Input format

The first one or two bytes select the target and input method. The remaining
bytes are terminal data or an OSC payload.

| Input bytes | Target |
| --- | --- |
| `00 <terminal data>` | Parser and terminal, one byte at a time |
| `01 00 <terminal data>` | Terminal stream, one slice |
| `01 01 <terminal data>` | Terminal stream, one byte at a time |
| `02 00 <OSC payload>` | OSC terminated by BEL |
| `02 01 <OSC payload>` | OSC terminated by C1 ST |
| `02 02 <OSC payload>` | Unterminated OSC |

The selector operations use modulo arithmetic. For stable seed files, use the
exact byte values in the table.

For example, create a terminal-stream seed:

```sh
printf '\x01\x00Hello\r\n\x1b[31mRed\x1b[0m\r\n' \
    > /tmp/swifterm-live-corpus/basic-stream
```

Then start the fuzzer with that corpus:

```sh
./.build/debug/SwiftTermFuzz /tmp/swifterm-live-corpus
```

The harness creates an 80-column by 24-row terminal with 100 scrollback lines.
It passes the data after the selectors to `Terminal.feed`. The harness does not
open a window or render terminal output.

## Use raw Ghostty seeds

Raw Ghostty corpus files already contain the stream-mode or OSC-terminator
selector. Add one SwiftTerm target byte before each file:

- Add `00` before a parser seed.
- Add `01` before a stream seed. Keep Ghostty's stream-mode byte.
- Add `02` before an OSC seed. Keep Ghostty's terminator byte.

For example, convert one Ghostty stream seed:

```sh
{
    printf '\x01'
    cat ../ghostty/test/fuzz-libghostty/corpus/stream-initial/01-plain-text-slice
} > /tmp/swifterm-live-corpus/ghostty-stream
```

The imported `.stfuzz` files are test archives. Do not pass an entire archive
to libFuzzer as one seed. To refresh the archives from a local Ghostty checkout,
run:

```sh
swift Tools/import-ghostty-fuzz-corpus.swift ../ghostty
```

## Replay a live-fuzzer failure

libFuzzer writes a failure to a file such as `crash-<hash>`. Replay an encoded
failure once with:

```sh
./.build/debug/SwiftTermFuzz -runs=1 crash-file
```

The failure file already contains the SwiftTerm target selector. Do not add a
new selector before replay.
