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

**Prescribed UI↔command backend for a-Shell:** `TerminalViewDelegate`
`send`/`feed` over Foundation `Pipe` + `ios_system` (not `LocalProcess`).
See [`Docs/host-ui-backend.md`](host-ui-backend.md).

**Prescribed UI backend for Web on Windows:** WASM package (`write` /
`readOutput` / `snapshot`) + host Canvas/input; shell via WebSocket to
PTY/SSH (WSL or remote). Not a-Shell’s command catalogue.
See [`Docs/host-ui-backend-web-windows.md`](host-ui-backend-web-windows.md).

**System comparison (fork vs Miguel + holzschu):**  
[`Docs/system-comparison-report-2026-11-26.md`](system-comparison-report-2026-11-26.md).

**Full a-Shell command catalogue (158 + extras):**  
[`Docs/command-catalogue-full-2026-11-26.md`](command-catalogue-full-2026-11-26.md).

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

**Command parity vs holzschu a-Shell (158 already identical):**  
[`Docs/command-parity-vs-ashell-2026-11-26.md`](command-parity-vs-ashell-2026-11-26.md).

**Host capabilities gap (daemon / hooks / binaries):**  
[`Docs/host-capabilities-gap-2026-11-26.md`](host-capabilities-gap-2026-11-26.md).
