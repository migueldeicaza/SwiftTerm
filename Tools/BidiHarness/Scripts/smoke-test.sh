#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/swiftterm-bidi-smoke.XXXXXX")
socket_path="$runtime_dir/control.sock"
artifact_root="$runtime_dir/artifacts"
launch_json=$(
    "$script_dir/run-harness.sh" \
        --socket "$socket_path" \
        --artifacts "$artifact_root" \
        --run-id smoke
)
pid=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["pid"])' <<<"$launch_json")

cleanup() {
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

control() {
    "$script_dir/harnessctl.py" --socket "$socket_path" "$@" >/dev/null
}

control ping
control listScenarios
control loadScenario '{"scenario":"author-sample"}'
control gotoStep '{"step":0}'
control resize '{"cols":36,"rows":20}'
control scrollToEdge '{"edge":"bottom"}'
control setRenderer '{"renderer":"coreGraphics"}'
control capture '{"name":"smoke-core-graphics"}'
control setRenderer '{"renderer":"metal"}'
metal_capture="$runtime_dir/metal-capture.json"
if ! "$script_dir/harnessctl.py" --socket "$socket_path" capture '{"name":"smoke-metal"}' >"$metal_capture"; then
    python3 - "$metal_capture" <<'PY'
import json
import sys

response = json.load(open(sys.argv[1]))
if response.get("error", {}).get("code") != "captureUnavailable":
    raise SystemExit("Metal capture failed without the expected captureUnavailable response")
PY
fi
control status
control quit

wait "$pid" 2>/dev/null || true
python3 - "$artifact_root" <<'PY'
from pathlib import Path
import json
import sys

root = Path(sys.argv[1])
images = sorted(root.rglob("*.png"))
manifests = sorted(root.rglob("*.json"))
if len(images) not in {1, 2} or len(manifests) != len(images):
    raise SystemExit(f"expected one or two images and matching manifests, found {len(images)} and {len(manifests)}")
for path in images:
    if path.stat().st_size == 0:
        raise SystemExit(f"empty image: {path}")
for path in manifests:
    data = json.loads(path.read_text())
    if data["renderer"] not in {"coreGraphics", "metal"}:
        raise SystemExit(f"unexpected renderer in {path}")
renderers = {json.loads(path.read_text())["renderer"] for path in manifests}
if "coreGraphics" not in renderers:
    raise SystemExit("the smoke test did not capture Core Graphics")
print(f"BiDi harness smoke test passed: {root} ({', '.join(sorted(renderers))})")
PY
