# Daemon / hooks / binaries — có gì & còn thiếu gì

**Ngày:** 2026-11-26 (Asia/Saigon)  
**So sánh:** fork `jiaomeimei0-prog/a-shell` `@ 0c9b11b6` × tip `holzschu/a-shell` × kỳ vọng “daemon / hooks / preloaded runtime”

---

## Verdict ngắn

Ba hạng mục bạn nêu **đã có trong a-Shell (và fork)** ở mức App Store iOS cho phép — **không phải lỗ hổng catalogue 158**.  
Chỗ “thiếu” thật chủ yếu là: **(a)** giới hạn nền tảng iOS, **(b)** artifact build chưa tải/build trên máy, **(c)** vài runtime tùy chọn (Python full / Stock SSH XCFramework) không publish sẵn.

| Hạng mục | Trong mã a-Shell / fork | Vs holzschu tip | “Thiếu” theo nghĩa nào? |
|----------|-------------------------|-----------------|-------------------------|
| Daemon / background listener | **Có** — Wasm HTTPS + Relay + ShellWorkers | Khớp (Relay/Wasm identical) | Không có `launchd`/system daemon (iOS cấm) |
| Event hooks / triggers | **Có** — Shortcuts, URL `ashell:`, NSUserActivity, Relay `/run` | Khớp Intent handlers | Không có file-watch daemon / BGAppRefresh shell |
| Preloaded runtime & CLI binaries | **Có định nghĩa** — 65 `binaryTarget` xcfs **identical** | Khớp 65/65 | Checkout cloud **chưa** chạy `downloadFrameworks.sh`; Python/Stock cần build riêng |

---

## 1. Daemon / background listener

### Đã có (fork = gốc)

| Listener / worker | Vai trò | Mặc định | Bind |
|-------------------|---------|----------|------|
| **Wasm `LocalHTTPServer`** | Phục vụ `wasm.html` + tài nguyên cho WASI | **Autostart** khi app foreground | `127.0.0.1` · port `WasmServerPort` (8443 full / 8334 mini) |
| **Relay** (`relay` CLI + `Relay.swift`) | HTTPS **`/run`** chạy lệnh qua `ios_system` | **`enabled=false`**, mTLS on | `127.0.0.1` · 8765 / 8766 |
| **ShellWorkers** (mini, iOS 26+) | Process/extension nền cho lệnh dài / Stock SSH | Theo `ShellWorkerCount` | Local XPC, không mở WAN |
| `Relay.shared.restore()` + `startLocalWebServer()` | Khôi phục listener khi launch | Trong `AppDelegate` | — |

Nguồn: `AppDelegate.swift` (Wasm server), `Relay.swift` (`NWListener`), `ShellWorkers/*`.

### Không có / không thể có trên App Store iOS

| Kỳ vọng kiểu desktop | Thực tế |
|----------------------|---------|
| Daemon `launchd` / service chạy 24/7 khi app bị kill | **Không** — iOS suspend/kill app; listener chỉ sống khi process app (hoặc extension) còn |
| Background fetch vô hạn chạy shell | **Không** có `BGAppRefresh`/`BGTask` đăng ký cho shell trong tree |
| Listener bind Internet mặc định | **Cố ý không** — loopback; Relay phải opt-in + đổi `bind` |

**Kết luận §1:** Fork **không thiếu** listener so với a-Shell gốc. Thiếu so với “daemon Unix” là **giới hạn iOS**, không phải regress fork.

---

## 2. Event hooks / triggers

### Đã có

| Hook | Cơ chế | Ghi chú |
|------|--------|---------|
| **Shortcuts — Execute Command** | `ExecuteCommandIntent` + handler | Mở cửa sổ / chạy lệnh |
| **Shortcuts — Get File / Put File** | Intents riêng | App Group FS |
| **Long Commands** | `AppIntent` (compiler mới) | Lệnh dài |
| **URL scheme** | `ashell:` / `ashell://` | `SceneDelegate.openURLContexts` |
| **NSUserActivity** | ExecuteCommand / OpenDirectory / EditDocument / TermSession | Handoff + restore |
| **Relay `/run`** | HTTPS POST lệnh | Trigger từ máy khác khi bật Relay |
| **`.profile` / `.bashrc`** | Autoload khi mở cửa sổ | Startup hook session |
| **Network path** | `NWPathMonitor` trong UI | Không phải lệnh hook |

