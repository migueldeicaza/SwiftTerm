# Kiểm toán bảo mật egress — SwiftTerm

**Repo:** `jiaomeimei0-prog/SwiftTerm`  
**Commit tham chiếu:** `92cbebc`  
**Ngày báo cáo:** 2026-11-26 (Asia/Saigon)  
**Câu hỏi chủ hệ thống:** Codebase có cơ chế kết nối mạng, telemetry, rò rỉ dữ liệu, hoặc điều hướng I/O trái phép sang bên thứ ba hay không?

---

## 1. Kết luận tổng quan (Verdict)

**`[CÓ CẢNH BÁO]`**

- Thư viện lõi `Sources/SwiftTerm` **không** có telemetry, không gọi `URLSession`/`NWConnection`, không hardcode endpoint bên thứ ba để “phone home”.
- Luồng I/O mặc định khớp bản đồ PTY ↔ engine ↔ UI; `LocalProcessTerminalView.send` chỉ ghi PTY.
- Có **kênh phụ theo giao thức terminal** (OSC 52 clipboard, mở link, Kitty đọc file local khi bật policy) và **mẫu app có mạng chủ đích** (SSH iOS, WebTerminal loopback) — không phải backdoor ẩn, nhưng có thể đưa dữ liệu ra ngoài process nếu host bật/cấu hình sai.

---

## 2. Bảng kiểm kê điểm giao tiếp ngoài (Egress Points)

| Điểm | Vị trí | Phân loại | Dữ liệu đi đâu |
|------|--------|-----------|----------------|
| PTY write | `LocalProcess.send` → `DispatchIO.write` | Hợp lệ | Master PTY / child process |
| `TerminalViewDelegate.send` (Mac local) | `MacLocalTerminalView.swift:521-524` | Hợp lệ | `process.send` → PTY only |
| `sendResponse` / OSC-CSI replies | `Terminal.swift:7971+` → `tdel.send` | Hợp lệ | Cùng kênh host (PTY/SSH/WS), không fork mạng riêng |
| OSC 52 clipboard **read** | `Terminal.swift:4058-4065` | Cảnh báo (protocol) | Clipboard → base64 → `sendResponse` → peer đang kết nối |
| OSC 52 clipboard **write** | `Terminal.swift:4066-4071` | Hợp lệ / host | Peer → pasteboard (local) |
| Pasteboard Mac local default | `MacLocalTerminalView.swift:412-424` | Cảnh báo khi SSH/remote | `clipboardRead` trả `NSPasteboard` → peer |
| Default `clipboardRead` | `Terminal.swift:10699-10700`, `MacTerminalView.swift:4912-4913` | An toàn mặc định | `nil` (từ chối đọc) |
| Mở hyperlink | `TerminalLinkOpening.swift:139`, `MacTerminalView.swift:4780` | Cảnh báo UX | User/delegate → `NSWorkspace.open` (trình duyệt/app) |
| Kitty local file `t=f`/`t=t` | `KittyGraphics.swift:1429+`; default policy `[]` tại `TerminalOptions.swift:154` | Cảnh báo nếu bật | Đọc file local vào engine (hiển thị); mặc định **tắt** |
| `setHostLogging` | `LocalProcess.swift:797-850` | Cảnh báo (opt-in debug) | Tee inbound PTY → file trên đĩa |
| `termcast` ghi `.cast` | `Sources/Termcast/TermcastRecorder.swift:64-70` | Hợp lệ (công cụ) | Session → file local do user chỉ định |
| Parser `dump()` ghi `/tmp` | `EscapeSequenceParser.swift:884-898` | Dead code | **Không có caller** trong repo |
| `Buffer.dump()` path Miguel | `Buffer.swift:1951-1979` | Dead / debug | Chỉ còn comment gọi `//buffer.dump()` (`Terminal.swift:8885`) |
| iOS SSH sample | `TerminalApp/iOSTerminal/UIKitSshTerminalView.swift` | Hợp lệ (sample) | User nhập host → NIO SSH |
| WebTerminal WS | `HTTPServer.swift:98` bind `127.0.0.1` | Hợp lệ (sample local) | Browser ↔ loopback ↔ local PTY |
| WASM `fetch(wasmURL)` | `Web/src/loader.ts:95` | Hợp lệ | Host tải artifact WASM do app cung cấp |
| CI `curl download.swift.org` | `.github/workflows/web-wasm.yml` | Hợp lệ (build) | Chỉ CI, không runtime app |
| `regen_unicode_width_data.py` | `scripts/` → unicode.org | Hợp lệ (dev) | Chỉ khi regen data, không runtime |

