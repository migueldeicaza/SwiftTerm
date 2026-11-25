# Final monorepo audit — 2026-11-26 (Asia/Saigon)

**Scope:** `jiaomeimei0-prog/SwiftTerm` `@ main` tip `68d1f61` with nested `Apps/a-Shell` `@ b4488692` (SwiftTerm submodule pin `edc5aae`), compared to upstream `holzschu/a-shell` tip and historical `holzschu/SwiftTerm` pin `dcbd49d` (the pin upstream a-shell still records), plus `migueldeicaza/SwiftTerm` tip (no HostHelpers surface).

**Method:** byte/identity diffs on host sources; line-level comparison of HostHelpers vs v1; static scan of scripts, listeners, and protocol defaults. **Not** a substitute for device E2E (see §4 script).

---

## 1. Chức năng & lệnh vs `holzschu/a-shell`

### 1.1 Host command call paths (a-Shell app)

| File | vs `holzschu/a-shell` tip | Notes |
|------|---------------------------|--------|
| `Apps/a-Shell/a-Shell/SceneDelegate.swift` | **IDENTICAL** | Includes `.profile`/`.bashrc` autoload ~5239–5284; `executeCommand` ~4191; Shortcuts/NSUserActivity `ExecuteCommand` ~4740+ |
| `Apps/a-Shell/a-Shell/SceneDelegate+TerminalView.swift` | **IDENTICAL** | All TerminalView host API call sites |
| `Apps/a-Shell/a-Shell/ExtraCommands.swift` | **IDENTICAL** | Embedded commands / help credits |
| `Apps/a-Shell/a-Shell/Relay.swift` | **IDENTICAL** | Relay + shared `LocalHTTPServer` |
| `Apps/a-Shell/a-Shell/ContentView.swift` | **IDENTICAL** | |
| `Apps/a-Shell/a-Shell/AppDelegate.swift` | **IDENTICAL** | Wasm listener start |

**Only intentional fork deltas** (non-app-logic):

- `Apps/a-Shell/.gitmodules` — `SwiftTerm` → `https://github.com/jiaomeimei0-prog/SwiftTerm.git` `branch = main` (upstream: `holzschu/SwiftTerm`)
- `Apps/a-Shell/.github/workflows/app-build.yml` — submodule sync for that pin
- `Apps/a-Shell/README.md` — fork / HostHelpers documentation

**Verdict:** No host command path, Shortcut, relay, or ExtraCommands behaviour was removed or altered relative to upstream beyond the SwiftTerm submodule pointer.

### 1.2 Twenty HostHelpers bridge APIs vs `holzschu/SwiftTerm` `@ dcbd49d`

Canonical fork file: `Sources/SwiftTerm/Apple/AppleTerminalView+HostHelpers.swift` (iOS/visionOS).  
Upstream v1 lived mainly in `AppleTerminalView.swift` ~3203–3469 and selection helpers in `iOSTerminalView.swift` ~3442–3475.

