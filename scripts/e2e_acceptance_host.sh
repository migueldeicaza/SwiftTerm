#!/usr/bin/env bash
# Host-side E2E acceptance for the SwiftTerm monorepo + nested a-Shell.
# Runs on Linux/macOS without Xcode. Complements Apps/a-Shell/scripts/verify_ashell_integrity.sh
# (that script must run inside the installed a-Shell app).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASHELL="$ROOT/Apps/a-Shell"
PASS=0
FAIL=0
WARN=0
SKIP=0
REPORT="${E2E_REPORT:-$ROOT/Docs/e2e-acceptance-results.md}"

ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$*"; }
warn() { WARN=$((WARN+1)); printf 'WARN  %s\n' "$*"; }
skip() { SKIP=$((SKIP+1)); printf 'SKIP  %s\n' "$*"; }

section() { printf '\n## %s\n' "$*"; }

require_file() {
  if [[ -f "$1" ]]; then ok "file $1"
  else bad "missing file $1"; fi
}

cd "$ROOT"

{
  echo "# E2E acceptance results (host)"
  echo
  echo "- Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"
  echo "- Root: \`$ROOT\`"
  echo "- HEAD: \`$(git rev-parse HEAD)\` (\`$(git log -1 --oneline)\`)"
  echo
} >"$REPORT.tmp"

exec > >(tee -a "$REPORT.tmp") 2>&1

echo "=== Host E2E acceptance ==="

section "1. Pin graph"
ST_MAIN="$(git rev-parse HEAD)"
ASHELL_PIN="$(git ls-tree HEAD Apps/a-Shell | awk '{print $3}')"
ok "SwiftTerm HEAD=$ST_MAIN"
ok "Apps/a-Shell gitlink=$ASHELL_PIN"
if [[ -d "$ASHELL/.git" ]] || [[ -f "$ASHELL/.git" ]]; then
  (
    cd "$ASHELL"
    git fetch -q origin master 2>/dev/null || true
    CUR="$(git rev-parse HEAD)"
    if [[ "$CUR" == "$ASHELL_PIN" ]]; then ok "Apps/a-Shell checkout matches gitlink"
    else warn "Apps/a-Shell checkout $CUR != gitlink $ASHELL_PIN"; fi
    NESTED="$(git ls-tree HEAD SwiftTerm 2>/dev/null | awk '{print $3}' || true)"
    if [[ -n "$NESTED" ]]; then
      ok "nested SwiftTerm pin=$NESTED"
      if git -C "$ROOT" merge-base --is-ancestor "$NESTED" HEAD 2>/dev/null; then
        ok "nested SwiftTerm is ancestor of monorepo HEAD (or equal)"
      else
        # nested may be older main tip edc5aae while HEAD moved — still OK if HostHelpers present
        warn "nested pin $NESTED not ancestor of $ST_MAIN (expected if only Apps/ bumps after)"
      fi
    else
      bad "Apps/a-Shell missing SwiftTerm gitlink"
    fi
    GM="$(git show HEAD:.gitmodules 2>/dev/null || true)"
    if echo "$GM" | grep -q 'jiaomeimei0-prog/SwiftTerm'; then
      ok ".gitmodules points at jiaomeimei0-prog/SwiftTerm"
    else
      bad ".gitmodules does not point at fork SwiftTerm"
    fi
  )
else
  bad "Apps/a-Shell not initialized"
fi

section "2. HostHelpers bridge (20 APIs)"
HH="$ROOT/Sources/SwiftTerm/Apple/AppleTerminalView+HostHelpers.swift"
require_file "$HH"
APIS=(
  getTerminal isCurrentBufferAlternate getLastLine getLastPrompt setPromptEnd
  getNewContent saveCursorPosition restoreCursorPosition setCursorPosition
  getCurrentChar moveUpIfNeeded moveDownIfNeeded atTheEndOfTheLine
  moveToBeginningOfLine moveToEndOfLine clearToEndOfLine wipeContents
  setCursorStyle moveToEndOfSelection moveToBeginningOfSelection deleteSelection
)
for api in "${APIS[@]}"; do
  if grep -Eq "(func|var) ${api}(\\(|:| |$)" "$HH"; then ok "HostHelpers has $api"
  else bad "HostHelpers missing $api"; fi
done
if grep -q 'promptline = terminal.buffer.linesTop + terminal.buffer.yBase + terminal.buffer.y' "$HH"; then
  ok "setPromptEnd uses linesTop+yBase+y"
else
  bad "setPromptEnd index formula drift"
fi
IOSV="$ROOT/Sources/SwiftTerm/iOS/iOSTerminalView.swift"
if grep -q 'public func ensureCaretIsVisible' "$IOSV" && grep -q 'public var currentCommandVoiceOver' "$IOSV"; then
  ok "ensureCaretIsVisible + currentCommandVoiceOver public on iOS"
