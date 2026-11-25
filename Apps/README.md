# Apps

Host applications and samples that consume SwiftTerm.

## Source-of-truth policy

**All terminal feature work and security patches land only in this repository**
(`jiaomeimei0-prog/SwiftTerm`, under `Sources/SwiftTerm/` and related package
targets).

| Change type | Where it goes |
|-------------|----------------|
| Emulator / OSC / clipboard / parse / render / hardening | This repo (`Sources/SwiftTerm/…`) |
| a-Shell UI, commands, Relay, Xcode project, CI | `jiaomeimei0-prog/a-shell` (wiring only) |

a-Shell may vendor a **submodule checkout of this same fork** at
`Apps/a-Shell/SwiftTerm` for Xcode `relativePath = SwiftTerm`. That is a
consumer pin of fork v2 — not a second emulator codebase to edit.

## Five original a-Shell terminal host capabilities (preserved on fork v2)

Implemented in `Sources/SwiftTerm/Apple/AppleTerminalView+HostHelpers.swift`
(+ prompt state on `iOSTerminalView`):

1. **Prompt / line-editor** — `setPromptEnd`, `getLastPrompt`, `getNewContent`, `getLastLine`
2. **Cursor control** — `saveCursorPosition` / `restoreCursorPosition` / `setCursorPosition`, line moves
3. **Selection editing** — `deleteSelection`, `moveToBeginningOfSelection`, `moveToEndOfSelection`
4. **Display / style** — `clearToEndOfLine`, `wipeContents`, `setCursorStyle(shape:)`, `ensureCaretIsVisible`
5. **Terminal / buffer access** — `getTerminal()`, `isCurrentBufferAlternate`, `currentCommandVoiceOver` (+ existing `feed`)

## a-Shell (`Apps/a-Shell`)

Git submodule: https://github.com/jiaomeimei0-prog/a-shell  

### Init

```sh
git submodule update --init Apps/a-Shell
cd Apps/a-Shell && git submodule update --init SwiftTerm
# Optional cpython for full Python builds:
# git submodule update --init cpython
```

Prefer the `a-Shell-noPython` scheme. See `Apps/a-Shell/README.md`.

### Layout

```text
SwiftTerm/                      ← Package.swift (this fork v2 — edit here)
├── Sources/SwiftTerm/
│   └── Apple/AppleTerminalView+HostHelpers.swift   ← five host capability groups
├── Apps/
│   ├── SwiftTerm -> ..         ← optional monorepo alias
│   └── a-Shell/                ← submodule (jiaomeimei0-prog/a-shell)
│       └── SwiftTerm/          ← submodule pin of THIS fork (Xcode local package)
└── Docs/source-of-truth.md
```
