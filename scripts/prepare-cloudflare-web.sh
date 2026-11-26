#!/usr/bin/env bash
# Assemble Web/cloudflare/site from Web/dist (embedded WASM for Pages size limits).
# Output uses site/pkg/ (not site/dist/) so Web/.gitignore `dist/` does not exclude it.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f Web/dist/swiftterm-embedded.wasm ]]; then
  echo "Missing Web/dist/swiftterm-embedded.wasm" >&2
  echo "Build: scripts/build-wasm.sh embedded --browser --release" >&2
  echo "Or download CI artifact swiftterm-web-wasm into Web/dist/" >&2
  exit 1
fi
rm -rf Web/cloudflare/site
mkdir -p Web/cloudflare/site/pkg/example Web/cloudflare/site/pkg/src
cp Web/dist/*.js Web/dist/*.d.ts Web/dist/package.json Web/dist/LICENSE Web/cloudflare/site/pkg/ 2>/dev/null || true
cp Web/dist/swiftterm-embedded.wasm Web/cloudflare/site/pkg/
cp Web/dist/src/* Web/cloudflare/site/pkg/src/
cp Web/dist/example/* Web/cloudflare/site/pkg/example/
ln -sfn . Web/cloudflare/site/pkg/dist
cp Web/example/index.html Web/cloudflare/site/index.html
python3 - <<'PY'
from pathlib import Path
index = Path('Web/cloudflare/site/index.html')
t = index.read_text()
t = t.replace('SwiftTerm Canvas example', 'SwiftTerm WASM (Cloudflare)')
t = t.replace('src="../dist/example/main.js"', 'src="./pkg/example/main.js"')
t = t.replace(
    'This example has a local data stream. It does not start a shell or connect to a PTY.',
    'Cloudflare Pages demo (embedded WASM). Local stream only — no PTY. '
    'Full WASM exceeds Pages file size limits; use Tunnel/R2 for full.',
)
index.write_text(t)
main = Path('Web/cloudflare/site/pkg/example/main.js')
m = main.read_text()
m = m.replace(
    'wasmURL: `../dist/swiftterm-${variant}.wasm`',
    "wasmURL: '/pkg/swiftterm-embedded.wasm'",
)
main.write_text(m)
PY
cat > Web/cloudflare/site/_headers <<'EOFHEADERS'
/*
  X-Content-Type-Options: nosniff

/*.wasm
  Content-Type: application/wasm
  Cache-Control: public, max-age=3600

/pkg/*
  Cache-Control: public, max-age=3600
EOFHEADERS
printf '%s\n' '/ /index.html 200' > Web/cloudflare/site/_redirects
echo "Prepared Web/cloudflare/site ($(du -sh Web/cloudflare/site | awk '{print $1}'))"
