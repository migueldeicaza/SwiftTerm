# Catalogue đầy đủ lệnh a-Shell (158 + mở rộng)

**Nguồn tip:** `Apps/a-Shell` `@ f47f284c` · `Resources/commandDictionary.plist`
**Ngày:** 2026-11-26 (Asia/Saigon)
**Thực thi (iOS):** `ios_system` in-process (`ios_fork` + `ios_system`) — không `fork`/`exec` Unix; một số lệnh thêm qua WASM/`pkg`.

Tham chiếu nền tảng: [`commands-by-platform-2026-11-26.md`](commands-by-platform-2026-11-26.md).

---

## 0. Tổng số

| Nguồn | Số lệnh | Ghi chú |
|-------|---------|---------|
| `commandDictionary.plist` (full) | **158** | Catalogue chính App Store full |
| `Resources_mini/commandDictionary.plist` | **136** | a-Shell mini |
| Chỉ có trên full (không mini) | 22 | xem §2 |
| `extraCommandsDictionary.plist` | 8 | Bổ sung (một phần trùng tên) |
| `llvmDictionary.plist` | 10 | clang / lld / ar… |
| `texCommandsDictionary.plist` | 31 | pdfTeX family |
| `luatexCommandsDictionary.plist` | 7 | LuaTeX / XeTeX |
| Host builtins (app) | ~10 | `help`, `config`, `pkg`, `relay`… — không nằm trong 158 |

**Windows / Android:** không có catalogue này — xem doc nền tảng.

---

## 1. Bảng đầy đủ — 158 lệnh `commandDictionary`