| # | API | Fork lines | v1 origin | `linesTop` / `yBase` | `markDirty` / `updateRange` / redraw |
|---|-----|------------|-----------|----------------------|--------------------------------------|
| 1 | `getTerminal()` | 27–29 | AppleTerminalView ~378 | n/a | n/a |
| 2 | `isCurrentBufferAlternate` | 31–33 | ~3467–3469 | n/a | n/a |
| 3 | `getLastLine()` | 35–66 | ~3203+ | uses `promptline` | none (read-only; same as v1) |
| 4 | `getLastPrompt()` | 68–100 | ~3234+ | uses `promptline`/`promptcolumn` | none |
| 5 | `setPromptEnd()` | 103–110 | ~3267–3272 | `promptline = linesTop + yBase + y` **:107** | `updateCursorPosition()` only (same as v1) |
| 6 | `getNewContent()` | 112–123 | ~3274–3280 | compensates `savedCursorLinesTop - linesTop` **:116** | none |
| 7 | `saveCursorPosition()` | 125–131 | ~3282–3287 | saves `linesTop`, `yBase+y`, `x` **:127–129** | none |
| 8 | `restoreCursorPosition()` | 133–138 | ~3289–3292 | `y = saved - yBase` **:136** | none (v1 also none) |
| 9 | `setCursorPosition` | 141–187 | ~3295–3327 | rejects below prompt via `linesTop+yBase` **:160**; distance uses same formula **:175–177** | `updateCursorPosition()` on success **:184** (v1 **:3325**) |
| 10 | `getCurrentChar()` | 189–200 | ~3329–3339 | `yBase+y` **:191** | none |
| 11 | `moveUpIfNeeded()` | 202–213 | ~3341–3352 | `linesTop+yBase+y` vs `promptline` **:204** | none |
| 12 | `moveDownIfNeeded()` | 215–226 | ~3354–3365 | `yBase+y` **:217** | none |
| 13 | `atTheEndOfTheLine()` | 228–234 | ~3367–3373 | `yBase+y` | none |
| 14 | `moveToBeginningOfLine()` | 236–241 | ~3376–3380 | `y = promptline - yBase - linesTop` **:239** | none |
| 15 | `moveToEndOfLine()` | 243–271 | ~3382–3411 | `y = lastUsed - yBase` **:258** | none |
| 16 | `clearToEndOfLine()` | 273–291 | ~3414–3430 | clears from `yBase+y` **:275–288** | **Neither fork nor v1** calls `markDirty`/`updateRange`/`updateFullScreen` inside the helper |
| 17 | `wipeContents()` | 293–304 | ~3433–3442 | nulls all cells | **Neither** helper marks dirty |
| 18 | `setCursorStyle(shape:)` | 306–325 | ~3444–3465 | n/a | via `terminal.setCursorStyle` (same mapping; fork adds `"beam"` aliases already present as fallthrough in v1) |
| 19 | `moveToEnd/BeginningOfSelection` | 328–357 | iOS ~3442–3461 | selection rows | clears selection + pan gesture (same) |
| 20 | `deleteSelection()` | 360–371 | iOS ~3464–3475 | gated on `promptline` **:362** | sends backspaces (same) |

**Related (group 4/5, not all in HostHelpers file):**

- `ensureCaretIsVisible()` — `Sources/SwiftTerm/iOS/iOSTerminalView.swift` ~3254 (`public`, matches v1 ~2719)
- `currentCommandVoiceOver`, `promptline`, `promptcolumn`, `savedCursor*` — `iOSTerminalView.swift` ~336–341 (v1 ~55–61)

**Redraw contract (important):** HostHelpers mutate buffer cells **without** internal `markDirty`/`updateRange`, **matching v1**. a-Shell already pairs many edits with `getTerminal().updateFullScreen()` (e.g. `SceneDelegate+TerminalView.swift:741,799,969,994,1164,1187,1285,1300`). Paths that only call `clearToEndOfLine()` without a following `updateFullScreen` behave the same as upstream a-shell + v1.

**vs `migueldeicaza/SwiftTerm` tip:** no HostHelpers / a-Shell bridge APIs — expected; fork v2 deliberately re-adds them.

**Verdict §1:** Function/command surface vs holzschu a-shell is preserved. HostHelpers index arithmetic for `linesTop`/`yBase` tracks v1. No missing dirty-mark relative to v1 (both omit it; host redraw pairing is unchanged).

---

## 2. Script & automation map (INPUT → OUTPUT)

### 2.1 Build

