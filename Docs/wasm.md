# WebAssembly

SwiftTerm has a Foundation-free, headless build for WebAssembly System
Interface (WASI), in two flavors:

- **Full**: the portable core with the full Swift runtime. Select it with the
  `Wasm` package trait and a `*_wasm` SDK. Largest, but places no language
  restrictions on your own code.
- **Embedded**: the same core compiled as Embedded Swift. Select it with the
  `Embedded` and `Wasm` traits together and a `*_wasm-embedded` SDK. About
  nine times smaller; your code must follow Embedded Swift restrictions.

Measured with the bundled smoke program (stripped of debug sections): the full
flavor is about 6.2 MB, the embedded flavor about 0.6 MB.

You need Swift 6.2 or later. For Xcode builds, you need Xcode 26 or later.

## Build

Install a Swift toolchain and a matching WASM SDK. Confirm the SDK name with
`swift sdk list`, then build the library:

```bash
swift build --traits Wasm -c release \
  --swift-sdk swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-08-14-a_wasm \
  --target SwiftTerm
```

To select the trait in another package, add it to the dependency:

```swift
.package(
    url: "https://github.com/migueldeicaza/SwiftTerm.git",
    from: "1.0.0",
    traits: ["Wasm"]
)
```

Then make your target depend on the `SwiftTerm` library product and build with
the WASM SDK.

## Embedded flavor

For the embedded flavor, enable both traits and use the `*_wasm-embedded` SDK
that the same artifactbundle installs:

```bash
swift build --traits Embedded,Wasm -c release \
  --swift-sdk swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-08-14-a_wasm-embedded \
  --target SwiftTerm
```

Your executable target must enable the experimental `Embedded` feature, and
its link needs the Embedded Swift Unicode data tables
(`libswiftUnicodeDataTables.a` inside the SDK bundle) plus the wasm-ld flag
`--allow-multiple-definition`, because Embedded Swift importers re-emit
library code that SwiftPM links again as objects.

## The smoke program and build script

`scripts/build-wasm.sh` builds the bundled WASI smoke program in either
flavor, and handles the embedded link details:

```bash
scripts/build-wasm.sh full --strip --run
scripts/build-wasm.sh embedded --strip --run
```

`--strip` writes a copy without debug and name sections. `--run` executes the
result with the Node.js WASI host. On macOS, set `TOOLCHAINS` to the toolchain
that matches the SDK.

`SWIFTTERM_WASM=1` only adds the smoke product to the package. The traits
select the portable core and its compiler definitions.

## Scope

WASM uses the same portable core API as Embedded Swift. `TerminalData` is
`[UInt8]`; call `Terminal.close()` before release. It includes the parser,
buffers, colors, keyboard encoding, selection, semantic prompts, BiDi state,
and packed cell storage. It excludes UI, PTYs, Dispatch adapters, files,
search, implicit links, image decoding, and Kitty transport.

The output uses WASI. It has no browser DOM or JavaScript bindings.
