# Backend lõi giao diện Web — dùng trên Windows

**Mục tiêu:** chạy UI terminal SwiftTerm trong **trình duyệt trên Windows** (Chrome / Edge).  
**Không phải** a-Shell iOS. **Không** có `LocalProcess` / PTY trong process Windows của thư viện SwiftTerm.

Thiết kế khớp DocC + [`Docs/wasm.md`](wasm.md) + package [`Web/`](../Web/README.md).

---

## 1. Phân lớp (Windows browser)

```text
┌──────────────────────────────────────────────────────────────┐
│  UI (browser trên Windows)                                   │
│  Canvas / WebGL host + TerminalInputController (Web/)        │
│  snapshot() → vẽ pixel     sendKey/sendText/paste/sendMouse  │
└────────────────────────────┬─────────────────────────────────┘
                             │ @swiftterm/wasm (WASI reactor)
┌────────────────────────────▼─────────────────────────────────┐
│  Emulator lõi (WASM Full hoặc Embedded)                      │
│  write(bytes)  ←── output từ shell/PTY/SSH                   │
│  readOutput() ───→ bytes trả lời / input đã encode → transport│
└────────────────────────────┬─────────────────────────────────┘
                             │ Transport (host cung cấp)
┌────────────────────────────▼─────────────────────────────────┐
│  Backend lệnh (chọn một — nằm NGOÀI WASM)                    │
│  A) WebSocket → máy Linux/WSL/Mac chạy PTY (khuyến nghị)     │
│  B) WebSocket → SSH bridge / server remote                   │
│  C) Demo local stream (Web/example) — KHÔNG có shell thật    │
└──────────────────────────────────────────────────────────────┘
```

| Lớp | Ai sở hữu | Windows |
|-----|-----------|---------|
| Renderer + input DOM | Host JS (`Web/example`, hoặc app của bạn) | **Có** — chạy trong Edge/Chrome |
| Engine VT (`createTerminal`) | `swiftterm-*.wasm` | **Có** — tải bằng `loadSwiftTerm` |
| Shell / PTY thật | Server hoặc WSL | **Không** trong WASM; sample `WebTerminal` cần macOS/Linux (PTY) |

---

## 2. Hợp đồng API lõi (thay cho `TerminalViewDelegate`)

Trên web **không** dùng `TerminalView` / `send`/`feed` UIKit. Dùng cặp đối xứng:

| Hướng | API WASM | Ý nghĩa |
|-------|----------|---------|
| Process → UI | `terminal.write(Uint8Array \| string)` | Output shell vào emulator (**không** nhét phím vào đây) |
| UI → Process | `sendKey` / `sendText` / `paste` / `sendMouse` → `readOutput()` → gửi transport → `consumeOutput(n)` sau khi gửi OK | Input đã encode |
| Vẽ | `snapshot()` → vẽ `rowData` → `markFrameRendered(generation)` | Chỉ ack sau khi draw thành công |
| Sự kiện host | `drainEvents()` | Title, bell, clipboard… — host **opt-in** |

Clipboard / OSC tin cậy: mặc định hạn chế; host phải `configureClipboard()` nếu muốn.

---

## 3. Backend lệnh phù hợp trên Windows

### Khuyến nghị sản phẩm (interactive shell)

1. Build artifact: `scripts/build-wasm.sh full --browser --release` (cần toolchain Swift WASM — thường build trên Mac/Linux CI, copy `Web/dist` sang Windows).  
2. Serve tĩnh `Web/dist` + trang host (hoặc CDN).  
3. Mở Edge/Chrome trên Windows.  
4. Transport: **WebSocket binary** tới một trong các đầu cuối:

| Đầu cuối | Ghi chú |
|----------|---------|
| **WSL2** trên cùng máy Windows chạy server PTY (port loopback) | Gần “local shell” nhất |
| **WebTerminal sample** trên Mac/Linux LAN (chỉ loopback mặc định — phải đổi bind/auth nếu remote) | Sample chính thức: `TerminalApp/WebTerminal` |
| **SSH/jump host** | Phù hợp client từ Windows thuần |

Luồng (giống sample):

```text
Browser input → encoder WASM → readOutput → WS → PTY/shell
Browser canvas ← snapshot ← write ← WS ← PTY output
```

### Chỉ xem UI (không shell)

`Web/example` + `python -m http.server` — stream demo local, **không** backend lệnh.

### Không làm trên Windows native Swift

- `LocalProcess` / `HeadlessTerminal` gắn `/bin/sh` — **không** có trên Windows theo DocC.  
- Đừng kỳ vọng `TerminalApp/WebTerminal/run.sh` chạy PTY native trên Windows không WSL.

---

## 4. Checklist thiết lập (Windows)

1. Lấy `Web/dist/swiftterm-full.wasm` (+ JS package) từ CI/Mac build.  
2. Host trang: `loadSwiftTerm({ wasmURL })` → `createTerminal` → Canvas + `TerminalInputController`.  
3. `socket.binaryType = 'arraybuffer'`; `onmessage` → `write`; sau input → `readOutput` / `consumeOutput`.  
4. Resize: gửi JSON `{"type":"resize","cols",…}` nếu dùng protocol WebTerminal.  
5. Bảo mật: đừng expose PTY WebSocket ra Internet không auth (sample loopback-only).

---

## 5. So sánh nhanh với backend a-Shell iOS

| | a-Shell iOS | Web trên Windows |
|--|-------------|------------------|
| Emulator | `TerminalView` native | WASM reactor |
| I/O UI | `feed` / `send` | `write` / `readOutput` |
| Lệnh | `ios_system` + WASM in-app | PTY/SSH **bên ngoài** browser |
| Catalogue 158 lệnh | Có | **Không** (là shell của server/WSL) |

Xem thêm: [`host-ui-backend.md`](host-ui-backend.md) (iOS), [`wasm.md`](wasm.md), [`commands-by-platform-2026-11-26.md`](commands-by-platform-2026-11-26.md).
