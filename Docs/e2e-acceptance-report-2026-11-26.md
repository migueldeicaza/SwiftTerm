# Biên bản nghiệm thu E2E tổng thể — 2026-11-26 (Asia/Saigon)

## Phạm vi & môi trường

| Hạng mục | Giá trị |
|----------|---------|
| Monorepo tip (lúc chạy harness) | `27db3e0` → sau PR này kèm pin mới |
| Nested a-Shell | tip có `verify_ashell_integrity.sh` |
| Nested SwiftTerm | `edc5aae` (HostHelpers) |
| Host runner | Linux x86_64 Cloud Agent — **không** Xcode / Simulator / thiết bị |
| Harness | `scripts/e2e_acceptance_host.sh` |
| Device script | `Apps/a-Shell/scripts/verify_ashell_integrity.sh` |

## Kết quả host gate (đã chạy)

Chạy: `bash scripts/e2e_acceptance_host.sh`  
Kết quả lần xanh: **PASS=67 WARN=1 FAIL=0 SKIP=2** (chi tiết `Docs/e2e-acceptance-results.md`).

| Nhóm | Trạng thái | Ghi chú |
|------|------------|---------|
| Pin graph (fork SwiftTerm, nested `edc5aae`) | **ĐẠT** | |
| 20 HostHelpers + VoiceOver/caret | **ĐẠT** | |
| Call-site a-Shell ↔ API | **ĐẠT** | |
| Byte-identical vs `holzschu/a-shell` host sources | **ĐẠT** | SceneDelegate*, ExtraCommands, Relay, AppDelegate |
| Side-channels / Relay defaults | **ĐẠT** | Kitty off; DECRQCRA release off; OSC52 read deny; write on |
| Build artifacts + checksum xcfs | **ĐẠT** | WARN: python tarball không SHA (thiết kế gốc) |
| Device script `sh -n` + dry-run stubs | **ĐẠT** | |
| `xcodebuild` / `swift test` | **SKIP** | Không có toolchain trên host |
| App CI (GitHub macos-15) | **CHƯA ĐẠT** | Jobs cancelled/queued — thiếu capacity runner, không phải lỗi code |
| Interactive trên thiết bị thật | **CHƯA CHẠY** | Cần máy Mac + Xcode |

## Verdict

**Nghiệm thu host / cấu trúc / parity: ĐẠT.**  
**Nghiệm thu E2E đầy đủ (build app + chạy trên device): CHƯA ĐẠT** — blocked bởi thiếu macOS/Xcode ở đây và CI hosted macOS chưa acquire được runner.

## Checklist thiết bị (bắt buộc để đóng E2E)

Trên Mac, sau `xcodebuild` / Run trên iPhone/iPad:

```sh
sh scripts/verify_ashell_integrity.sh
```

Thủ công thêm:

1. Gõ lệnh, history ↑↓, Ctrl-A/E, xóa selection  
2. Shortcuts → Execute Command  
3. `relay status` (mặc định off / loopback)  
4. (Tuỳ chọn) `codex --version` nếu đã build xcframework  

## Cách tái chạy host gate

```sh
git submodule update --init Apps/a-Shell
UPSTREAM_ASHELL=/path/to/holzschu/a-shell bash scripts/e2e_acceptance_host.sh
```