**Không tìm thấy trong `Sources/`:** `URLSession`, `NWConnection`, `NWListener`, Sentry/Firebase/analytics, `sendBeacon`, endpoint telemetry hardcode.

---

## 3. Phân tích bất thường / kênh phụ

### 3.1 Không phát hiện rò rỉ sang bên thứ ba (telemetry)

Quét `Sources/` không có client HTTP/telemetry. `Package.swift` chỉ phụ thuộc:

- `apple/swift-argument-parser`
- `apple/swift-docc-plugin`
- `tayloraswift/swift-png`
- Transitive `rarestype/h` = thư viện hash/Base64 cho PNG — không phải mạng

### 3.2 Invariant luồng send (khớp bản đồ)

```swift
// Sources/SwiftTerm/Mac/MacLocalTerminalView.swift:521-524
open func send(source: TerminalView, data: ArraySlice<UInt8>)
{
    process.send (data: data)
}
```

Không thấy tee/mirror sang socket hay URL thứ hai trong đường này.

### 3.3 OSC 52 — kênh exfil theo thiết kế protocol (không phải backdoor ẩn)

```swift
// Sources/SwiftTerm/Terminal.swift:4058-4065
if payload.count == 1 && payload[payload.startIndex] == UInt8(ascii: "?") {
    if tdel?.clipboardReadRequest(source: self, selection: selectionChars) == true { return }
    guard let content = tdel?.clipboardRead(source: self) else {
        return
    }
    let base64 = terminalBase64Encode(content)
    sendResponse(cc.OSC, "52;\(selectionChars);\(base64)", cc.ST)
```

- Default delegate: `clipboardRead` → `nil` (chặn).
- `LocalProcessTerminalView` **bật** đọc pasteboard → nếu peer là SSH remote, clipboard có thể ra máy khác qua cùng kênh SSH (không phải domain lạ riêng).

### 3.4 Kitty đọc file local — mặc định tắt

```swift
// Sources/SwiftTerm/TerminalOptions.swift:152-156
public init(
    storageLimitBytesPerScreen: UInt32 = 10_000_000,
    localMediaPolicy: LocalMediaPolicy = [],
    trustedTemporaryDirectory: TerminalTemporaryDirectory? = nil
```

Chỉ khi host set `.regularFiles`/`.temporaryFiles` thì remote sequence mới đọc được path local vào buffer đồ họa.

### 3.5 `setHostLogging` — fork inbound ra đĩa (opt-in)

```swift
// Sources/SwiftTerm/LocalProcess.swift:843-849
if let path = delivery.logPath {
    let ownedData = Data(data.copiedBytes())
    do {
        try ownedData.write(to: URL(fileURLWithPath: path))
```

Chỉ khi gọi `setHostLogging(directory:)`. Đây là tee khỏi trục “chỉ feed UI”, nhưng local disk, không mạng.

### 3.6 Render lock / dirty

`TerminalRenderOwner.feedTransaction` lấy `terminalLock`; `prepareFrame` gọi `clearUpdateRange()` sau khi lấy dirty range (`TerminalRenderOwner.swift:642-643`). Precondition chặn send/input khi đang giữ lock. Không thấy nhánh exfil từ FrameDriver.

### 3.7 Sample mạng (không nằm trong library embed mặc định)

| Sample | Egress |
|--------|--------|
| iOS SSH | Kết nối host user chỉ định |
| WebTerminal | Chỉ `127.0.0.1` + Origin check |

---

## 4. Khuyến nghị kiểm chứng động (Runtime)

Khi chạy app thật (MacTerminal / app nhúng SwiftTerm):

```bash
# 1) Process đang nghe/kết nối gì (thay PID)
lsof -nP -iTCP -a -p <PID>
lsof -nP -p <PID> | egrep 'TCP|UDP|PIPE|unix'

# 2) macOS: theo dõi kết nối theo process
nettop -p <PID> -L 1
# hoặc: sudo tcpdump -i any -n host not 127.0.0.1 and not ::1

# 3) Xác nhận không gọi setHostLogging
# (grep binary / audit log) — nếu có, kiểm tra thư mục log

# 4) Nếu dùng SSH: coi OSC 52 như exfil clipboard
# Tắt bằng cách clipboardRead luôn trả nil (default TerminalView)

# 5) Kitty local media: giữ localMediaPolicy = [] (mặc định)
```

Firewall: deny egress cho binary terminal trừ đích SSH/user-intended; WebTerminal chỉ cần loopback.

---

## 5. Kiểm tra bổ sung — Ba điểm mù (Blind Spots)

### 5.1 Diff fork `jiaomeimei0-prog/SwiftTerm` @ `92cbebc` vs upstream `migueldeicaza/SwiftTerm`

