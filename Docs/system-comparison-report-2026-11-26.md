# Đánh giá hệ thống hiện tại so với hệ thống gốc

**Thời điểm:** 2026-11-26 (Asia/Saigon)  
**Phương pháp:** đối chiếu tip git, diff identity trên host sources, quét HostHelpers / side-channel / pin graph.  
**Không thay thế:** build Xcode / chạy trên thiết bị thật (Cloud Agent không có macOS runner ổn định).

---

## 0. Định nghĩa “hệ thống gốc” và “hệ thống hiện tại”

Hệ thống a-Shell + terminal trên iOS vốn là **hai dòng gốc** ghép lại, không phải một monorepo Miguel duy nhất:

| Vai trò | Hệ thống gốc | Tip khảo sát |
|---------|--------------|--------------|
| Thư viện VT hiện đại (parser, OSC/Kitty, WASM, Mac PTY) | `migueldeicaza/SwiftTerm` | `a480ce6` |
| Cầu nối HostHelpers cho a-Shell (v1) | `holzschu/SwiftTerm` (fork cũ của Miguel) | tip `e8ebb5d`; pin lịch sử trong a-shell gốc = `dcbd49d` |
| App host iOS (ios_system, lệnh, Relay, Shortcuts) | `holzschu/a-shell` | `17b01a4d` |

| Vai trò | Hệ thống hiện tại (fork của bạn) | Tip khảo sát |
|---------|----------------------------------|--------------|
| **Source-of-truth** emulator + HostHelpers + docs/E2E | `jiaomeimei0-prog/SwiftTerm` `main` | `5dfea6c` |
| App host (wiring + pin submodule) | `jiaomeimei0-prog/a-shell` `master` | `f47f284c` |
| Nested Xcode pin SwiftTerm | submodule trong a-shell | `edc5aae` (fork v2 + HostHelpers) |

```text
GỐC (hai nhánh rời)                    HIỆN TẠI (SoT thống nhất)
─────────────────────                  ─────────────────────────
miguel/SwiftTerm ──┐                   jiaomeimei0-prog/SwiftTerm  ← sửa emulator/security
                   │  (không HostHelpers)         │
holzschu/SwiftTerm ┼─ HostHelpers v1              ├── HostHelpers (port từ v1)
                   │                              ├── Apps/a-Shell submodule
holzschu/a-shell ──┘── pin holzschu/SwiftTerm     └── Docs + E2E host gate
                              │
                              ▼
                   jiaomeimei0-prog/a-shell
                   pin → jiaomeimei0-prog/SwiftTerm
```

**Verdict một câu:** Hệ thống hiện tại = **lõi Miguel gần tip** + **HostHelpers kiểu holzschu v1** + **host a-Shell gần gốc** (có vài delta chủ đích), kèm **chính sách SoT / audit / E2E host** mà gốc không có.

---

## 1. So sánh kiến trúc

| Hạng mục | Miguel gốc | holzschu a-shell + SwiftTerm v1 | Hệ thống hiện tại |
|----------|------------|----------------------------------|-------------------|
| Emulator VT | Có (tip mới nhất) | Có nhưng pin cũ (`dcbd49d`) / tip holzschu lệch Miguel | Gần Miguel (`5dfea6c` = Miguel tip − 1 commit) + HostHelpers |
| HostHelpers (prompt/cursor/selection…) | **Không** | **Có** (inline `AppleTerminalView` / `iOSTerminalView`) | **Có** — file riêng `AppleTerminalView+HostHelpers.swift` (~374 dòng) |
| LocalProcess / kernel PTY | macOS/Linux (không iOS/Windows/Android/WASI) | Không dùng trên iOS a-Shell | Giống Miguel — **a-Shell không dùng** |
| Backend lệnh iOS | Sample SSH only | `ios_system` + WASM `pkg` | **Giống holzschu** — Pipe + `ios_system` + WASM |
| Backend Web / Windows | WASM + sample WebTerminal (PTY cần Mac/Linux/WSL) | Không phải sản phẩm a-Shell | Documented: `Docs/host-ui-backend-web-windows.md` |
| Monorepo Apps/a-Shell | Không | Repo riêng | Submodule trong SwiftTerm fork |
| Source-of-truth policy | Repo Miguel | Repo holzschu + pin | **Chỉ fork SwiftTerm** sửa emulator; a-shell wiring-only |

