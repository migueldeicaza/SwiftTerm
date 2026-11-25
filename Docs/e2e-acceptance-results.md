# E2E acceptance results (host)

- Generated: 2026-11-25T21:05:35Z UTC
- Root: `/workspace`
- HEAD: `8e135176bdb8d5f075e87c2620f6502c5ab47222` (`8e13517 Add host E2E acceptance harness and report`)

=== Host E2E acceptance ===

## 1. Pin graph
PASS  SwiftTerm HEAD=8e135176bdb8d5f075e87c2620f6502c5ab47222
PASS  Apps/a-Shell gitlink=68857ae1ab46216c312bdc8ef5ac6712160d9bb7
PASS  Apps/a-Shell checkout matches gitlink
PASS  nested SwiftTerm pin=edc5aae87c070887c1575b059e83a800a44e3bae
PASS  nested SwiftTerm is ancestor of monorepo HEAD (or equal)
PASS  .gitmodules points at jiaomeimei0-prog/SwiftTerm

## 2. HostHelpers bridge (20 APIs)
PASS  file /workspace/Sources/SwiftTerm/Apple/AppleTerminalView+HostHelpers.swift
PASS  HostHelpers has getTerminal
PASS  HostHelpers has isCurrentBufferAlternate
PASS  HostHelpers has getLastLine
PASS  HostHelpers has getLastPrompt
PASS  HostHelpers has setPromptEnd
PASS  HostHelpers has getNewContent
PASS  HostHelpers has saveCursorPosition
PASS  HostHelpers has restoreCursorPosition
PASS  HostHelpers has setCursorPosition
PASS  HostHelpers has getCurrentChar
PASS  HostHelpers has moveUpIfNeeded
PASS  HostHelpers has moveDownIfNeeded
PASS  HostHelpers has atTheEndOfTheLine
PASS  HostHelpers has moveToBeginningOfLine
PASS  HostHelpers has moveToEndOfLine
PASS  HostHelpers has clearToEndOfLine
PASS  HostHelpers has wipeContents
PASS  HostHelpers has setCursorStyle
PASS  HostHelpers has moveToEndOfSelection
PASS  HostHelpers has moveToBeginningOfSelection
PASS  HostHelpers has deleteSelection
PASS  setPromptEnd uses linesTop+yBase+y
PASS  ensureCaretIsVisible + currentCommandVoiceOver public on iOS

## 3. a-Shell call-site coverage vs HostHelpers
PASS  call-site clearToEndOfLine satisfied by HostHelpers
PASS  call-site currentCommandVoiceOver satisfied on iOSTerminalView
PASS  call-site deleteSelection satisfied by HostHelpers
PASS  call-site ensureCaretIsVisible satisfied on iOSTerminalView
PASS  call-site getLastLine satisfied by HostHelpers
PASS  call-site getLastPrompt satisfied by HostHelpers
PASS  call-site getNewContent satisfied by HostHelpers
PASS  call-site getTerminal satisfied by HostHelpers
PASS  call-site isCurrentBufferAlternate satisfied by HostHelpers
PASS  call-site moveDownIfNeeded satisfied by HostHelpers
PASS  call-site moveToBeginningOfLine satisfied by HostHelpers
PASS  call-site moveToBeginningOfSelection satisfied by HostHelpers
PASS  call-site moveToEndOfLine satisfied by HostHelpers
PASS  call-site moveToEndOfSelection satisfied by HostHelpers
PASS  call-site moveUpIfNeeded satisfied by HostHelpers
PASS  call-site restoreCursorPosition satisfied by HostHelpers
PASS  call-site saveCursorPosition satisfied by HostHelpers
PASS  call-site setCursorPosition satisfied by HostHelpers
PASS  call-site setCursorStyle satisfied by HostHelpers
PASS  call-site setPromptEnd satisfied by HostHelpers
PASS  call-site wipeContents satisfied by HostHelpers