| Kiểm tra | Kết quả |
|----------|---------|
| `upstream/main` | `92cbebc0088fa13dec870373d8c189edc4062022` |
| `origin/main` | `92cbebc` (trùng tuyệt đối) |
| `git diff 92cbebc upstream/main` | **rỗng** (0 file) |
| `origin/main` ahead/behind upstream | **0 / 0** |
| Nhánh báo cáo này vs upstream | Chỉ thêm `Docs/security-audit-egress-2026-11-26.md` |

**Kết luận:** Tại điểm audit `92cbebc`, fork **không lệch** upstream. Không có patch riêng, không có commit lạ chèn telemetry. Mọi phát hiện egress thuộc **cùng codebase upstream**, không phải “payload chỉ có trên fork”.

Lệnh tái xác minh:

```bash
git remote add upstream https://github.com/migueldeicaza/SwiftTerm.git  # nếu chưa có
git fetch upstream main
git rev-parse origin/main upstream/main
git diff --stat origin/main upstream/main
```

---

### 5.2 Lớp C-Interop / Bridge & Build plugin

#### C / Objective-C bridge

| Kỳ vọng | Thực tế |
|---------|---------|
| `Sources/CSwiftTerm` | **Không tồn tại** |
| `*.c` / `*.h` trong package targets | **Không** (không có trong `Package.swift`) |
| File C trong tree | Chỉ `Docs/prototypes/futex-ticket-lock/shim.c` + `shim.h` — **không tham gia build**; README ghi rõ prototype đo lock |

Interop native thực tế nằm **trong Swift** qua Darwin/libc:

| API | File | Mục đích | Egress mạng? |
|-----|------|----------|--------------|
| `forkpty` / `execve` / `ioctl(TIOCSWINSZ)` | `Pty.swift`, `LocalProcess.swift` | Tạo PTY + child process | Không |
| `open` / `read` / `shm_open` (`@_silgen_name`) | `KittyGraphics.swift` | Kitty local media / shm (opt-in) | Không (đĩa/SHM local) |
| `TerminalIOPipeline` read PTY | `TerminalIOPipeline.swift` | Inbound từ master fd | Không |

**Không** thấy `dlopen`/`dlsym` tải binary lạ; không module map C trong product.

#### `Plugins/SwiftTermBuildInfoPlugin` + `Sources/SwiftTermBuildInfoGenerator`

| Hành vi | Chi tiết | Rủi ro |
|---------|----------|--------|
| Build-time only | Plugin gọi `SwiftTermBuildInfoGenerator` sinh `SwiftTermBuildInfo.swift` + bảng XTGETTCAP | Không chạy trên máy user cuối như daemon |
| `Process()` | Chỉ `/usr/bin/git -C <repo> …` đọc branch/tag/commit/dirty | Local git, **không** HTTP |
| Env fallback | `SWIFTTERM_BUILD_BRANCH/TAG/COMMIT/DIRTY` | Host CI có thể ghi đè metadata |
| Output | Embed `SwiftTermBuildInfo.version` / tag / branch vào binary | Metadata build; lộ qua **XTVERSION** (xem §5.3) |
| Terminfo | Đọc `swifterm-terminfo` → bảng trả lời DCS XTGETTCAP | Capability strings cố định, không mạng |

**Kết luận điểm mù 2:** Không có cầu C ẩn; plugin chỉ sinh metadata build + terminfo. Không egress mạng ở build plugin.

---

### 5.3 Chuỗi phản hồi tự động khác ngoài OSC 52 (`sendResponse` / `tdel.send`)

Mọi reply đi **cùng kênh** `TerminalDelegate.send` → PTY/SSH/WS (không mở socket riêng). Phân loại theo độ nhạy:

#### A. Có thể mang dữ liệu nhạy cảm / fingerprint (ưu tiên cứng hóa)

