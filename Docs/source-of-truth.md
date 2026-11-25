# Source of truth

This fork (`jiaomeimei0-prog/SwiftTerm`) is the **only** place for terminal
emulator feature work and security patches.

| Work | Repository |
|------|------------|
| Parser, buffers, OSC/CSI, clipboard, Kitty, render, hardening | **This repo** — `Sources/SwiftTerm/` |
| Host app UI, `ios_system`, Relay, Xcode project, CI package path | `jiaomeimei0-prog/a-shell` (consume this package; no nested SwiftTerm) |

Apps under `Apps/` resolve the local package (see `Apps/README.md`). Do not
vendor a second SwiftTerm tree inside a host app.