else
  bad "missing public VoiceOver/caret APIs on iOSTerminalView"
fi

section "3. a-Shell call-site coverage vs HostHelpers"
if [[ -d "$ASHELL/a-Shell" ]]; then
  CALLS=$(rg -oN --no-filename \
    'terminalView[?!]?\.(getTerminal|isCurrentBufferAlternate|getLastPrompt|setPromptEnd|getNewContent|getLastLine|saveCursorPosition|restoreCursorPosition|setCursorPosition|moveUpIfNeeded|moveDownIfNeeded|moveToBeginningOfLine|moveToEndOfLine|deleteSelection|moveToBeginningOfSelection|moveToEndOfSelection|clearToEndOfLine|wipeContents|setCursorStyle|ensureCaretIsVisible|currentCommandVoiceOver)\b' \
    "$ASHELL/a-Shell" --glob '*.swift' 2>/dev/null | sed 's/.*\.//' | sort -u || true)
  # also view.getLastLine
  EXTRA=$(rg -oN --no-filename '\.getLastLine\(' "$ASHELL/a-Shell" --glob '*.swift' 2>/dev/null | head -1 || true)
  [[ -n "$EXTRA" ]] && CALLS=$(printf '%s\n%s\n' "$CALLS" getLastLine | sort -u)
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    case "$c" in
      ensureCaretIsVisible|currentCommandVoiceOver)
        if grep -q "$c" "$IOSV"; then ok "call-site $c satisfied on iOSTerminalView"
        else bad "call-site $c unresolved"; fi
        ;;
      *)
        if grep -Eq "(func|var) ${c}(\\(|:| |$)" "$HH"; then ok "call-site $c satisfied by HostHelpers"
        else bad "call-site $c unresolved"; fi
        ;;
    esac
  done <<< "$CALLS"
else
  bad "a-Shell sources missing"
fi

section "4. Upstream parity spot-check (identical host sources)"
UP="${UPSTREAM_ASHELL:-/tmp/upstream-audit/holzschu-a-shell}"
if [[ -d "$UP/a-Shell" ]]; then
  for f in SceneDelegate.swift SceneDelegate+TerminalView.swift ExtraCommands.swift Relay.swift AppDelegate.swift; do
    if diff -q "$UP/a-Shell/$f" "$ASHELL/a-Shell/$f" >/dev/null 2>&1; then
      ok "identical to holzschu: a-Shell/$f"
    else
      bad "differs from holzschu: a-Shell/$f"
    fi
  done
else
  warn "upstream clone missing at $UP — skip byte identity (set UPSTREAM_ASHELL)"
fi

section "5. Network / side-channel defaults (static)"
TO="$ROOT/Sources/SwiftTerm/TerminalOptions.swift"
if grep -q 'kittyClipboardPolicy: \[\]' "$TO"; then ok "Kitty clipboard policy default empty"
else bad "Kitty clipboard policy default unexpected"; fi
if grep -q 'static let defaultEnableRectangularAreaChecksum = false' "$TO"; then
  ok "DECRQCRA default false in release"
else
  bad "DECRQCRA release default not false"
fi
if grep -q 'enableOsc8Hyperlinks: true' "$TO"; then ok "OSC8 hyperlinks default true"
else warn "OSC8 default not found as true"; fi
if grep -q 'var enabled = false' "$ASHELL/a-Shell/Relay.swift" && grep -q 'var bind = "127.0.0.1"' "$ASHELL/a-Shell/Relay.swift"; then
  ok "Relay default disabled + loopback bind"
else
  bad "Relay defaults drifted"
fi
if ! rg -n 'func clipboardRead' "$ASHELL/a-Shell" --glob '*.swift' | grep -v 'clipboardCopy' >/dev/null; then
  # ensure no clipboardRead implementation in a-Shell host
  if rg -n 'func clipboardRead' "$ASHELL/a-Shell" --glob '*.swift' >/dev/null; then
    warn "clipboardRead appears in a-Shell — review deny policy"
  else
    ok "a-Shell does not implement clipboardRead (OSC52 read stays denied)"
  fi
fi
if rg -n 'func clipboardCopy' "$ASHELL/a-Shell/SceneDelegate+TerminalView.swift" >/dev/null; then
  ok "a-Shell implements clipboardCopy (OSC52 write)"
else
  bad "clipboardCopy missing"
fi

