#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
node scripts/wasm-artifact.mjs check "$@"
