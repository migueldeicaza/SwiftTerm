#!/usr/bin/env bash
# Build the portable command or browser reactor with the pinned Swift SDK.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/wasm-toolchain.env
variant=${1:-full}
if [[ $# -gt 0 ]]; then shift; fi
case "$variant" in full|embedded) ;; *) echo 'Expected full or embedded.' >&2; exit 2;; esac
mode=smoke
configuration=debug
run=0
strip=0
for arg in "$@"; do
    case "$arg" in
        --browser) mode=browser;;
        --smoke) mode=smoke;;
        --release) configuration=release; strip=1;;
        --strip) configuration=release; strip=1;;
        --run) run=1;;
        *) echo "Unknown option: $arg" >&2; exit 2;;
    esac
done
swift_bin=${SWIFTTERM_SWIFT:-}
if [[ -z "$swift_bin" ]]; then
    candidate="$HOME/Library/Developer/Toolchains/$SWIFTTERM_TOOLCHAIN_ID.xctoolchain/usr/bin/swift"
    if [[ -x "$candidate" ]]; then swift_bin="$candidate"; else swift_bin=$(command -v swift); fi
fi
compiler_version=$("$swift_bin" --version)
if [[ "$compiler_version" != *"$SWIFTTERM_COMPILER_REVISION"* ]]; then
    echo "Compiler mismatch. Use $SWIFTTERM_TOOLCHAIN_ID (revision $SWIFTTERM_COMPILER_REVISION)." >&2
    echo 'Set SWIFTTERM_SWIFT to its usr/bin/swift executable.' >&2
    exit 1
fi
sdk_dir=${SWIFTTERM_SWIFT_SDKS_PATH:-$HOME/.swiftpm/swift-sdks}
sdk_base="$sdk_dir/${SWIFTTERM_TOOLCHAIN_ID}_wasm.artifactbundle/${SWIFTTERM_TOOLCHAIN_ID}_wasm/wasm32-unknown-wasip1"
if [[ ! -f "$sdk_base/swift-sdk.json" || ! -f "$sdk_base/embedded-swift-sdk.json" ]]; then
    echo "Matching WASM SDK missing: ${SWIFTTERM_TOOLCHAIN_ID}_wasm" >&2
    echo 'Set SWIFTTERM_SWIFT_SDKS_PATH to the directory that contains the artifact bundle.' >&2
    exit 1
fi
sdk_id="${SWIFTTERM_TOOLCHAIN_ID}_wasm"
traits=Wasm
if [[ "$variant" == embedded ]]; then sdk_id+="-embedded"; traits=Embedded; fi
export SWIFTTERM_WASM_EMBEDDED_LIBDIR="$sdk_base/swift.xctoolchain/usr/lib/swift/embedded/wasm32-unknown-wasip1"
export SWIFTTERM_EXCLUDE_APPLE=1
export SWIFTTERM_WASM=0
export SWIFTTERM_WEB_WASM=0
if [[ "$mode" == browser ]]; then export SWIFTTERM_WEB_WASM=1; product=SwiftTermWebWasm
else export SWIFTTERM_WASM=1; product=SwiftTermWasmSmoke; fi
scratch="$PWD/.build/wasm-$variant"
mkdir -p "$scratch" "$PWD/.build/wasm-cache" "$PWD/.build/wasm-config" "$PWD/.build/wasm-security"
export CLANG_MODULE_CACHE_PATH="$scratch/ModuleCache"
# A clean offline checkout can reuse dependencies that SwiftPM has already resolved.
if [[ ! -f "$scratch/workspace-state.json" && -f .build/workspace-state.json && -d .build/checkouts ]]; then
    cp .build/workspace-state.json "$scratch/workspace-state.json"
    cp -R .build/checkouts "$scratch/checkouts"
    cp -R .build/repositories "$scratch/repositories"
fi
clang_resources="$sdk_base/swift.xctoolchain/usr/lib/clang"
build_args=(--disable-sandbox --skip-update --scratch-path "$scratch"
    --cache-path "$PWD/.build/wasm-cache" --config-path "$PWD/.build/wasm-config"
    --security-path "$PWD/.build/wasm-security" --swift-sdks-path "$sdk_dir"
    --swift-sdk "$sdk_id" --traits "$traits" -c "$configuration"
    -Xswiftc -Xclang-linker -Xswiftc -resource-dir -Xswiftc -Xclang-linker -Xswiftc "$clang_resources")
if [[ "$configuration" == release ]]; then build_args+=(-debug-info-format none); fi
if [[ "$variant" == embedded ]]; then build_args+=(--disable-default-traits); fi
# Check the compiler export feature with this exact compiler/SDK before the build.
if [[ "$mode" == browser ]]; then
    cat > "$scratch/ExportProbe.swift" <<'PROBE'
@_expose(wasm, "swiftterm_probe")
public func probe() -> UInt32 { 1 }
PROBE
    "${swift_bin%/swift}/swiftc" -target wasm32-unknown-wasip1 -sdk "$sdk_base/WASI.sdk" \
        -resource-dir "$sdk_base/swift.xctoolchain/usr/lib/swift_static" \
        -module-cache-path "$CLANG_MODULE_CACHE_PATH" -static-stdlib -parse-as-library \
        -Xclang-linker -resource-dir -Xclang-linker "$clang_resources" \
        -Xclang-linker -mexec-model=reactor "$scratch/ExportProbe.swift" -o "$scratch/export-probe.wasm"
    node scripts/wasm-artifact.mjs probe "$scratch/export-probe.wasm"
fi
"$swift_bin" build "${build_args[@]}" --product "$product"
bin_dir=$("$swift_bin" build "${build_args[@]}" --show-bin-path)
artifact="$bin_dir/$product.wasm"
if [[ ! -f "$artifact" ]]; then artifact="$bin_dir/$product"; fi
if [[ "$mode" == browser ]]; then
    mkdir -p Web/dist
    output="Web/dist/swiftterm-$variant.wasm"
else
    mkdir -p "$scratch/out"
    output="$scratch/out/swiftterm-$variant-smoke.wasm"
fi
if [[ $strip == 1 ]]; then
    node scripts/wasm-artifact.mjs strip "$artifact" "$output"
else
    cp "$artifact" "$output"
fi
if [[ "$mode" == browser ]]; then
    scripts/check-wasm-exports.sh "$output" "$variant"
    npm --prefix Web run build
    node scripts/wasm-artifact.mjs smoke "$output"
    node scripts/wasm-artifact.mjs sizes "$output"
elif [[ $run == 1 ]]; then
    node scripts/wasm-artifact.mjs command "$output"
fi
echo "Built $output"