| # | Lệnh | Nhóm | Framework | Symbol | Full | Mini | Arg type |
|---|------|------|-----------|--------|------|------|----------|
| 1 | `alias` | Shell builtin | `SELF (app)` | `alias_main` | ✓ | ✓ | `no` |
| 2 | `apropos` | Man / docs | `mandoc.framework` | `main` | ✓ | ✓ | `no` |
| 3 | `awk` | Text / filter / archive | `awk.framework` | `awk_main` | ✓ | ✓ | `file` |
| 4 | `base64` | Text / filter / archive | `files.framework` | `base64_main` | ✓ | ✓ | `file` |
| 5 | `basename` | File / FS | `shell.framework` | `basename_main` | ✓ | ✓ | `file` |
| 6 | `bc` | Language / calc / make | `bc_ios.framework` | `bcdc_main` | ✓ | ✓ | `no` |
| 7 | `blink` | Clipboard / UI / system info | `blink.framework` | `main` | ✓ | ✓ | `file` |
| 8 | `calc` | Language / calc / make | `calc.framework` | `main` | ✓ | ✓ | `no` |
| 9 | `cat` | Text / filter / archive | `text.framework` | `cat_main` | ✓ | ✓ | `file` |
| 10 | `cbc` | Other | `cbc.framework` | `main` | ✓ | — | `file` |
| 11 | `cd` | Shell builtin | `SELF (app)` | `cd_main` | ✓ | ✓ | `directory` |
| 12 | `chdir` | Shell builtin | `SELF (app)` | `cd_main` | ✓ | ✓ | `directory` |
| 13 | `chflags` | File / FS | `files.framework` | `chflags_main` | ✓ | ✓ | `file` |
| 14 | `chmod` | File / FS | `files.framework` | `chmod_main` | ✓ | ✓ | `file` |
| 15 | `cksum` | Text / filter / archive | `files.framework` | `chksum_main` | ✓ | ✓ | `file` |
| 16 | `codex` | AI CLI | `codex.framework` | `codex_ios_main` | ✓ | — | `file` |
| 17 | `compare` | ImageMagick | `magick.framework` | `main` | ✓ | ✓ | `file` |
| 18 | `composite` | ImageMagick | `magick.framework` | `main` | ✓ | ✓ | `file` |
| 19 | `compress` | Text / filter / archive | `files.framework` | `compress_main` | ✓ | ✓ | `file` |
| 20 | `conjure` | ImageMagick | `magick.framework` | `main` | ✓ | ✓ | `file` |
| 21 | `convert` | ImageMagick | `magick.framework` | `main` | ✓ | ✓ | `file` |
| 22 | `cp` | File / FS | `files.framework` | `cp_main` | ✓ | ✓ | `file` |
| 23 | `curl` | Network | `curl_ios.framework` | `curl_main` | ✓ | ✓ | `file` |
| 24 | `curl-impersonate` | Network | `curl-impersonate.framework` | `main` | ✓ | ✓ | `file` |
| 25 | `dash` | Shell binary | `dash.framework` | `main` | ✓ | ✓ | `no` |
| 26 | `date` | Clipboard / UI / system info | `shell.framework` | `date_main` | ✓ | ✓ | `no` |
| 27 | `dc` | Language / calc / make | `bc_ios.framework` | `bcdc_main` | ✓ | ✓ | `no` |
| 28 | `diff` | Text / filter / archive | `text.framework` | `diff_main` | ✓ | ✓ | `file` |
| 29 | `dig` | Network | `network_ios.framework` | `dig_main` | ✓ | ✓ | `no` |
| 30 | `dirname` | File / FS | `shell.framework` | `dirname_main` | ✓ | ✓ | `file` |
| 31 | `du` | File / FS | `files.framework` | `du_main` | ✓ | ✓ | `file` |
| 32 | `echo` | Shell builtin | `shell.framework` | `echo_main` | ✓ | ✓ | `no` |
| 33 | `ed` | Editor | `text.framework` | `ed_main` | ✓ | ✓ | `` |
| 34 | `egrep` | Text / filter / archive | `text.framework` | `grep_main` | ✓ | ✓ | `file` |
| 35 | `ein` | Git | `gitoxide.framework` | `gix_ios_main` | ✓ | — | `file` |
| 36 | `env` | Shell builtin | `shell.framework` | `env_main` | ✓ | ✓ | `no` |
| 37 | `export` | Shell builtin | `shell.framework` | `export_main` | ✓ | ✓ | `no` |
| 38 | `expr` | Language / calc / make | `ssh_agent.framework` | `expr_main` | ✓ | ✓ | `none` |
| 39 | `fd` | Modern search / tools | `fd.framework` | `fd_ios_main` | ✓ | — | `file` |
| 40 | `ffmpeg` | Media (ffmpeg) | `ffmpeg.framework` | `main` | ✓ | ✓ | `file` |
| 41 | `ffprobe` | Media (ffmpeg) | `ffprobe.framework` | `main` | ✓ | ✓ | `file` |
| 42 | `fgrep` | Text / filter / archive | `text.framework` | `grep_main` | ✓ | ✓ | `file` |
| 43 | `find` | File / FS | `shell.framework` | `find_main` | ✓ | ✓ | `directory` |
| 44 | `fzf` | Modern search / tools | `fzf.framework` | `fzf_ios_main` | ✓ | — | `no` |
| 45 | `gix` | Git | `gitoxide.framework` | `gix_ios_main` | ✓ | — | `file` |
| 46 | `grep` | Text / filter / archive | `text.framework` | `grep_main` | ✓ | ✓ | `file` |
| 47 | `gunzip` | Text / filter / archive | `files.framework` | `gzip_main` | ✓ | ✓ | `file` |
| 48 | `gzip` | Text / filter / archive | `files.framework` | `gzip_main` | ✓ | ✓ | `file` |
| 49 | `head` | Text / filter / archive | `text.framework` | `head_main` | ✓ | ✓ | `file` |
| 50 | `host` | Network | `network_ios.framework` | `host_main` | ✓ | ✓ | `no` |
| 51 | `hx` | Editor | `helix.framework` | `hx_ios_main` | ✓ | — | `file` |
| 52 | `id` | Clipboard / UI / system info | `shell.framework` | `id_main` | ✓ | ✓ | `no` |
| 53 | `identify` | ImageMagick | `magick.framework` | `main` | ✓ | ✓ | `file` |
| 54 | `ifconfig` | Network | `network_ios.framework` | `ifconfig_main` | ✓ | ✓ | `no` |
| 55 | `import` | ImageMagick | `magick.framework` | `main` | ✓ | ✓ | `file` |
| 56 | `jq` | Markup / JSON | `jq.framework` | `main` | ✓ | ✓ | `file` |
| 57 | `jsc` | Language — JS / Node | `shell.framework` | `jsc` | ✓ | ✓ | `file` |
| 58 | `jsc_core` | Language — JS / Node | `shell.framework` | `jsc` | ✓ | ✓ | `file` |
| 59 | `kpsewhich` | TeX helper (main dict) | `kpsewhich.framework` | `main` | ✓ | — | `none` |
| 60 | `less` | Text / filter / archive | `files.framework` | `less_main` | ✓ | ✓ | `no` |
| 61 | `lessecho` | Text / filter / archive | `files.framework` | `lessecho_main` | ✓ | ✓ | `no` |
| 62 | `lex` | Language / calc / make | `lex.framework` | `main` | ✓ | ✓ | `no` |
| 63 | `lg2` | Git | `lg2.framework` | `main` | ✓ | ✓ | `directory` |
| 64 | `link` | File / FS | `files.framework` | `ln_main` | ✓ | ✓ | `file` |
| 65 | `ln` | File / FS | `files.framework` | `ln_main` | ✓ | ✓ | `file` |
| 66 | `ls` | File / FS | `files.framework` | `ls_main` | ✓ | ✓ | `file` |
| 67 | `lua` | Language — Lua | `lua_ios.framework` | `lua_main` | ✓ | ✓ | `file` |
| 68 | `luac` | Language — Lua | `lua_ios.framework` | `luac_main` | ✓ | ✓ | `file` |
| 69 | `magick` | ImageMagick | `magick.framework` | `main` | ✓ | ✓ | `file` |
| 70 | `magick-script` | ImageMagick | `magick.framework` | `main` | ✓ | ✓ | `file` |
| 71 | `make` | Language / calc / make | `make.framework` | `main` | ✓ | — | `file` |
| 72 | `man` | Man / docs | `mandoc.framework` | `main` | ✓ | ✓ | `no` |
| 73 | `mandoc` | Man / docs | `mandoc.framework` | `main` | ✓ | ✓ | `no` |
| 74 | `mandocdb` | Man / docs | `mandoc.framework` | `main` | ✓ | ✓ | `no` |
| 75 | `md5` | Text / filter / archive | `text.framework` | `md5_main` | ✓ | ✓ | `file` |
| 76 | `mkdir` | File / FS | `files.framework` | `mkdir_main` | ✓ | ✓ | `directory` |
| 77 | `mogrify` | ImageMagick | `magick.framework` | `main` | ✓ | ✓ | `file` |
| 78 | `montage` | ImageMagick | `magick.framework` | `main` | ✓ | ✓ | `file` |
| 79 | `more` | Text / filter / archive | `files.framework` | `less_main` | ✓ | ✓ | `no` |
| 80 | `multimarkdown` | Markup / JSON | `multimarkdown.framework` | `main` | ✓ | ✓ | `file` |
| 81 | `mv` | File / FS | `files.framework` | `mv_main` | ✓ | ✓ | `file` |
| 82 | `navi` | Modern search / tools | `navi.framework` | `navi_ios_main` | ✓ | — | `no` |
| 83 | `nc` | Network | `network_ios.framework` | `netcat_main` | ✓ | ✓ | `no` |
| 84 | `node` | Language — JS / Node | `node.framework` | `node_ios_main` | ✓ | — | `file` |
| 85 | `npm` | Language — JS / Node | `node.framework` | `npm_ios_main` | ✓ | — | `file` |
| 86 | `npx` | Language — JS / Node | `node.framework` | `npx_ios_main` | ✓ | — | `file` |
| 87 | `nslookup` | Network | `network_ios.framework` | `nslookup_main` | ✓ | ✓ | `no` |
| 88 | `open` | Clipboard / UI / system info | `shell.framework` | `open_main` | ✓ | ✓ | `no` |
| 89 | `openrsync` | Network | `openrsync.framework` | `main` | ✓ | ✓ | `file` |
| 90 | `openurl` | Clipboard / UI / system info | `shell.framework` | `openurl_main` | ✓ | ✓ | `no` |
| 91 | `pbcopy` | Clipboard / UI / system info | `SELF (app)` | `pbcopy` | ✓ | ✓ | `no` |
| 92 | `pbpaste` | Clipboard / UI / system info | `SELF (app)` | `pbpaste` | ✓ | ✓ | `no` |
| 93 | `perl` | Language — Perl | `perl.framework` | `main` | ✓ | — | `file` |
| 94 | `perl5` | Language — Perl | `perl.framework` | `main` | ✓ | — | `none` |
| 95 | `pico` | Editor | `pico.framework` | `main` | ✓ | ✓ | `file` |
| 96 | `ping` | Network | `network_ios.framework` | `ping_main` | ✓ | ✓ | `no` |
| 97 | `ping6` | Network | `network_ios.framework` | `ping6_main` | ✓ | ✓ | `no` |
| 98 | `printenv` | Shell builtin | `shell.framework` | `printenv_main` | ✓ | ✓ | `no` |
| 99 | `pwd` | Shell builtin | `shell.framework` | `pwd_main` | ✓ | ✓ | `no` |
| 100 | `python` | Language — Python | `Python.framework` | `Py_BytesMain` | ✓ | ✓ | `file` |
| 101 | `python3` | Language — Python | `Python.framework` | `Py_BytesMain` | ✓ | ✓ | `file` |
| 102 | `python3.13` | Language — Python | `Python.framework` | `Py_BytesMain` | ✓ | ✓ | `file` |
| 103 | `readlink` | File / FS | `files.framework` | `stat_main` | ✓ | ✓ | `file` |
| 104 | `realpath` | File / FS | `shell.framework` | `realpath_main` | ✓ | — | `file` |
| 105 | `rg` | Modern search / tools | `rg.framework` | `rg_ios_main` | ✓ | — | `file` |
| 106 | `rlogin` | Network | `network_ios.framework` | `telnet_main` | ✓ | ✓ | `no` |
| 107 | `rm` | File / FS | `files.framework` | `rm_main` | ✓ | ✓ | `file` |
| 108 | `rmdir` | File / FS | `files.framework` | `rmdir_main` | ✓ | ✓ | `directory` |
| 109 | `rsync` | Network | `openrsync.framework` | `main` | ✓ | ✓ | `file` |
| 110 | `ruff` | Modern search / tools | `Ruff.framework` | `ruff_ios_main` | ✓ | — | `file` |
| 111 | `say` | Clipboard / UI / system info | `text.framework` | `say_main` | ✓ | ✓ | `no` |
| 112 | `scp` | Network | `ssh_cmd.framework` | `scp_main` | ✓ | ✓ | `file` |
| 113 | `sed` | Text / filter / archive | `text.framework` | `sed_main` | ✓ | ✓ | `file` |
| 114 | `setenv` | Shell builtin | `shell.framework` | `setenv_main` | ✓ | ✓ | `no` |
| 115 | `sftp` | Network | `ssh_cmd.framework` | `sftp_main` | ✓ | ✓ | `file` |
| 116 | `sh` | Shell binary | `SELF (app)` | `sh_main` | ✓ | ✓ | `file` |
| 117 | `sha1` | Text / filter / archive | `text.framework` | `md5_main` | ✓ | ✓ | `file` |
| 118 | `sha256` | Text / filter / archive | `text.framework` | `md5_main` | ✓ | ✓ | `file` |
| 119 | `sleep` | Clipboard / UI / system info | `shell.framework` | `sleep_main` | ✓ | ✓ | `none` |
| 120 | `sort` | Text / filter / archive | `text.framework` | `sort_main` | ✓ | ✓ | `file` |
| 121 | `source` | Shell builtin | `shell.framework` | `source` | ✓ | ✓ | `file` |
| 122 | `ssh` | Network | `ssh_cmd.framework` | `ssh_main` | ✓ | ✓ | `no` |
| 123 | `ssh-add` | Network | `ssh_agent.framework` | `ssh_add_main` | ✓ | ✓ | `none` |
| 124 | `ssh-agent` | Network | `ssh_agent.framework` | `main` | ✓ | ✓ | `none` |
| 125 | `ssh-keygen` | Network | `ssh_cmd.framework` | `sshkeygen_main` | ✓ | ✓ | `file` |
| 126 | `stat` | File / FS | `files.framework` | `stat_main` | ✓ | ✓ | `file` |
| 127 | `stream` | ImageMagick | `magick.framework` | `main` | ✓ | ✓ | `file` |
| 128 | `stty` | Clipboard / UI / system info | `shell.framework` | `stty_main` | ✓ | ✓ | `no` |
| 129 | `sum` | Text / filter / archive | `files.framework` | `chksum_main` | ✓ | ✓ | `file` |
| 130 | `sw_vers` | Clipboard / UI / system info | `SELF (app)` | `sw_vers` | ✓ | — | `no` |
| 131 | `tail` | Text / filter / archive | `text.framework` | `tail_main` | ✓ | ✓ | `file` |
| 132 | `tar` | Text / filter / archive | `tar.framework` | `tar_main` | ✓ | ✓ | `file` |
| 133 | `task` | Modern search / tools | `task.framework` | `main` | ✓ | ✓ | `no` |
| 134 | `tee` | Text / filter / archive | `shell.framework` | `tee_main` | ✓ | ✓ | `file` |
| 135 | `telnet` | Network | `network_ios.framework` | `telnet_main` | ✓ | ✓ | `no` |
| 136 | `touch` | File / FS | `files.framework` | `touch_main` | ✓ | ✓ | `file` |
| 137 | `tr` | Text / filter / archive | `text.framework` | `tr_main` | ✓ | ✓ | `no` |
| 138 | `true` | Shell builtin | `SELF (app)` | `true_main` | ✓ | — | `no` |
| 139 | `type` | Shell builtin | `SELF (app)` | `type_main` | ✓ | — | `no` |
| 140 | `unalias` | Shell builtin | `SELF (app)` | `unalias_main` | ✓ | ✓ | `no` |
| 141 | `uname` | Clipboard / UI / system info | `shell.framework` | `uname_main` | ✓ | ✓ | `no` |
| 142 | `uncompress` | Text / filter / archive | `files.framework` | `compress_main` | ✓ | ✓ | `file` |
| 143 | `uniq` | Text / filter / archive | `text.framework` | `uniq_main` | ✓ | ✓ | `file` |
| 144 | `unlink` | File / FS | `files.framework` | `rm_main` | ✓ | ✓ | `file` |
| 145 | `unrar` | Text / filter / archive | `unrar.framework` | `main` | ✓ | ✓ | `directory` |
| 146 | `unsetenv` | Shell builtin | `shell.framework` | `unsetenv_main` | ✓ | ✓ | `no` |
| 147 | `uptime` | Clipboard / UI / system info | `shell.framework` | `w_main` | ✓ | ✓ | `no` |
| 148 | `vim` | Editor | `vim.framework` | `main` | ✓ | ✓ | `` |
| 149 | `wasm3` | WASM runner | `shell.framework` | `wasm3` | ✓ | ✓ | `file` |
| 150 | `wasmkit` | WASM runner | `WasmKitCommand.framework` | `wasmkit` | ✓ | ✓ | `file` |
| 151 | `wc` | Text / filter / archive | `text.framework` | `wc_main` | ✓ | ✓ | `file` |
| 152 | `whatis` | Man / docs | `mandoc.framework` | `main` | ✓ | ✓ | `no` |
| 153 | `whoami` | Clipboard / UI / system info | `shell.framework` | `id_main` | ✓ | ✓ | `no` |
| 154 | `whois` | Network | `network_ios.framework` | `whois_main` | ✓ | ✓ | `no` |
| 155 | `wol` | Network | `network_ios.framework` | `_Z8wol_mainiPKPc` | ✓ | ✓ | `no` |
| 156 | `xargs` | Text / filter / archive | `shell.framework` | `xargs_main` | ✓ | ✓ | `no` |
| 157 | `xcode-select` | Clipboard / UI / system info | `SELF (app)` | `xcode_select` | ✓ | — | `no` |
| 158 | `xxd` | Text / filter / archive | `xxd.framework` | `main` | ✓ | ✓ | `file` |

