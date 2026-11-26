# Setup Web WASM trên Cloudflare

**Mục tiêu:** chạy demo Canvas SwiftTerm (HTTP/HTTPS) qua Cloudflare.  
**Không phải** a-Shell iOS. Demo = stream local trong browser, **không** PTY/shell.

---

## Giới hạn quan trọng

| Artifact | Size | Cloudflare Pages |
|----------|------|------------------|
| `swiftterm-embedded.wasm` | ~0.9 MiB | **OK** — dùng mặc định |
| `swiftterm-full.wasm` | ~54 MiB | **Vượt** giới hạn file Pages (~25 MiB) → dùng **Tunnel** hoặc **R2** |

HTTPS: Cloudflare Pages/Tunnel terminate TLS giúp bạn (edge HTTPS).

---

## A. Deploy Cloudflare Pages (khuyến nghị)

### 1. Một lần trên Cloudflare Dashboard

1. Tạo API Token: **Account → Cloudflare Pages → Edit** (+ Account Settings Read nếu cần).  
2. Lấy **Account ID** (sidebar Overview).  
3. (Tuỳ chọn) tạo sẵn Pages project tên `swiftterm-web`.

### 2. Secrets trên GitHub (`jiaomeimei0-prog/SwiftTerm`)

| Secret | Giá trị |
|--------|---------|
| `CLOUDFLARE_API_TOKEN` | token vừa tạo |
| `CLOUDFLARE_ACCOUNT_ID` | account id |

### 3. Deploy

- **CI:** push `main` (đổi `Web/**`) hoặc chạy workflow **Cloudflare Pages (Web WASM)** (`workflow_dispatch`).  
- **Local:**

```sh
# Cần Web/dist (build hoặc artifact CI)
scripts/build-wasm.sh embedded --browser --release   # hoặc copy artifact
bash scripts/prepare-cloudflare-web.sh
cd Web/cloudflare && npm install
export CLOUDFLARE_API_TOKEN=... CLOUDFLARE_ACCOUNT_ID=...
npm run deploy
```

Site output: `Web/cloudflare/site/` · config: `Web/cloudflare/wrangler.toml`.

URL dạng: `https://swiftterm-web.<account>.pages.dev/`

---

## B. Cloudflare Tunnel (full WASM / máy local)

Khi cần **full** wasm hoặc serve từ laptop/Windows:

```sh
# Repo root — đã có Web/dist (full + embedded)
python3 -m http.server 8000
# Mở: http://127.0.0.1:8000/Web/example/?variant=embedded
#     http://127.0.0.1:8000/Web/example/          (full, nếu có file)

# Tunnel (cài cloudflared, login Cloudflare):
cloudflared tunnel --url http://127.0.0.1:8000
```

Gán hostname cố định trong Zero Trust → Networks → Tunnels nếu cần domain của bạn.

---

## C. HTTP local (không Cloudflare)

```sh
# Từ root monorepo, với Web/dist đã chuẩn bị:
python3 -m http.server 8000
# → http://127.0.0.1:8000/Web/example/?variant=embedded
```

---

## File trong repo

| Path | Vai trò |
|------|---------|
| `Web/cloudflare/site/` | Static site Pages (embedded) |
| `Web/cloudflare/wrangler.toml` | Wrangler Pages config |
| `scripts/prepare-cloudflare-web.sh` | Ghép site từ `Web/dist` |
| `.github/workflows/cloudflare-pages-web.yml` | Build embedded + deploy |

PTY/shell trên Windows vẫn theo [`host-ui-backend-web-windows.md`](host-ui-backend-web-windows.md) (WebSocket → WSL/remote) — ngoài scope Pages demo.
