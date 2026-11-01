#!/usr/bin/env bash
# Fails when a hot-path type in SwiftTerm has a run-time field layout.
#
# A stored field of a resilient type from another module (URL, Date, UUID,
# Locale, ...) gives the containing type a layout that is known only at run
# time. Then each field access must load the field offset first. One such
# field in Terminal cost 8% more instructions on the scrolling benchmark
# (commit 17e6c5e8).
#
# The compiler emits a "type metadata completion function" for each type
# with a run-time layout. This script makes sure that none of the types
# below has one.
#
# Usage:
#   scripts/check-fixed-layout.sh            # builds release, checks SwiftTerm.o
#   scripts/check-fixed-layout.sh <binary>   # checks an object file or binary
#
# The binary must keep its symbols. A stripped app binary gives no result.
set -euo pipefail
cd "$(dirname "$0")/.."

# Types that the parse and scroll paths access for each byte or each line.
FIXED_TYPES=(
    Terminal
    TerminalOptions
    Buffer
    BufferLine
    CircularBufferLineList
    CellStoragePage
    CellArena
)

if [[ $# -gt 0 ]]; then
    binary="$1"
else
    swift build -c release --product SwiftTerm >&2
    binary="$(swift build -c release --show-bin-path)/SwiftTerm.o"
fi

if [[ ! -f "$binary" ]]; then
    echo "error: $binary does not exist" >&2
    exit 2
fi

if [[ -z "$(nm "$binary" | grep -m1 'SwiftTerm' || true)" ]]; then
    echo "error: $binary has no SwiftTerm symbols (stripped?)" >&2
    exit 2
fi

completions="$(nm "$binary" | xcrun swift-demangle \
    | sed -n 's/.*type metadata completion function for SwiftTerm\.//p' \
    | sort -u)"

failed=0
for type in "${FIXED_TYPES[@]}"; do
    if grep -qx "$type" <<< "$completions"; then
        echo "error: SwiftTerm.$type has a run-time field layout." >&2
        failed=1
    fi
done

if [[ $failed -ne 0 ]]; then
    cat >&2 <<'EOF'

A stored field of a resilient type (URL, Date, UUID, Locale, ...) in this
type, or in a struct that it stores, causes this. Put the field behind a
reference (a final class box), as KittyGraphicsConfiguration does for
trustedTemporaryDirectory. See "Keep a fixed field layout" in PERFORMANCE.md.
EOF
    exit 1
fi

echo "OK: ${FIXED_TYPES[*]} have a fixed field layout."
