# Báo cáo tổng hợp tính năng — mã nguồn chính

**Thời điểm:** 2026-11-26 (Asia/Saigon)  
**Phạm vi:** source-of-truth `jiaomeimei0-prog/SwiftTerm` `@ main` + consumer `jiaomeimei0-prog/a-shell` `@ master`

| Repo | Tip khảo sát | Ghi chú pin |
|------|--------------|-------------|
| SwiftTerm `main` | `d2e8f42` | `Apps/a-Shell` → `f47f284c` (đã merge #10) |
| a-shell `master` | `f47f284c` | Nested `SwiftTerm` → `edc5aae` (fork v2 + HostHelpers) |

**Chính sách:** mọi tính năng / vá bảo mật emulator chỉ sửa tại SwiftTerm; a-shell chỉ wiring host (`Docs/source-of-truth.md`).

---

## 1. Kiến trúc đang hoạt động

```text
jiaomeimei0-prog/SwiftTerm          ← SOURCES emulator (fork v2)
├── Sources/SwiftTerm/…             ← parser, buffer, OSC/CSI, render, HostHelpers
├── Apps/a-Shell/                   ← submodule → jiaomeimei0-prog/a-shell
│   └── SwiftTerm/                  ← submodule → cùng fork (Xcode relativePath=SwiftTerm)
└── Docs/…                          ← audit, SoT, E2E host gate
```

| Thành phần | Trạng thái |
|------------|------------|
| Single source-of-truth SwiftTerm | **Hoạt động** |
| a-Shell pin fork (không còn holzschu v1) | **Hoạt động** |
| Host sources vs upstream holzschu (SceneDelegate*, ExtraCommands, Relay, AppDelegate) | **Giống hệt** (đã đối chiếu audit) |
| Bỏ gọi `updateDisplay` internal | **Hoạt động** — a-shell `f47f284c` + monorepo pin khớp |

I/O terminal app: Foundation `Pipe` + `ios_system` (không dùng `LocalProcess`/PTY kernel).

---

## 2. SwiftTerm — năm nhóm HostHelpers (cầu nối a-Shell)

File: `Sources/SwiftTerm/Apple/AppleTerminalView+HostHelpers.swift` (+ state trên `iOSTerminalView`).

| # | Nhóm | API đang có | Trạng thái |
|---|------|-------------|------------|
| 1 | Prompt / line-editor | `setPromptEnd`, `getLastPrompt`, `getNewContent`, `getLastLine` | **Hoạt động (API có mặt)** |
| 2 | Cursor | `save/restore/setCursorPosition`, `moveUp/DownIfNeeded`, `moveToBeginning/EndOfLine` | **Hoạt động (API có mặt)** |
| 3 | Selection | `deleteSelection`, `moveToBeginning/EndOfSelection` | **Hoạt động (API có mặt)** |
| 4 | Display / style | `clearToEndOfLine`, `wipeContents`, `setCursorStyle(shape:)`, `ensureCaretIsVisible` | **Hoạt động (API có mặt)** |
| 5 | Buffer / VO | `getTerminal()`, `isCurrentBufferAlternate`, `currentCommandVoiceOver` + `feed` | **Hoạt động (API có mặt)** |

Redraw host: dùng `getTerminal().updateFullScreen()` (public). **`updateDisplay` giữ internal** — không expose theo yêu cầu.

Chỉ số `linesTop` / `yBase` khớp hành vi holzschu SwiftTerm `@ dcbd49d` (audit §1).

---

## 3. SwiftTerm — lõi emulator (có trong package)

Các khối sau nằm trong fork v2 và được a-Shell link qua SPM local package:

| Khối | Nội dung chính | Trạng thái mã nguồn |
|------|----------------|---------------------|
| Parser / CSI / OSC | Escape sequences, modes, OSC 8 hyperlinks | Có |
| Buffer / scrollback | Primary + alternate buffer | Có (`isCurrentBufferAlternate`) |
| Clipboard protocol | OSC 52 write path; OSC 52 read mặc định deny | Có (host a-Shell: write bật, read không implement) |
| Kitty clipboard 5522 | Policy mặc định `[]` (tắt) | Có — **tắt mặc định** |
| DECRQCRA | Mặc định false ở release | Có — **tắt release** |
| Render Apple | Metal / CoreGraphics, caret, selection | Có |
| Powerline / box drawing | Render helpers | Có |
| BuildInfo plugin | Metadata git embed lúc build | Có |
| WASM / Web package | Build script + `Web/` (không phải a-Shell) | Có (tuỳ build) |

---

## 4. a-Shell — tính năng host đang có trong mã nguồn

Nguồn: tree `master` (logic app = holzschu + pin fork + bỏ `updateDisplay`).

### 4.1 Shell & sandbox

| Tính năng | Trạng thái |
|-----------|------------|
| Terminal đa cửa sổ / scene | Có |
| `.profile` / `.bashrc` tự chạy khi mở cửa sổ | Có (`SceneDelegate` ~5239+) |
| Bookmarks / `pickFolder` / `jump` (sandbox folders) | Có |
| `config` (font, màu, toolbar, theme) | Có |
| Themes JSON + Settings | Có |
| ~158 lệnh native trong `commandDictionary.plist` (full) | Có (catalogue) |

### 4.2 Lời gọi & tự động hoá

| Tính năng | Trạng thái |
|-----------|------------|
| Shortcuts **Execute Command** | Có |
| Shortcuts **Get File** / **Put File** | Có |
| Long Commands extension | Có |
| NSUserActivity / URL mở lệnh / file → vim | Có |
| ShellWorkers (mini, iOS 26+) | Có trong tree |

### 4.3 Mạng / remote

| Tính năng | Mặc định | Trạng thái |
|-----------|----------|------------|
| Wasm HTTPS local (`WasmServerPort` 8443/8334) | Bind `127.0.0.1`, autostart | Có |
| Relay HTTPS `/run` | `enabled=false`, bind `127.0.0.1`, mTLS on | Có (opt-in) |
| `pkg` → a-Shell-commands | Download script gói | Có |
| `ssh` / `curl` / `lg2` / … | User-driven | Có trong catalogue |
| **Codex** (OpenAI CLI nhúng) | Full app, iOS ≥ 26.2; cần build xcframework | Có trong tree / dictionary — **runtime phụ thuộc artifact** |
| Herdr | Mini / build script | Có trong tree |

### 4.4 Lập trình / runtime nhúng

| Tính năng | Trạng thái |
|-----------|------------|
| Python / Lua / JS / clang→WASM / TeX (full targets) | Có trong kiến trúc gốc (scheme `a-Shell-noPython` CI không cần Python 3.13 private) |
| VoiceOver line-editor hooks | Có (dùng HostHelpers + `currentCommandVoiceOver`) |

---

## 5. Side-channels & an toàn mặc định (đang áp dụng)

| Kênh | Mặc định trên tip | a-Shell |
|------|-------------------|---------|
| OSC 52 write | Host quyết định | **Bật** → pasteboard |
| OSC 52 read | Deny nếu không implement | **Deny** |
| Kitty OSC 5522 | Policy rỗng | **Tắt** |
| DECRQCRA | Release false | **Tắt** |
| OSC 8 / `requestOpenLink` | On | **Mở URL** |
| Relay | Off + loopback | An toàn mặc định |
| Wasm server | Loopback only | An toàn mặc định |

Chi tiết: `Docs/final-monorepo-audit-2026-11-26.md`, `Docs/security-audit-egress-2026-11-26.md`.

---

## 6. Nghiệm thu / kiểm chứng

| Cổng kiểm | Kết quả |
|-----------|---------|
| Host E2E (`scripts/e2e_acceptance_host.sh`) | **PASS=67 FAIL=0** (pin, API, parity, side-channel) — `Docs/e2e-acceptance-results.md` |
| Byte-identical host vs holzschu | **Đạt** (trước khi #5 bỏ `updateDisplay`; #5 chỉ xoá call internal) |
| GitHub Actions `App build` (macos-15) | **Không ổn định**: nhiều run `cancelled` vì hết capacity runner; khi có runner từng fail vì `updateDisplay` internal → **đã xử lý trên a-shell #5** |
| Build Xcode / Simulator / thiết bị | **Chưa nghiệm thu trong Cloud Agent** (không có Xcode) |
| Script thiết bị | `Apps/a-Shell/scripts/verify_ashell_integrity.sh` — sẵn sàng chạy trong app |

---

## 7. Việc còn mở

1. Chạy lại CI App build khi có runner macOS (hoặc build trên Mac/cloud Mac).  
2. Trên thiết bị: `sh scripts/verify_ashell_integrity.sh` + thử history/selection/Shortcuts.  
3. Codex: build `codex/codex.xcframework` nếu cần dùng AI CLI.  
4. Windows: **không** chạy a-Shell; chỉ có thể xem WASM browser của SwiftTerm (không đủ nghiệm thu app).

---

## 8. Kết luận ngắn

Trên mã nguồn chính của bạn, **đang hoạt động về mặt kiến trúc & API**:

- Fork SwiftTerm v2 làm SoT + submodule pin sạch.  
- **5 nhóm HostHelpers** đủ cho a-Shell.  
- Toàn bộ bề mặt tính năng host gốc a-Shell (Shortcuts, Relay opt-in, Wasm loopback, profile startup, ~158 lệnh, Codex/Herdr trong tree…).  
- Hardening side-channel mặc định hợp lý; không expose `updateDisplay`.

**Chưa đóng** nghiệm thu runtime trên Simulator/device và CI macOS xanh liên tục — cần Mac/Xcode hoặc runner ổn định.
