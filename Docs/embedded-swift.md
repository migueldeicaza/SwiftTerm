# Embedded Swift

SwiftTerm has a Foundation-free, headless core for Embedded Swift. Select this
core with the `Embedded` package trait.

You need Swift 6.2 or later. For Xcode builds, you need Xcode 26 or later.

## Build

Use a Swift development snapshot with the Embedded Swift standard library:

```bash
swift build --traits Embedded -c release --target SwiftTerm \
  --triple arm64-apple-macosx14.0
```

Add the target triple, SDK, C headers, allocator, and linker settings required
by the board or RTOS. The Swift Embedded documentation describes these settings.
For a macOS build, the triple must specify macOS 14 or later because the
snapshot Embedded Swift standard library requires it.

To select the trait in another package, add it to the dependency:

```swift
.package(
    url: "https://github.com/migueldeicaza/SwiftTerm.git",
    from: "1.0.0",
    traits: ["Embedded"]
)
```

Then make your target depend on the `SwiftTerm` library product.
An Embedded Swift target that imports SwiftTerm must also enable the
experimental `Embedded` feature in its own target settings. Build it in release
mode so SwiftPM uses whole-module optimization. For a macOS build, also pass
`--triple arm64-apple-macosx14.0` (or later); the snapshot Embedded Swift
standard library is not available for earlier deployment targets.

Maintainers can run the host-standard-library portability check and core tests
with this command:

```bash
SWIFTTERM_EMBEDDED_CHECK=1 swift test -c release \
  --filter SwiftTermEmbeddedTests
```

`SWIFTTERM_EMBEDDED_CHECK` is test tooling for this package. Consumers must use
the `Embedded` trait. The check does not replace a true Embedded Swift build.

## Scope

The portable core includes the parser, screen buffers, character sets, colors,
keyboard encoding, selection, semantic prompts, BiDi state, and packed cell
storage. `TerminalData` is `[UInt8]` in this mode.

It excludes Apple UI and Metal code, PTYs and process control, Dispatch-based
adapters, files, search, implicit link detection, Sixel, iTerm2 decoding, and
Kitty graphics transport. Unsupported graphics sequences are ignored. The LAB
palette falls back to the xterm palette.

## Integration

Implement `TerminalDelegate.send(source:data:)` for terminal replies. For
synchronized output, implement
`scheduleSynchronizedOutputTimeout(source:afterMilliseconds:)`, then call
`Terminal.expireSynchronizedOutput()` when the timer fires.

Embedded Swift uses strong links where host builds use weak or unowned links.
Call `Terminal.close()` before releasing an embedded terminal to break these
cycles.
