# Source of truth

This fork (`jiaomeimei0-prog/SwiftTerm`) is the **only** place to edit terminal
emulator features and security patches.

| Work | Repository |
|------|------------|
| Parser, buffers, OSC/CSI, clipboard, Kitty, render, hardening, HostHelpers | **This repo** |
| Host app UI, `ios_system`, Relay, Xcode/CI | `jiaomeimei0-prog/a-shell` |

### a-Shell command execution on iOS

iOS does not allow App Store apps to `fork`/`exec` real Unix child processes.
a-Shell runs commands **inside the app sandbox**:

1. **`ios_system`** (`ios_fork` + `ios_system`) — in-process session/streams for
   native embedded commands from the host catalogue.
2. **WebAssembly** — user/`pkg` WASI binaries via the in-app WASM runtime and
   loopback `wasm.html` HTTPS server; not a substitute for every native command.

SwiftTerm only owns the terminal emulator UI/API; command dispatch stays in a-Shell.

## a-Shell package pin

a-Shell keeps a **SwiftTerm git submodule** for Xcode
(`relativePath = SwiftTerm`). That submodule must point at **this fork**
(`jiaomeimei0-prog/SwiftTerm`), not `holzschu/SwiftTerm`. Treat the nested
checkout as a read-only pin of fork v2.

## Five original host capabilities (must remain on fork v2)

1. Prompt / line-editor bookkeeping  
2. Cursor control  
3. Selection editing  
4. Display / style helpers  
5. Terminal / buffer access (+ `feed` I/O used by a-Shell)

See `AppleTerminalView+HostHelpers.swift` and `Apps/README.md`.