---

## 2. Chỉ có trên bản full (không có trên mini)

`cbc`, `codex`, `ein`, `fd`, `fzf`, `gix`, `hx`, `kpsewhich`, `make`, `navi`, `node`, `npm`, `npx`, `perl`, `perl5`, `realpath`, `rg`, `ruff`, `sw_vers`, `true`, `type`, `xcode-select`

---

## 3. Phân nhóm (158 lệnh)

| Nhóm | Số | Lệnh |
|------|----|------|
| Text / filter / archive | 31 | `awk`, `base64`, `cat`, `cksum`, `compress`, `diff`, `egrep`, `fgrep`, `grep`, `gunzip`, `gzip`, `head`, `less`, `lessecho`, `md5`, `more`, `sed`, `sha1`, `sha256`, `sort`, `sum`, `tail`, `tar`, `tee`, `tr`, `uncompress`, `uniq`, `unrar`, `wc`, `xargs`, `xxd` |
| Network | 21 | `curl`, `curl-impersonate`, `dig`, `host`, `ifconfig`, `nc`, `nslookup`, `openrsync`, `ping`, `ping6`, `rlogin`, `rsync`, `scp`, `sftp`, `ssh`, `ssh-add`, `ssh-agent`, `ssh-keygen`, `telnet`, `whois`, `wol` |
| File / FS | 19 | `basename`, `chflags`, `chmod`, `cp`, `dirname`, `du`, `find`, `link`, `ln`, `ls`, `mkdir`, `mv`, `readlink`, `realpath`, `rm`, `rmdir`, `stat`, `touch`, `unlink` |
| Clipboard / UI / system info | 15 | `blink`, `date`, `id`, `open`, `openurl`, `pbcopy`, `pbpaste`, `say`, `sleep`, `stty`, `sw_vers`, `uname`, `uptime`, `whoami`, `xcode-select` |
| Shell builtin | 14 | `alias`, `cd`, `chdir`, `echo`, `env`, `export`, `printenv`, `pwd`, `setenv`, `source`, `true`, `type`, `unalias`, `unsetenv` |
| ImageMagick | 11 | `compare`, `composite`, `conjure`, `convert`, `identify`, `import`, `magick`, `magick-script`, `mogrify`, `montage`, `stream` |
| Language / calc / make | 6 | `bc`, `calc`, `dc`, `expr`, `lex`, `make` |
| Modern search / tools | 6 | `fd`, `fzf`, `navi`, `rg`, `ruff`, `task` |
| Man / docs | 5 | `apropos`, `man`, `mandoc`, `mandocdb`, `whatis` |
| Language — JS / Node | 5 | `jsc`, `jsc_core`, `node`, `npm`, `npx` |
| Editor | 4 | `ed`, `hx`, `pico`, `vim` |
| Git | 3 | `ein`, `gix`, `lg2` |
| Language — Python | 3 | `python`, `python3`, `python3.13` |
| Language — Lua | 2 | `lua`, `luac` |
| Language — Perl | 2 | `perl`, `perl5` |
| Markup / JSON | 2 | `jq`, `multimarkdown` |
| Media (ffmpeg) | 2 | `ffmpeg`, `ffprobe` |
| Shell binary | 2 | `dash`, `sh` |
| WASM runner | 2 | `wasm3`, `wasmkit` |
| AI CLI | 1 | `codex` |
| Other | 1 | `cbc` |
| TeX helper (main dict) | 1 | `kpsewhich` |