| Tool | INPUT | OUTPUT | Network | Checksum / notes |
|------|-------|--------|---------|------------------|
| `Apps/a-Shell/downloadFrameworks.sh:1-9` | `xcfs/Package.swift`; URL `github.com/holzschu/a-shell/releases/.../pythonInstall.tar.gz` | SPM artifacts under `xcfs/.build/`; extracted Python tree | Download only | SPM SHA-256 per binaryTarget; **python tarball: no checksum** |
| `Apps/a-Shell/xcfs/Package.swift` | ~65 `binaryTarget` ZIPs (`ios_system`, `lg2`, `sshd`, llvm, tex, vim, curl, …) | `xcfs/.build/artifacts/.../*.xcframework` | Download only | Every binary has `checksum:` |
| `Plugins/SwiftTermBuildInfoPlugin/plugin.swift` + `Sources/SwiftTermBuildInfoGenerator/` | Local git HEAD / env `SWIFTTERM_BUILD_*`; terminfo | Generated `SwiftTermBuildInfo.swift`, `SwiftTermTerminfo.swift` | **No** | Embeds metadata locally only |
| `.github/workflows/*` (a-Shell) | checkout + submodule; `downloadFrameworks.sh`; native recipes | Unsigned `xcodebuild`; release zips/checksums | Download (+ CI artifact upload of **build products**) | `ci/native-frameworks.sh` verifies SHA-256 of pinned sources |
| `.github/workflows/*` (SwiftTerm) | xcode tests; wasm SDK from `download.swift.org`; DocC | logs / `Web/dist` / Pages | Download + artifact upload | wasm toolchain checksums in workflow |
| `codex/build.sh` | `codeload.github.com/openai/codex` tag `rust-v0.160.0`; crossterm fork | `codex.xcframework` (gitignored) | Download | SHA-256 in script |
| `Herdr/build.sh` | clone `herdr` @ pinned tag | `libherdr_ios.a` | Download | pin + printed SHA |
| `ShellWorkers/generate-targets.sh`, `resources.sh` | plist / dictionary | pbxproj + worker resources | No | local rewrite |

**Build egress of local machine data:** **No.** Scripts only download (and CI may upload build artifacts/logs). Incidental TLS client metadata only. BuildInfoPlugin does not phone home.

### 2.2 Runtime

| Path | INPUT | OUTPUT / destination | Network |
|------|-------|----------------------|---------|
| `Resources/bin/pkg` (~14–70) | `$PKG_SERVER` or default `raw.githubusercontent.com/holzschu/a-Shell-commands/master/` (`list`, `packages/<name>`) | Runs install script → typically `~/Documents/bin/*.wasm`, man pages, `.pkg` records | **Yes — download + execute remote shell** (no package checksum) |
| `lg2_sync.sh` | **Not in-tree**; lives on a-Shell-commands; uses local vault + `lg2` | User’s `origin` remote via SSH | User-initiated sync |
| Wasm HTTPS (`AppDelegate.swift` ~45–49, `Relay.swift` LocalServerPorts) | Bundle `localCertificate.pfx`; Library + Bundle files | `https://127.0.0.1:<WasmServerPort>/…` (8443 full / 8334 mini) | **Loopback only** |
| Relay (`Relay.swift`) | `.relay.json`, `.relay-identity.p12`, optional `.relay-client-ca.der` | HTTPS `/run` command exec | Opt-in inbound; bind default loopback |
| `codex/` | User auth; OpenAI Responses APIs (upstream CLI) | `$GROUP/Library/codex` or `CODEX_HOME` | **Yes when user runs Codex** |
| `Herdr/` | local panes | ShellWorkers IPC | No third-party egress |
| `a-Shell-Intents` | Shortcuts payloads | App Group FS / `ashell:` URL / ios_system | Only if command itself networks |
| `ShellWorkers` | XPC pane spawn | local workers | Local IPC |

---

## 3. Network endpoints & side-channels

### 3.1 Inbound listeners

| Listener | Default state | Bind | Port | TLS / mTLS | Certs | Citations |
|----------|---------------|------|------|------------|-------|-----------|
| Wasm `LocalHTTPServer` | Autostart with app | **`127.0.0.1`** | `WasmServerPort` 8443 / mini 8334 | TLS server-only | Bundle `localCertificate.pfx` (passphrase `password`); also `localCertificate.pem` in tree | `AppDelegate.swift` ~45–49; `Relay.swift` LocalServerPorts ~244–294 |
| Relay | **`enabled = false`** (`RelayConfiguration` **:139**) | Default **`127.0.0.1`** (**:140**); configurable `0.0.0.0` / `::` | 8765 / mini 8766 | TLS always; **mTLS default true** (**:142**) | Generated `.relay-identity.p12` / `.relay-cert.pem` (passphrase `relay`); SAN `relay.local,localhost,127.0.0.1` (**:95**) | `Relay.swift:11,23–55,115–142` |