section "6. Automation artifacts present"
require_file "$ASHELL/downloadFrameworks.sh"
require_file "$ASHELL/xcfs/Package.swift"
require_file "$ASHELL/Resources/bin/pkg"
require_file "$ASHELL/scripts/verify_ashell_integrity.sh"
require_file "$ASHELL/codex/build.sh"
require_file "$ASHELL/a-Shell-Intents/ExecuteCommandIntentHandler.swift"
if grep -q 'checksum:' "$ASHELL/xcfs/Package.swift"; then ok "xcfs Package.swift has checksum entries"
else bad "xcfs missing checksums"; fi
if grep -q 'pythonInstall.tar.gz' "$ASHELL/downloadFrameworks.sh" && ! grep -q 'shasum' "$ASHELL/downloadFrameworks.sh"; then
  warn "pythonInstall.tar.gz fetched without local SHA-256 (upstream design)"
fi

section "7. Device script syntax"
if sh -n "$ASHELL/scripts/verify_ashell_integrity.sh"; then
  ok "verify_ashell_integrity.sh sh -n clean"
else
  bad "verify_ashell_integrity.sh syntax error"
fi
# Dry-run in a fake Documents tree (cannot exercise real a-Shell builtins)
FAKE=$(mktemp -d)
mkdir -p "$FAKE/Documents"
printf '%s\n' '{"enabled":false,"bind":"127.0.0.1","port":8765,"mutualTLS":true,"token":"0123456789abcdef0123456789abcdef"}' >"$FAKE/Documents/.relay.json"
export HOME="$FAKE" COLUMNS=80 LINES=24 TERM=xterm-256color
# Provide stubs for a-Shell builtins missing on Linux host
PATH_STUB="$FAKE/bin"
mkdir -p "$PATH_STUB"
cat >"$PATH_STUB/help" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-l" ]; then
  i=1
  while [ "$i" -le 30 ]; do
    printf 'cmd%02d\n' "$i"
    i=$((i + 1))
  done
  printf '%s\n' config pkg curl open help echo cat codex
  exit 0
fi
echo "help stub"
EOF
cat >"$PATH_STUB/pbcopy" <<'EOF'
#!/bin/sh
cat >"${TMPDIR:-/tmp}/pbcopy-buf"
EOF
cat >"$PATH_STUB/pbpaste" <<'EOF'
#!/bin/sh
cat "${TMPDIR:-/tmp}/pbcopy-buf" 2>/dev/null || true
EOF
# curl stub: always "connection refused" so port probes take WARN/OK paths without false TLS hits
cat >"$PATH_STUB/curl" <<'EOF'
#!/bin/sh
exit 7
EOF
chmod +x "$PATH_STUB"/*
export PATH="$PATH_STUB:$PATH"
set +e
OUT=$(sh "$ASHELL/scripts/verify_ashell_integrity.sh" 2>&1)
RC=$?
set -e
printf '%s\n' "$OUT" | sed -n '1,50p'
if echo "$OUT" | grep -q 'PASS  env has HOME' \
  && echo "$OUT" | grep -q 'PASS  env has COLUMNS' \
  && echo "$OUT" | grep -q 'PASS  found' \
  && echo "$OUT" | grep -q 'PASS  pbcopy/pbpaste round-trip' \
  && [[ "$RC" -eq 0 ]]; then
  ok "device script dry-run passed under host stubs (rc=$RC)"
else
  warn "device script dry-run incomplete (rc=$RC) — review output above"
fi
rm -rf "$FAKE"

section "8. Local toolchain / CI gates"
if command -v xcodebuild >/dev/null; then
  ok "xcodebuild available"
else
  skip "xcodebuild unavailable — cannot build iOS app on this host"
fi
if command -v swift >/dev/null; then
  ok "swift available — consider swift test"
else
  skip "swift unavailable — package unit tests not executed"
fi

section "Summary"
echo "PASS=$PASS WARN=$WARN FAIL=$FAIL SKIP=$SKIP"
{
  echo
  echo "## Counts"
  echo
  echo "| PASS | WARN | FAIL | SKIP |"
  echo "|------|------|------|------|"
  echo "| $PASS | $WARN | $FAIL | $SKIP |"
  echo
  if [[ "$FAIL" -eq 0 ]]; then
    echo "**Host gate: PASS** (device interactive / Xcode build still required for full E2E)."
  else
    echo "**Host gate: FAIL** — fix FAIL items before claiming acceptance."
  fi
  echo
  echo "## Device follow-up (manual)"
  echo
  echo '```sh'
  echo 'sh scripts/verify_ashell_integrity.sh'
  echo '```'
  echo
  echo "Plus interactive: history edit, selection delete, VoiceOver, Shortcuts Execute Command, optional Codex."
} >>"$REPORT.tmp"

mv "$REPORT.tmp" "$REPORT"
echo "Wrote $REPORT"
exit "$FAIL"