---

## 4. Dictionary mở rộng (không tính trong 158)

### Extra commands (`extraCommandsDictionary`) — 8 lệnh

| Lệnh | Framework | Symbol |
|------|-----------|--------|
| `chgrp` | `files.framework` | `chown_main` |
| `chmod` | `files.framework` | `chmod_main` |
| `chown` | `files.framework` | `chown_main` |
| `ctags` | `libctags.dylib` | `ctags_main` |
| `df` | `files.framework` | `df_main` |
| `id` | `shell.framework` | `id_main` |
| `readtags` | `libctags.dylib` | `readtags_main` |
| `w` | `shell.framework` | `w_main` |

### LLVM / clang (`llvmDictionary`) — 10 lệnh

| Lệnh | Framework | Symbol |
|------|-----------|--------|
| `ar` | `ar.framework` | `main` |
| `clang` | `clang.framework` | `main` |
| `clang++` | `clang.framework` | `main` |
| `ld` | `lld.framework` | `main` |
| `ld.lld` | `lld.framework` | `main` |
| `ld64.lld` | `lld.framework` | `main` |
| `lld` | `lld.framework` | `main` |
| `lld-link` | `lld.framework` | `main` |
| `ranlib` | `ar.framework` | `main` |
| `wasm-ld` | `lld.framework` | `main` |

