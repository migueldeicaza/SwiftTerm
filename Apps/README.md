# Apps

Host applications and samples that consume SwiftTerm.

## Source-of-truth policy

**All terminal feature work and security patches land only in this repository**
(`jiaomeimei0-prog/SwiftTerm`, under `Sources/SwiftTerm/` and related package
targets). Host apps under `Apps/` may wire package paths, UI, and `ios_system`
integration — they must **not** vendor a second SwiftTerm tree or carry
fork-local terminal/security diffs.

| Change type | Where it goes |
|-------------|----------------|
| Emulator / OSC / clipboard / parse / render / hardening | This repo (`Sources/SwiftTerm/…`) |
| a-Shell UI, commands, Relay, Xcode project, CI checkout path | `jiaomeimei0-prog/a-shell` (wiring only) |

## a-Shell (`Apps/a-Shell`)

Git submodule: https://github.com/jiaomeimei0-prog/a-shell  
Pinned to that fork’s branch that retargets the Xcode local package to this monorepo.

a-Shell is an iOS terminal. It no longer vendors a nested SwiftTerm git submodule. The Xcode project resolves SwiftTerm at `../SwiftTerm` relative to `Apps/a-Shell` — in this monorepo that is the `Apps/SwiftTerm` symlink to the parent package root.

### Init

```sh
git submodule update --init Apps/a-Shell
# Optional — only if you need a-Shell’s nested cpython pin:
# cd Apps/a-Shell && git submodule update --init cpython
```

Build instructions remain those of a-Shell (prefer the `a-Shell-noPython` scheme). See `Apps/a-Shell/README.md`.

### Layout

```text
SwiftTerm/                 ← Package.swift (this repo)
├── Apps/
│   ├── SwiftTerm -> ..    ← local package path for a-Shell.xcodeproj
│   └── a-Shell/           ← submodule (jiaomeimei0-prog/a-shell)
│       └── a-Shell.xcodeproj  (relativePath = ../SwiftTerm)
└── Sources/SwiftTerm/
```