### 1.1 Luồng UI ↔ lệnh

**Miguel (Mac sample):** `TerminalView` ↔ `LocalProcess` ↔ PTY ↔ `/bin/sh`.

**holzschu / fork hiện tại (a-Shell iOS):**

```text
TerminalView + HostHelpers
    send / feed  (TerminalViewDelegate)
        ↕
Foundation Pipe + ios_setStreams
        ↕
ios_fork() + ios_system(...)   hoặc   WASM / wasm.html (loopback)
```

Đây là điểm **không đổi so với gốc a-Shell**, và là điểm **khác hoàn toàn** so với DocC LocalProcess của Miguel trên desktop.

---

## 2. So sánh thư viện SwiftTerm (Miguel vs fork)

### 2.1 Khoảng cách tip

| | Commits |
|--|---------|
| Fork **ahead** Miguel | **14** (HostHelpers, Apps submodule, Docs, E2E script, README, Powerline fix nhỏ) |
| Fork **behind** Miguel | **1** — `a480ce6` *macOS find-bar cursor + Wasm mouse-mode dedupe (#845)* |

**Đánh giá:** Lõi parser/render/security options gần như đồng bộ Miguel; chỉ thiếu 1 PR desktop/WASM chuột. Không có divergence lớn về escape sequences.

### 2.2 Thay đổi mã nguồn `Sources/` so với Miguel

| File | Thay đổi | Mục đích |
|------|----------|----------|
| `AppleTerminalView+HostHelpers.swift` | **Thêm mới** | Port ~20 API HostHelpers từ holzschu v1 |
| `iOSTerminalView.swift` | State prompt (`promptline`…) + `ensureCaretIsVisible` → `public` | Hỗ trợ HostHelpers / VoiceOver |
| `PowerlineRenderer.swift` | `Array(flameLowerPath.dropFirst())` | Fix kiểu Swift (biên dịch) |

**Không** fork-patch Kitty/OSC/DECRQCRA defaults so với Miguel tip (cùng `TerminalOptions`: Kitty policy `[]`, DECRQCRA release `false`).

### 2.3 HostHelpers: fork vs holzschu v1 vs Miguel

| Nhóm | holzschu v1 | Fork hiện tại | Miguel |
|------|-------------|----------------|--------|
| Prompt / line-editor | Có | Có (cùng công thức `linesTop`/`yBase`) | Không |
| Cursor | Có | Có | Không |
| Selection | Có | Có | Không |
| Display / style | Có | Có; redraw qua `updateFullScreen` (public) | Không |
| Buffer / VO + `feed` | Có | Có | `feed` có; không VO/prompt state |
| `updateDisplay` | Public/internal tùy bản v1; a-shell gốc vẫn gọi | **Giữ internal** — a-shell fork **đã bỏ** mọi call | Có internal; không a-Shell |

**Đánh giá:** Cầu nối a-Shell được **bảo toàn hành vi v1** trên nền Miguel hiện đại — đây là giá trị cốt lõi của fork so với “chỉ dùng Miguel tip” (Miguel tip **không** chạy a-Shell line-editor).

### 2.4 WASM / Web

| | Miguel | Fork |
|--|--------|------|
| Package `Web/`, wasm build | Có | Có (kế thừa) |
| Doc backend Web-on-Windows | Không đặc thù a-Shell | Có (`host-ui-backend-web-windows.md`) |
| a-Shell trên Windows | N/A | **Không** — đúng như gốc |

---

## 3. So sánh app a-Shell (holzschu vs fork)

### 3.1 Pin SwiftTerm

| | holzschu/a-shell | jiaomeimei0-prog/a-shell |
|--|------------------|--------------------------|
| Submodule URL | `holzschu/SwiftTerm` | **`jiaomeimei0-prog/SwiftTerm`** |
| Commit pin điển hình | `dcbd49d` (cũ) | Nested `edc5aae` (fork v2 + HostHelpers) |
| Catalogue lệnh (`commandDictionary.plist`) | **158** keys | **158** keys (khớp) |

### 3.2 Identity host sources (tip holzschu `17b01a4d` vs fork `f47f284c`)

| File | Kết quả | Ý nghĩa |
|------|---------|---------|
| `SceneDelegate.swift` | **IDENTICAL** | Profile startup, `executeCommand`, Shortcuts — giữ nguyên |
| `ExtraCommands.swift` | **IDENTICAL** | |
| `Relay.swift` | **IDENTICAL** | Relay opt-in + Wasm server shared |
| `ContentView.swift` | **IDENTICAL** | |
| `SceneDelegate+TerminalView.swift` | **DIFF** — chỉ **xoá** các `updateDisplay()` (giữ `updateFullScreen`) | Tương thích API internal Miguel/fork; không đổi logic lệnh |
| `AppDelegate.swift` | **DIFF** — fork **thiếu** khối Stock SSH / `ios_posix_spawn` (iOS 26 + ShellWorkers) mà tip holzschu mới thêm | **Hụt tính năng mới của upstream** (opt-in ssh stock qua worker), không phải regression HostHelpers |

### 3.3 Tính năng host giữ / lệch

| Tính năng gốc a-Shell | Hiện tại | Ghi chú |
|-----------------------|----------|---------|
| ~158 lệnh native + WASM pkg | Giữ | |
| `.profile` / `.bashrc` auto | Giữ | |
| Shortcuts Execute / Get / Put File | Giữ | |
| Relay HTTPS `/run` (default off, loopback, mTLS) | Giữ | |
| Wasm HTTPS loopback | Giữ | |
| VoiceOver + HostHelpers line-editor | Giữ (qua fork API) | |
| Gọi `updateDisplay` | **Bỏ** | Cố ý — API internal |
| Stock SSH worker (tip holzschu mới) | **Chưa có** trên fork tip | Cần merge/cherry-pick nếu muốn parity tuyệt đối với tip holzschu hôm nay |

---

## 4. So sánh bảo mật / side-channel

| Kênh | Miguel default | holzschu a-shell + v1 | Hệ thống hiện tại |
|------|----------------|------------------------|-------------------|
| Telemetry trong `Sources/SwiftTerm` | Không | Không | Không (đã audit) |
| OSC 52 write | Host quyết định | a-Shell: pasteboard | **Giống** — bật |
| OSC 52 read | Default deny | Deny (không override) | **Giống** — deny |
| Kitty clipboard 5522 | Policy `[]` | Off | **Off** |
| DECRQCRA | Release false | Off release | **Off** |
| OSC 8 open link | On | Mở URL | **Giống** |
| Relay | N/A (app) | Opt-in loopback | **Giống gốc** |
| SoT security patches | Trên Miguel | Trên holzschu SwiftTerm (lệch tip) | **Chỉ trên fork** — rõ ràng hơn v1 |

**Đánh giá:** Tư thế mặc định **không kém** gốc Miguel; so với a-Shell gốc **tương đương** trên kênh terminal. Lợi thế fork: audit egress đã ghi nhận + E2E quét default.

---

## 5. So sánh kiểm chứng & vận hành

| Cổng | Miguel gốc | holzschu gốc | Hiện tại |
|------|------------|--------------|----------|
| Unit/DocC/WASM CI (SwiftTerm) | Có | Một phần / lệch | Kế thừa + docs |
| Host E2E pin/API/parity script | Không | Không | **Có** — `scripts/e2e_acceptance_host.sh` (**PASS=67 FAIL=0**) |
| Device integrity script | Không | Không | **Có** — `verify_ashell_integrity.sh` |
| App build CI macos-15 | N/A / khác | Có | **Không ổn định** (cancelled / thiếu runner) |
| Nghiệm thu Simulator/device trong Cloud | N/A | N/A | **Chưa** |

Nested pin `edc5aae` **đứng sau** tip SoT `5dfea6c` **10 commit** (chủ yếu docs + bump Apps) — mã HostHelpers trong nested vẫn là đúng bản v2; docs mới hơn nằm ở parent SoT.

---

## 6. Ma trận tổng hợp: hơn / kém / ngang gốc

### 6.1 So với `migueldeicaza/SwiftTerm`

| | Đánh giá |
|--|----------|
| **Hơn** | HostHelpers cho a-Shell; monorepo pin; SoT policy; audit/E2E/docs backend iOS & Web-Windows |
| **Kém / rủi ro** | **1 commit** behind tip Miguel (#845); nested submodule chưa luôn = tip SoT |
| **Ngang** | Lõi VT, WASM package, LocalProcess desktop, default side-channel |

### 6.2 So với `holzschu/a-shell` + `holzschu/SwiftTerm`

| | Đánh giá |
|--|----------|
| **Hơn** | Emulator dựa Miguel tip (mới hơn pin `dcbd49d`); SoT một nơi; bỏ phụ thuộc API `updateDisplay` internal; harness E2E/audit |
| **Kém / rủi ro** | Tip host **chưa** có Stock SSH worker mới của holzschu; CI app chưa xanh liên tục; device E2E chưa chạy ở đây |
| **Ngang** | Catalogue 158 lệnh; SceneDelegate/Relay/ExtraCommands; mô hình ios_system+WASM; hầu hết HostHelpers semantics |

---

## 7. Điểm mạnh / điểm yếu hệ thống hiện tại

### Điểm mạnh

1. **Hợp nhất đúng bài toán:** Miguel hiện đại + cầu a-Shell — hai gốc trước đây tách rời.  
2. **SoT rõ:** không sửa emulator trong a-shell; giảm drift v1.  
3. **Parity host có bằng chứng:** identity SceneDelegate/Relay + E2E PASS=67.  
4. **Hardening mặc định hợp lý** + không public hóa `updateDisplay`.  
5. **Tài liệu kiến trúc** (ios_system, UI backend iOS, Web-Windows) tốt hơn cả hai gốc cho người vận hành fork.

### Điểm yếu / nợ kỹ thuật

1. **Chưa đóng E2E runtime** (Xcode/device + CI macOS).  
2. **Drift tip holzschu** trên AppDelegate (Stock SSH).  
3. **Nested SwiftTerm pin** (`edc5aae`) không auto-track mọi commit docs/SoT — cần quy trình bump có chủ đích.  
4. **1 commit Miguel** chưa cherry-pick.  
5. Windows chỉ có đường Web/WASM + PTY ngoài process — **không** thay a-Shell (đúng thiết kế, nhưng dễ hiểu nhầm).

---

## 8. Kết luận đánh giá

| Câu hỏi | Trả lời ngắn |
|---------|----------------|
| Hệ thống hiện tại có “mất” lõi gốc Miguel không? | **Không** — gần tip; thiếu 1 PR nhỏ. |
| Có giữ được a-Shell gốc không? | **Gần như toàn bộ** bề mặt lệnh/host; delta cố ý `updateDisplay`; **hụt** Stock SSH mới của tip holzschu. |
| Có hơn gốc ở chỗ nào có ý nghĩa? | SoT + HostHelpers trên Miguel + audit/E2E/docs — **vận hành fork rõ ràng hơn**. |
| Mức sẵn sàng sản phẩm? | **Sẵn sàng về kiến trúc & parity host tĩnh**; **chưa** chứng minh xanh trên device/CI macOS trong môi trường này. |

**Khuyến nghị ưu tiên (kỹ thuật, không ước lịch):**

1. Cherry-pick / rebase Miguel `#845` vào SoT.  
2. Quyết định merge Stock SSH từ tip holzschu hoặc ghi rõ “won't port”.  
3. Chạy `verify_ashell_integrity.sh` + smoke HostHelpers trên thiết bị; theo dõi App build CI khi có runner.  
4. Khi cần binary mới: bump nested `Apps/a-Shell/SwiftTerm` lên tip SoT có HostHelpers (không chỉ docs).

---

## 9. Tham chiếu nội bộ

- `Docs/source-of-truth.md`  
- `Docs/feature-status-report-2026-11-26.md`  
- `Docs/final-monorepo-audit-2026-11-26.md`  
- `Docs/e2e-acceptance-report-2026-11-26.md`  
- `Docs/security-audit-egress-2026-11-26.md`  
- `Docs/host-ui-backend.md` / `Docs/host-ui-backend-web-windows.md`  
- `Apps/README.md`