### TeX (pdfTeX…) (`texCommandsDictionary`) — 31 lệnh

| Lệnh | Framework | Symbol |
|------|-----------|--------|
| `amstex` | `pdftex.framework` | `dllpdftexmain` |
| `bibtex` | `bibtex.framework` | `bibtex_main` |
| `cslatex` | `pdftex.framework` | `dllpdftexmain` |
| `csplain` | `pdftex.framework` | `dllpdftexmain` |
| `dvipdfmx` | `xdvipdfmx.framework` | `dlldvipdfmxmain` |
| `eplain` | `pdftex.framework` | `dllpdftexmain` |
| `etex` | `pdftex.framework` | `dllpdftexmain` |
| `euptex` | `euptex.framework` | `dlleuptexmain` |
| `jadetex` | `pdftex.framework` | `dllpdftexmain` |
| `latex` | `pdftex.framework` | `dllpdftexmain` |
| `makeindex` | `makeindex.framework` | `main` |
| `mex` | `pdftex.framework` | `dllpdftexmain` |
| `mllatex` | `pdftex.framework` | `dllpdftexmain` |
| `mltex` | `pdftex.framework` | `dllpdftexmain` |
| `pdfcslatex` | `pdftex.framework` | `dllpdftexmain` |
| `pdfcsplain` | `pdftex.framework` | `dllpdftexmain` |
| `pdfetex` | `pdftex.framework` | `dllpdftexmain` |
| `pdfjadetex` | `pdftex.framework` | `dllpdftexmain` |
| `pdflatex` | `pdftex.framework` | `dllpdftexmain` |
| `pdfmex` | `pdftex.framework` | `dllpdftexmain` |
| `pdftex` | `pdftex.framework` | `dllpdftexmain` |
| `pdfxmltex` | `pdftex.framework` | `dllpdftexmain` |
| `tex` | `pdftex.framework` | `dllpdftexmain` |
| `texlua` | `luatex.framework` | `dllluatexmain` |
| `texluac` | `luatex.framework` | `dllluatexmain` |
| `texsis` | `pdftex.framework` | `dllpdftexmain` |
| `uplatex` | `euptex.framework` | `dlleuptexmain` |
| `uptex` | `euptex.framework` | `dlleuptexmain` |
| `utf8mex` | `pdftex.framework` | `dllpdftexmain` |
| `xdvipdfmx` | `xdvipdfmx.framework` | `dlldvipdfmxmain` |
| `xmltex` | `pdftex.framework` | `dllpdftexmain` |

