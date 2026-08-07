#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
harness_dir=$(cd "$script_dir/.." && pwd)
repository_root=$(cd "$harness_dir/../.." && pwd)
derived_data=${BIDI_HARNESS_DERIVED_DATA:-"${TMPDIR:-/tmp}/SwiftTermBidiHarnessDerivedData"}
runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/swiftterm-bidi-harness.XXXXXX")
socket_path="$runtime_dir/control.sock"
capture_socket_path="$runtime_dir/capture.sock"
artifact_root="$runtime_dir/artifacts"
run_id=$(date -u +%Y%m%dT%H%M%SZ)
build=true

while (($#)); do
    case "$1" in
        --artifacts) artifact_root=$2; shift 2 ;;
        --socket) socket_path=$2; shift 2 ;;
        --run-id) run_id=$2; shift 2 ;;
        --no-build) build=false; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

cd "$harness_dir"
xcodegen generate --quiet
if $build; then
    xcodebuild \
        -project BidiHarness.xcodeproj \
        -scheme BidiHarness \
        -configuration Debug \
        -derivedDataPath "$derived_data" \
        CODE_SIGNING_ALLOWED=NO \
        build >/dev/null
fi

executable="$derived_data/Build/Products/Debug/BidiHarness.app/Contents/MacOS/BidiHarness"
if [[ ! -x "$executable" ]]; then
    echo "Harness executable not found: $executable" >&2
    exit 1
fi

mkdir -p "$artifact_root" "$(dirname "$socket_path")"
log_path="$runtime_dir/harness.log"
git_revision=$(git -C "$repository_root" rev-parse HEAD)
open -n -F \
    -o "$log_path" \
    --stderr "$log_path" \
    --env "SWIFTTERM_GIT_SHA=$git_revision" \
    --env "SWIFTTERM_CAPTURE_SOCKET=$capture_socket_path" \
    "$derived_data/Build/Products/Debug/BidiHarness.app" --args \
    --socket "$socket_path" \
    --artifacts "$artifact_root" \
    --run-id "$run_id"

for _ in $(seq 1 200); do
    [[ -S "$socket_path" ]] && break
    sleep 0.05
done
if [[ ! -S "$socket_path" ]]; then
    echo "Harness did not create its control socket" >&2
    exit 1
fi

ping_json=$("$script_dir/harnessctl.py" --socket "$socket_path" ping)
pid=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pid"])' <<<"$ping_json")

capture_log_path="$runtime_dir/capture-helper.log"
nohup "$script_dir/capture-helper.py" \
    --socket "$capture_socket_path" \
    --watch-pid "$pid" \
    </dev/null >"$capture_log_path" 2>&1 &
capture_pid=$!
for _ in $(seq 1 100); do
    [[ -S "$capture_socket_path" ]] && break
    kill -0 "$capture_pid" 2>/dev/null || break
    sleep 0.05
done
if [[ ! -S "$capture_socket_path" ]]; then
    echo "Capture helper did not create its socket" >&2
    cat "$capture_log_path" >&2
    exit 1
fi

python3 - "$pid" "$socket_path" "$capture_socket_path" "$artifact_root" "$run_id" "$log_path" "$capture_log_path" <<'PY'
import json
import sys

print(json.dumps({
    "pid": int(sys.argv[1]),
    "socket": sys.argv[2],
    "captureSocket": sys.argv[3],
    "artifactRoot": sys.argv[4],
    "runID": sys.argv[5],
    "log": sys.argv[6],
    "captureLog": sys.argv[7],
}, sort_keys=True))
PY
