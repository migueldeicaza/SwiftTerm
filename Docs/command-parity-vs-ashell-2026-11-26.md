# Parity lệnh vs a-Shell gốc — 2026-11-26 (Asia/Saigon)

## Kết luận ngắn

| Hạng mục | Trạng thái fork vs `holzschu/a-shell` tip |
|----------|-------------------------------------------|
| **158 lệnh** `Resources/commandDictionary.plist` | **ĐÃ ĐỦ — byte-identical** (SHA khớp, 0 lệnh thiếu/thừa) |
| mini 136 | **ĐÃ ĐỦ — byte-identical** |
| extra / llvm / tex / luatex dictionaries | **ĐÃ ĐỦ — byte-identical** |
| Host builtins (`help`, `config`, `pkg`…) | Có (cùng mã nguồn host) |
| Stock OpenSSH overlay (4 lệnh ssh* trên mini) | **Wiring đã port** trên a-shell `cursor/stock-ssh-parity-3951` — cần XCFramework build local + runtime `ios_posix_spawn` |

**Không cần “thêm 158 lệnh”** — catalogue chính đã hoàn chỉnh so với a-Shell nói chung.

---

## Chi tiết đối chiếu (fork a-shell `f47f284c` × holzschu `17b01a4d`)

Trước port Stock SSH:

| File | fork | holzschu | Khớp? |
|------|------|----------|-------|
| `commandDictionary.plist` | 158 | 158 | **Có (byte)** |
| `Resources_mini/commandDictionary.plist` | 136 | 136 | **Có** |
| `extraCommandsDictionary.plist` | 8 | 8 | **Có** |
| `llvmDictionary.plist` | 10 | 10 | **Có** |
| `texCommandsDictionary.plist` | 31 | 31 | **Có** |
| `luatexCommandsDictionary.plist` | 7 | 7 | **Có** |
| `sshStockCommands.plist` | thiếu | có | **Đã bổ sung trên nhánh Stock SSH** |

Legacy SSH trong 158 vẫn trỏ `ssh_cmd.framework` — dùng được trên full/mini **không** cần Stock.

---

## Stock SSH ≠ lệnh thứ 159–162 mới

Stock chỉ **thay backend** của cùng 4 tên lệnh (`ssh`, `scp`, `sftp`, `ssh-keygen`) bằng OpenSSH 10.6 + ShellWorkers khi điều kiện iOS 26+ thỏa. Xem README a-shell mục *Stock OpenSSH*.

Bảng catalogue 158: [`command-catalogue-full-2026-11-26.md`](command-catalogue-full-2026-11-26.md).

---

## Việc còn lại để “chạy” Stock trên thiết bị

1. Merge PR a-shell Stock SSH wiring.  
2. Build 4 XCFramework `*Stock` từ ios_system `ssh-stock` (Mac/Xcode).  
3. ios_system runtime có `ios_posix_spawn`.  
4. Chạy `tests/ssh-stock-registration.sh` trên macOS + smoke trên device.

---

## Nguồn

- a-shell tip fork / holzschu đối chiếu plist  
- PR a-shell: Stock SSH wiring (`cursor/stock-ssh-parity-3951`)