## 4. Upstream parity spot-check (identical host sources)
PASS  identical to holzschu: a-Shell/SceneDelegate.swift
PASS  identical to holzschu: a-Shell/SceneDelegate+TerminalView.swift
PASS  identical to holzschu: a-Shell/ExtraCommands.swift
PASS  identical to holzschu: a-Shell/Relay.swift
PASS  identical to holzschu: a-Shell/AppDelegate.swift

## 5. Network / side-channel defaults (static)
PASS  Kitty clipboard policy default empty
PASS  DECRQCRA default false in release
PASS  OSC8 hyperlinks default true
PASS  Relay default disabled + loopback bind
PASS  a-Shell does not implement clipboardRead (OSC52 read stays denied)
PASS  a-Shell implements clipboardCopy (OSC52 write)

## 6. Automation artifacts present
PASS  file /workspace/Apps/a-Shell/downloadFrameworks.sh
PASS  file /workspace/Apps/a-Shell/xcfs/Package.swift
PASS  file /workspace/Apps/a-Shell/Resources/bin/pkg
PASS  file /workspace/Apps/a-Shell/scripts/verify_ashell_integrity.sh
PASS  file /workspace/Apps/a-Shell/codex/build.sh
PASS  file /workspace/Apps/a-Shell/a-Shell-Intents/ExecuteCommandIntentHandler.swift
PASS  xcfs Package.swift has checksum entries
WARN  pythonInstall.tar.gz fetched without local SHA-256 (upstream design)

## 7. Device script syntax
PASS  verify_ashell_integrity.sh sh -n clean
=== a-Shell integrity 2026-11-25T21:05:36Z ===
pwd=/workspace
HOME=/tmp/tmp.DNouIwqodq
GROUP=

## env
PASS  env produced output (44 lines)
PASS  env has HOME
PASS  env has PATH
PASS  env has TERM
PASS  env has COLUMNS
PASS  env has LINES

## help -l
PASS  help -l listed 38 commands
PASS  help -l contains config
PASS  help -l contains pkg
PASS  help -l contains curl
PASS  help -l contains open
PASS  help -l contains help
PASS  help -l contains codex (full app)

## .relay.json
PASS  found /tmp/tmp.DNouIwqodq/Documents/.relay.json
PASS  /tmp/tmp.DNouIwqodq/Documents/.relay.json has enabled/bind/port keys
PASS  /tmp/tmp.DNouIwqodq/Documents/.relay.json enabled is not true (safe default / stopped)
PASS  /tmp/tmp.DNouIwqodq/Documents/.relay.json bind is loopback 127.0.0.1
WARN  relay command not available in this target

## clipboard pbcopy/pbpaste
PASS  pbcopy/pbpaste round-trip

## local listeners (Wasm / Relay)
WARN  no TLS response on 127.0.0.1:8443 (wasm-full) — server may be down or different port
WARN  no TLS response on 127.0.0.1:8334 (wasm-mini) — server may be down or different port
PASS  no TLS acceptor on 127.0.0.1:8765 (relay-full) — expected when relay is off
PASS  no TLS acceptor on 127.0.0.1:8766 (relay-mini) — expected when relay is off
(plist defaults: full Wasm=8443 Relay=8765; mini often 8334/8766)

=== summary PASS=20 WARN=3 FAIL=0 ===
PASS  device script dry-run passed under host stubs (rc=0)

## 8. Local toolchain / CI gates
SKIP  xcodebuild unavailable — cannot build iOS app on this host
SKIP  swift unavailable — package unit tests not executed

## Summary
PASS=67 WARN=1 FAIL=0 SKIP=2

## Counts

| PASS | WARN | FAIL | SKIP |
|------|------|------|------|
| 67 | 1 | 0 | 2 |

**Host gate: PASS** (device interactive / Xcode build still required for full E2E).

## Device follow-up (manual)

```sh
sh scripts/verify_ashell_integrity.sh
```

Plus interactive: history edit, selection delete, VoiceOver, Shortcuts Execute Command, optional Codex.
Wrote /workspace/Docs/e2e-acceptance-results.md
