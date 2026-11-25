# Backend lõi giao diện — app thích hợp (a-Shell trên iOS)

**App đích:** `jiaomeimei0-prog/a-shell` (consumer của fork SwiftTerm v2)  
**Không dùng:** `LocalProcess` / kernel PTY (Miguel doc — macOS/Linux only)  
**Không dùng làm shell local trên iOS:** chỉ SSH (sample iOSTerminal) — a-Shell cần lệnh local trong sandbox

Thiết kế này khớp DocC nhà sản xuất (`send` / `feed` + `TerminalViewDelegate`) với mô hình thực thi a-Shell (`ios_system` + WASM).

---

## 1. Phân lớp

```text
┌─────────────────────────────────────────────────────────┐
│  UI — SwiftTerm (SoT: jiaomeimei0-prog/SwiftTerm)       │
│  TerminalView + HostHelpers (prompt/cursor/selection)     │
│  feed(text/bytes) ←── vẽ output                         │
│  send(data) ──────────→ user input                      │
└───────────────────────────┬─────────────────────────────┘
                            │ TerminalViewDelegate
┌───────────────────────────▼─────────────────────────────┐
│  Host backend — a-Shell (SceneDelegate)                 │
│  1) Line editor / prompt (HostHelpers)                  │
│  2) Foundation Pipe stdin/stdout + ios_setStreams       │
│  3) ios_fork() + ios_system(command)  OR  WASM path     │
│  4) onStdout → outputToTerminalView → feed              │
└─────────────────────────────────────────────────────────┘
```

| Thành phần | Repo | Trách nhiệm |
|------------|------|-------------|
| Emulator / render / HostHelpers | **SwiftTerm** | Chỉ UI terminal + API cầu nối |
| Pipe session, `ios_system`, WASM, Relay, Shortcuts | **a-shell** | Backend lệnh trong sandbox |

---

## 2. Hợp đồng `TerminalViewDelegate` (lõi)

Implement trên `SceneDelegate` (đã có):

| Callback | Backend a-Shell phải làm |
|----------|---------------------------|
| `send(source:data:)` | Đưa bytes vào line-editor **hoặc** ghi `stdin_file_input` khi lệnh interactive đang chạy |
| (stdout handler) | Đọc `Pipe` → `feed` vào `TerminalView` trên main |
| `clipboardCopy` | Ghi `UIPasteboard` (OSC 52 write) |
| `clipboardRead` | **Không implement** → deny OSC 52 read |
| `requestOpenLink` | Mở URL (`BROWSER` / `UIApplication.open`) |
| `sizeChanged` / title / scroll | Cập nhật `COLUMNS`/`LINES` / UI theo host |

**Cấm trên iOS a-Shell:** `LocalProcessTerminalView`, `HeadlessTerminal` gắn `/bin/sh` hệ thống.

---

## 3. Vòng đời một lệnh (backend chuẩn)

1. User kết thúc dòng (CR) → host gom `commandBeforeCursor` + … → `executeCommand`.  
2. Tạo `Pipe` stdin/stdout (retry nếu `fdopen` fail).  
3. `ios_setStreams` + `ios_settty` / window size.  
4. `pid = ios_fork()`; `ios_system(command)`.  
5. `readabilityHandler` → `onStdout` → `outputToTerminalView` → `terminalView.feed`.  
6. Kết thúc: đóng pipe, vẽ lại qua `getTerminal().updateFullScreen()` (không gọi `updateDisplay` internal).  
7. `setPromptEnd()` cho dòng lệnh tiếp theo (HostHelpers).

WASM: lệnh `.wasm` / `wasm3` đi path WebView `wasm.html` (loopback HTTPS), stdout vẫn về terminal qua cùng kiểu feed.

---

## 4. HostHelpers — phần “giao diện thông minh”

Backend lệnh không thay HostHelpers. UI line-editor dùng:

- Prompt: `setPromptEnd`, `getLastPrompt`, `getNewContent`, `getLastLine`  
- Cursor / selection / `clearToEndOfLine` / `wipeContents` / VoiceOver  

Sửa emulator → chỉ SwiftTerm. Sửa pipe/`ios_system` → chỉ a-shell.

---

## 5. Checklist thiết lập khi build app hợp nhất

1. Submodule a-Shell pin fork SwiftTerm (`edc5aae`+ với HostHelpers).  
2. Scheme `a-Shell-noPython` (hoặc full nếu có framework Python).  
3. Xác nhận `SceneDelegate` là `TerminalViewDelegate`; không dùng `LocalProcess`.  
4. Chạy trong app: `sh scripts/verify_ashell_integrity.sh`.  
5. Smoke: gõ lệnh native (`ls`), lệnh WASM nếu có, Shortcuts Execute Command.

---

## 6. So với các backend khác (không chọn cho a-Shell)

| Backend | Khi nào dùng | a-Shell iOS |
|---------|--------------|-------------|
| `LocalProcess` + PTY | Mac/Linux terminal app | **Không** |
| SSH → `send`/`feed` | Client SSH thuần (sample iOSTerminal) | Chỉ khi user chạy `ssh` *bên trong* ios_system |
| ExternalTerminalView | Emulator remote / process khác | **Không** (emulator local trong app) |
| **Pipe + ios_system** | Lệnh local trong sandbox iOS | **Đúng — backend lõi** |