Handlers: `a-Shell-Intents/*`, `SceneDelegate` ~4738–5577, `AppDelegate` Shortcuts section.

### Không có (cả gốc lẫn fork)

| Hook kiểu “agent OS” | Trạng thái |
|----------------------|------------|
| File-system watcher → auto chạy lệnh | Không |
| Cron / calendar trigger trong app | Không (dùng Shortcuts Automation bên ngoài) |
| Push notification → shell | Không `registerForRemoteNotifications` cho lệnh |
| GitHub/Slack webhook listener trong app | Không (Relay là HTTPS local, không phải SaaS webhook) |

**Kết luận §2:** So với a-Shell gốc — **đủ hooks**. So với hệ thống agent đa nền tảng — thiếu watcher/cron **native**; trên iOS thường ủy quyền cho **Shortcuts Automations**.

---

## 3. Preloaded runtime & CLI binaries

### Đã có trong repo (định nghĩa + catalogue)

| Lớp | Nội dung | Vs holzschu |
|-----|----------|-------------|
| `xcfs/Package.swift` | **65** `binaryTarget` (ios_system, shell, files, ssh_cmd, curl, vim, …) | **Identical** (0 diff) |
| `commandDictionary` | 158 lệnh map → framework/`SELF` | Identical |
| `downloadFrameworks.sh` | Kéo artifact + Python tarball | Identical |
| LLVM / TeX / LuaTeX plists | Nạp qua `needLLVM` / `needTeX`… | Identical |
| WASM runners | `wasm3`, `wasmkit`, `wasm` host | Có trong tree |
| Stock SSH overlay | Wiring đã merge (#6); XCFramework **local build** | Tip parity wiring |

### Chỗ “thiếu” thực dụng (không phải thiếu so với tip mã nguồn)

| Artifact | Trong git tip? | Cần làm gì |
|----------|----------------|------------|
| `xcfs/.build/artifacts/**/*.xcframework` | **Không** (download) | Chạy `./downloadFrameworks.sh` trên Mac |
| Python 3.13 full frameworks | Không publish đủ | Scheme `a-Shell-noPython` hoặc artifact nội bộ |
| `*Stock.xcframework` (OpenSSH 10.6) | Không trong Package.swift | Build ios_system `ssh-stock` (README) |
| Codex `.xcframework` | gitignored | `codex/build.sh` |
| Cloud Agent Linux | Không Xcode | Không thể nạp binary iOS tại đây |

**Kết luận §3:** Catalogue + pin binary **không thiếu so với a-Shell**. Thiếu là **môi trường build/device** chưa materialize frameworks.

---

## 4. Việc nên làm tiếp (nếu muốn “đủ” theo hướng bạn nêu)

Ưu tiên kỹ thuật, không ước lịch:

1. **Mac:** `downloadFrameworks.sh` + `xcodebuild` scheme phù hợp → chứng minh CLI binaries chạy.  
2. **(Tuỳ chọn Stock)** build 4 `*Stock` XCFramework + runtime `ios_posix_spawn`.  
3. **Hooks ngoài app:** dùng Shortcuts Automation / Relay LAN thay cho daemon; document playbook nếu cần.  
4. **Không** cố thêm system daemon trong App Store binary — trái sandbox iOS.

---

## 5. Tham chiếu

- `Docs/final-monorepo-audit-2026-11-26.md` §3 (listeners)  
- `Docs/command-parity-vs-ashell-2026-11-26.md`  
- `Docs/command-catalogue-full-2026-11-26.md`  
- `Docs/host-ui-backend.md`  
- a-Shell `Relay.swift`, `AppDelegate.swift`, `xcfs/Package.swift`, README Stock OpenSSH  
