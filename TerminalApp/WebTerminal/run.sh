#!/usr/bin/env bash
set -euo pipefail
sample_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$sample_dir/../.." && pwd)
cd "$repo_dir"
if [[ ! -x Web/node_modules/.bin/tsc ]]; then
    npm ci --prefix Web
fi
if [[ ! -f Web/dist/swiftterm-full.wasm ]]; then
    scripts/build-wasm.sh full --browser --release
else
    npm run build --prefix Web
fi
exec swift run --package-path "$sample_dir" web-terminal "$@"