### LuaTeX / XeTeX (`luatexCommandsDictionary`) — 7 lệnh

| Lệnh | Framework | Symbol |
|------|-----------|--------|
| `dvilualatex` | `luatex.framework` | `dllluatexmain` |
| `dviluatex` | `luatex.framework` | `dllluatexmain` |
| `luahbtex` | `luahbtex.framework` | `dllluatexmain` |
| `lualatex` | `luahbtex.framework` | `dllluatexmain` |
| `luatex` | `luatex.framework` | `dllluatexmain` |
| `xelatex` | `xetex.framework` | `dllxetexmain` |
| `xetex` | `xetex.framework` | `dllxetexmain` |

---

## 5. Host builtins (app — ngoài plist 158)

Đăng ký qua `@_cdecl` trong `ExtraCommands.swift` / `Relay.swift` (không nằm trong 158 khóa chính):

| Lệnh / symbol | Cơ chế | Mô tả |
|---------------|--------|-------|
| `help` / `credits` | host | Help / credits |
| `history` / `clear` | host | History / clear screen |
| `config` | host | Font / theme / toolbar |
| `pickFolder` | host | Sandbox folder picker |
| `bookmark` / `showmarks` / `renamemark` / `deletemark` / `jump` | host | Bookmarks |
| `downloadFile` / `downloadFolder` | host | Share sheet downloads |
| `openurl` (`openurl_main`) | host | Open URL |
| `hideKeyboard` / `hideToolbar` / `showToolbar` | host | UI chrome |
| `wasm` / `executeWebAssemblyCommands` | host + WASM | Chạy `.wasm` / pipeline WASM |
| `needLLVM` / `needTeX` / `needLuaTeX` / `updateCommands` | host | Nạp llvm/tex/luatex dictionaries |
| `relay` (`relay_main`) | host | HTTPS `/run` control plane |
| `pkg` | host_script (`Resources/bin/pkg`) | Cài gói từ a-Shell-commands |
| `z` (`z_command`) / `rehash` / `repeatCommand` | host | Tiện ích session |
| `call` / `text` / interactive helpers | host | Tích hợp hệ thống / interactive |

Shortcuts / URL scheme / NSUserActivity cũng gọi cùng đường `ios_system` khi “Execute Command”.

---

## 6. Cách gọi / thực thi

```text
User / Shortcut / Relay /run
        │
        ▼
SceneDelegate.executeCommand
        │
        ▼
ios_fork() + ios_system(command)     hoặc     WASM path (pkg / .wasm)
        │
        ▼
stdout/stderr Pipe → TerminalView.feed
```

| Cột bảng | Ý nghĩa |
|----------|---------|
| Framework | Binary/`xcframework` nhúng trong bundle (hoặc `SELF`) |
| Symbol | Entry `*_main` đăng ký với `ios_system` |
| Arg type | Gợi ý kiểu đối số cho hoàn thành / sandbox (`file`, …) |
| Mini | Có trong a-Shell mini |

Lệnh thêm qua `pkg` (remote install script → thường `.wasm` trong `~/Documents/bin`) **không** liệt kê ở đây.