| Cơ chế | Vị trí | Payload gửi về peer | Điều kiện |
|--------|--------|---------------------|-----------|
| **OSC 52 clipboard query** | `Terminal.swift:4058-4065` | Clipboard base64 | `clipboardRead` ≠ nil |
| **OSC 52 complete (host API)** | `TerminalWebInput.swift:5` | Clipboard base64 | Host gọi `completeClipboardRead` |
| **Kitty Clipboard (OSC 5522)** | `KittyClipboardProtocol.swift` | MIME/clipboard qua protocol | Host bật capability / grant |
| **DECRQCRA** (checksum vùng màn) | `Terminal.swift:5374-5396` | Hex checksum nội dung ô | `enableRectangularAreaChecksum` **và** `isProcessTrusted` |
| **XTVERSION** | `Terminal.swift:5877-5883` | `SwiftTerm <tag>-<branch>+<version>` | CSI `>0q` — lộ build identity |
| **OSC 10/11/12 color query** | `Terminal.swift:4336+` | Màu FG/BG/cursor dạng xcolor | Peer hỏi màu |
| **Window ops CSI `t`** | `Terminal.swift:5652+`, `9100-9106` | rows/cols/pixel size | Peer hỏi kích thước |
| **Mouse reports** | `Terminal.swift:9427+` | Tọa độ / nút chuột | Mouse mode bật + sự kiện |
| **Focus report** | `Terminal.swift:1042+` | Focus in/out | DECSET 1004 |
| **DA / DA2 / DSR** | `Terminal.swift:6487+`, `7510+` | Nhận dạng VT525, cursor pos, status | Peer hỏi attributes/status |
| **XTGETTCAP** | `Terminal.swift:1631+` | Terminfo capability từ bảng sinh sẵn | DCS `+q` |
| **DECRQSS** | `Terminal.swift:1757+` | Chuỗi trạng thái mode (SGR, …) | DCS `$q` |
| **OSC 1337 Capabilities** | `Terminal.swift:4204-4213` | `featureReport` (chữ số/chữ cái) | Peer hỏi; không phải file contents |
| **Kitty Graphics OK/ERR** | `KittyGraphics.swift:1993+` | ACK/NACK control | Sau lệnh đồ họa |
| **OSC 7501 `?`** | `ProgramStatus.swift:117-121` | Echo query terminator | Không leak nội dung status store |

#### B. Gate tin cậy (`isProcessTrusted`)

- Default `TerminalDelegate.isProcessTrusted` → **`true`** (`Terminal.swift:10638-10640`).
- `MacTerminalView` cũng trả `true` (`MacTerminalView.swift:4484-4486`).
- Khi trusted: OSC 7/6 (cwd/document) được ghi nhận; DECRQCRA có thể checksum màn hình nếu bật option.
- Khi untrusted: chặn OSC 7/6 và checksum thật (DECRQCRA trả `0000`).

#### C. Không phải exfil bên thứ ba

Các reply trên **không** tạo kết nối mới; chúng chỉ trả lời peer đang gắn (shell local hoặc SSH remote). Rủi ro thực tế:

1. **SSH remote độc hại** kích OSC 52 / Kitty clipboard / DECRQCRA → lấy clipboard hoặc fingerprint màn hình qua kênh SSH.
2. **XTVERSION** giúp nhận diện phiên bản/build (không phải secret, nhưng fingerprint).
3. Local shell độc hại cùng máy cũng dùng được các CSI/OSC trên — mô hình đe dọa “untrusted child”.

#### D. Khuyến nghị cứng hóa (bổ sung mục 4)

| Biện pháp | Cách |
|-----------|------|
| Chặn clipboard → peer | Giữ `clipboardRead` / Kitty read → `nil` / deny (default `TerminalView`) |
| Chặn đọc lại màn hình | `enableRectangularAreaChecksum = false` (mặc định an toàn nếu không bật) + cân nhắc `isProcessTrusted = false` với peer không tin |
| Giảm fingerprint build | Không phụ thuộc vào việc xóa XTVERSION trừ khi fork chủ đích; hoặc sanitize `SwiftTermBuildInfo` env lúc build release |
| Kitty local files | Giữ `localMediaPolicy = []` |

---

### 5.4 Verdict sau ba điểm mù

| Điểm mù | Verdict riêng |
|---------|----------------|
| 1. Diff fork vs upstream | **SẠCH** — tree trùng `92cbebc` |
| 2. C-interop / Build plugin | **SẠCH** — không C product; plugin chỉ git local + terminfo |
| 3. Auto-replies ngoài OSC 52 | **CẢNH BÁO** — nhiều CSI/OSC/DCS hợp lệ theo VT; rủi ro khi peer không tin cậy (SSH), không phải phone-home |

**Verdict tổng thể sau bổ sung vẫn: `[CÓ CẢNH BÁO]`** — không đổi kết luận telemetry ẩn; làm rõ thêm bề mặt reply protocol và xác nhận fork = upstream.

---

## Tóm tắt một câu

**Không có cơ chế telemetry/exfil ẩn sang bên thứ ba trong lõi SwiftTerm; fork trùng upstream tại `92cbebc`; không có lớp C product; có nhiều chuỗi `sendResponse` (OSC/CSI/DCS) đi về peer đang kết nối — cần cứng hóa OSC 52 / Kitty clipboard / DECRQCRA / `isProcessTrusted` / không gọi `setHostLogging` trên bản production.**