### 3.2 Outbound (hardcoded / default)

| Sink | Domain / URL | Where |
|------|--------------|-------|
| pkg default | `https://raw.githubusercontent.com/holzschu/a-Shell-commands/master/` | `Resources/bin/pkg` |
| downloadFrameworks | `github.com/holzschu/a-shell/releases/.../pythonInstall.tar.gz` | `downloadFrameworks.sh:7` |
| xcfs binaries | `github.com/holzschu/*/releases/download/...` (+ `fprimex/jq`) | `xcfs/Package.swift` |
| Codex build | `codeload.github.com/openai/codex/...`, `openai-oss-forks/crossterm` | `codex/build.sh:28–29` |
| Codex runtime | OpenAI APIs via upstream CLI (auth env) | not hardcoded host string in app patches |
| Help / credits | gitbook, GitHub issues, Discord | `ExtraCommands.swift` ~200–264 |
| User tools | arbitrary via `curl`/`ssh`/`nc`/`pip` | commandDictionary |

### 3.3 Terminal protocol side-channels @ SwiftTerm `edc5aae`

| Channel | Default | a-Shell host | Citations |
|---------|---------|--------------|-----------|
| OSC 52 **write** (`clipboardCopy`) | Host-decided | **Enabled** → `UIPasteboard` | `SceneDelegate+TerminalView.swift:1813–1816` |
| OSC 52 **read** (`clipboardRead`) | Delegate default **nil = deny** | **No override → deny** | `iOSTerminalView.swift:4065–4174`; a-Shell implements copy only |
| Kitty OSC **5522** | `kittyClipboardPolicy: []` (**off**) | a-Shell does not opt in → **off** | `TerminalOptions.swift:227,270,940` (`KittyClipboardProtocol.swift`) |
| **DECRQCRA** | Release **false** / Debug **true** | Never set → **off in App Store release** | `TerminalOptions.swift:221–221,277–280`; `AppleTerminalView.swift:1887–1896` |
| `requestOpenLink` | OSC8 default **on** | **Opens URL** (`BROWSER` or `UIApplication.open`) | `TerminalOptions.swift:205,274`; `SceneDelegate+TerminalView.swift:1797–1810` |
| `setHostLogging` | Off until set | **Unused** in a-Shell | `MacLocalTerminalView.swift:529–531` (Mac path) |

---

## 4. Device E2E acceptance script

Added: `Apps/a-Shell/scripts/verify_ashell_integrity.sh`

**On device (after Xcode install):**

```sh
# from repo copy in Files/Documents, or:
sh scripts/verify_ashell_integrity.sh
```

Checks: `.relay.json` presence/keys/bind; `env` required vars; `help -l` command catalogue; `pbcopy`/`pbpaste` round-trip; TLS/TCP probes on Wasm/Relay loopback ports.

**Still requires human/Xcode:** full interactive HostHelpers (history edit, selection delete, VoiceOver), Codex login, LAN relay mTLS — script covers integrity smoke only.

---

## Overall acceptance

| Criterion | Status |
|-----------|--------|
| a-Shell command/host paths vs holzschu | **Pass** (identical sources) |
| HostHelpers vs holzschu SwiftTerm v1 index math | **Pass** |
| HostHelpers internal dirty-mark vs v1 | **Pass (parity: both omit; host updateFullScreen unchanged)** |
| Build scripts phone-home | **None found** |
| Inbound defaults (Wasm loopback; Relay off + loopback) | **Pass** |
| Side-channels locked as documented | **Pass** (OSC52 read deny; Kitty off; DECRQCRA release off) |
| Device E2E green | **Pending** — run §4 script + manual interactive checks on hardware |
