# Embedded Swift and WebAssembly

Build SwiftTerm's Foundation-free, headless portable core for Embedded Swift
or WebAssembly System Interface (WASI).

## Overview

SwiftTerm's `Embedded` and `Wasm` package traits select the portable core. It
includes terminal parsing, screen buffers, character sets, colors, keyboard
encoding, selection, semantic prompts, BiDi state, and packed cell storage. It
does not include Apple UI, Metal rendering, PTYs or process control,
Dispatch-based adapters, files, search, implicit links, Sixel, iTerm2 decoding,
or Kitty graphics transport. Unsupported graphics sequences are ignored.

| Build | Traits | Runtime |
| --- | --- | --- |
| Embedded Swift | `Embedded` | Embedded Swift |
| WASI | `Wasm` | Full Swift runtime |
| Embedded WASI | `Embedded`, `Wasm` | Embedded Swift |

Swift 6.2 or later is required. Xcode builds require Xcode 26 or later.

## Integration

Select the trait or traits on the dependency in your package manifest:

```swift
.package(
    url: "https://github.com/migueldeicaza/SwiftTerm.git",
    from: "1.0.0",
    traits: ["Embedded"]
)
```

For an Embedded Swift host, also enable the experimental `Embedded` feature on
your own target and build in release mode. The portable API uses `[UInt8]` for
``TerminalData`` rather than Foundation `Data`. Implement
``TerminalDelegate/send(source:data:)`` to receive terminal replies. For
synchronized output, schedule the callback requested by
``TerminalDelegate/scheduleSynchronizedOutputTimeout(source:afterMilliseconds:)``
and call ``Terminal/expireSynchronizedOutput()`` when it fires. Embedded Swift
uses strong links where host builds use weak or unowned links, so call
``Terminal/close()`` before releasing an embedded terminal to break those
cycles.

For WASI, use a matching WASM SDK. `Wasm` produces a full-runtime binary;
combining it with `Embedded` produces an Embedded Swift binary. The latter
needs the Embedded Swift Unicode data tables and the `wasm-ld`
`--allow-multiple-definition` flag when linking an executable.

For complete build commands and host-integration requirements, see the
[Embedded Swift guide](https://github.com/migueldeicaza/SwiftTerm/blob/main/Docs/embedded-swift.md)
and the
[WebAssembly guide](https://github.com/migueldeicaza/SwiftTerm/blob/main/Docs/wasm.md).
