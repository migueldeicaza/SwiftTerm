# Lệnh terminal theo nền tảng (iOS / Windows / Android APK)

**Nguồn tip:** SwiftTerm `main` + nested a-Shell `commandDictionary.plist`  
**Ngày:** 2026-11-26 (Asia/Saigon)

---

## Tóm tắt nhanh

| Nền tảng | App lệnh shell trong monorepo này? | Cơ chế thực thi |
|----------|-----------------------------------|-----------------|
| **iOS / iPadOS / visionOS** (a-Shell) | **Có** — catalogue đầy đủ | `ios_system` in-process + WASM tùy lệnh |
| **macOS** (Apple Silicon, App Store a-Shell) | Cùng codebase a-Shell (không phải focus fork CI) | Tương tự iOS |
| **Windows** | **Không** có a-Shell / catalogue lệnh | SwiftTerm chỉ là **emulator** (WASM/browser hoặc host PTY ngoài phạm vi a-Shell) |
| **Android APK** | **Không** có port a-Shell / APK trong repo | SwiftTerm library có target `.android` (portable graphics) — **không** kèm bộ lệnh Unix |

---

## 1. iOS — a-Shell (có lệnh)

### 1.1 Host builtins (app, không chỉ `commandDictionary`)

Ví dụ trong `ExtraCommands.swift` / host: `help`, `config`, `pickFolder`, `jump`, bookmark helpers, `pkg` (script), `relay`, mở cửa sổ / exit, v.v.

### 1.2 Catalogue native — **full** (`Resources/commandDictionary.plist`) — **158** khóa

Bảng đầy đủ (nhóm, framework, symbol, full/mini) + CSV + dictionary mở rộng:  
[`command-catalogue-full-2026-11-26.md`](command-catalogue-full-2026-11-26.md) · [`command-catalogue-full-2026-11-26.csv`](command-catalogue-full-2026-11-26.csv)

### 1.2b Danh sách phẳng (158 khóa)

```
alias, apropos, awk, base64, basename, bc, blink, calc, cat, cbc, cd, chdir,
chflags, chmod, cksum, codex, compare, composite, compress, conjure, convert,
cp, curl, curl-impersonate, dash, date, dc, diff, dig, dirname, du, echo, ed,
egrep, ein, env, export, expr, fd, ffmpeg, ffprobe, fgrep, find, fzf, gix,
grep, gunzip, gzip, head, host, hx, id, identify, ifconfig, import, jq, jsc,
jsc_core, kpsewhich, less, lessecho, lex, lg2, link, ln, ls, lua, luac,
magick, magick-script, make, man, mandoc, mandocdb, md5, mkdir, mogrify,
montage, more, multimarkdown, mv, navi, nc, node, npm, npx, nslookup, open,
openrsync, openurl, pbcopy, pbpaste, perl, perl5, pico, ping, ping6,
printenv, pwd, python, python3, python3.13, readlink, realpath, rg, rlogin,
rm, rmdir, rsync, ruff, say, scp, sed, setenv, sftp, sh, sha1, sha256, sleep,
sort, source, ssh, ssh-add, ssh-agent, ssh-keygen, stat, stream, stty, sum,
sw_vers, tail, tar, task, tee, telnet, touch, tr, true, type, unalias, uname,
uncompress, uniq, unlink, unrar, unsetenv, uptime, vim, wasm3, wasmkit, wc,
whatis, whoami, whois, wol, xargs, xcode-select, xxd
```

### 1.3 Catalogue **mini** — **136** khóa

Giống full **trừ** (chỉ có trên full):

`cbc, codex, ein, fd, fzf, gix, hx, kpsewhich, make, navi, node, npm, npx, perl, perl5, realpath, rg, ruff, sw_vers, true, type, xcode-select`

### 1.4 Nhóm chức năng (iOS)

| Nhóm | Ví dụ lệnh |
|------|------------|
| Shell / file | `sh`, `dash`, `ls`, `cp`, `mv`, `rm`, `mkdir`, `find`, `tar`, `gzip`… |
| Text / filter | `grep`, `sed`, `awk`, `jq`, `rg` (full), `fd` (full), `fzf` (full) |
| Mạng | `curl`, `ssh`, `scp`, `sftp`, `ping`, `nc`, `dig`, `nslookup`, `whois`… |
| Ngôn ngữ | `python3`, `lua`, `jsc`, `perl` (full), `node`/`npm` (full) |
| Editor | `vim`, `ed`, `pico`, `hx` (full) |
| Git | `lg2`, `gix` (full) |
| Media / ImageMagick | `ffmpeg`, `ffprobe`, `magick`, `convert`… |
| WASM runners | `wasm3`, `wasmkit` (+ file `.wasm` / `pkg`) |
| AI (full, iOS mới) | `codex` (cần xcframework build) |

Thêm lệnh qua **`pkg`** (script từ `a-Shell-commands`, thường `.wasm`) — không nằm cố định trong plist trên.

**Thực thi:** không `fork`/`exec` Unix; `ios_system` + WASM (xem `Docs/feature-status-report-2026-11-26.md` §1.1).

---

## 2. Windows

| Thành phần trong monorepo | Lệnh shell nhúng? |
|---------------------------|-------------------|
| SwiftTerm (library / WASM web) | **Không** — chỉ vẽ/điều khiển terminal |
| a-Shell | **Không hỗ trợ Windows** |

Trên Windows bạn có thể:

- Chạy **emulator** SwiftTerm WASM trong browser (không có 158 lệnh a-Shell).
- Gắn terminal vào shell Windows/WSL **bên ngoài** thư viện — đó là host OS, không phải catalogue fork này.

---

## 3. Android APK

| Thành phần | Có APK / bộ lệnh? |
|------------|-------------------|
| a-Shell | **Không** — không có port Android trong upstream hay fork |
| SwiftTerm `Package.swift` | Platform `.android` cho **PortableGraphics** (thư viện), **không** ship app APK hay `commandDictionary` |

Muốn shell trên Android cần app khác (ví dụ Termux) — **ngoài** monorepo này.

---

## 4. Kết luận

- **Chỉ iOS (a-Shell)** trong stack của bạn có **danh sách lệnh terminal thực thi** (~158 full / ~136 mini + host builtins + `pkg`).  
- **Windows / APK:** không có bộ lệnh a-Shell; SwiftTerm không thay thế catalogue đó.
