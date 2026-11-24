#!/bin/bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=qa-lifecycle.sh
source "$ROOT/scripts/qa-lifecycle.sh"
DIST="$ROOT/dist"
OUT="${1:-}"
if [ "$#" -gt 1 ] || { [ -n "$OUT" ] && [ -e "$OUT" ]; }; then
  echo "Usage: bash scripts/selftest.sh [new-candidate-directory]" >&2
  exit 2
fi
QA_LOCK=
STAGE=
SWIFT_PID=
BUN_PID=
SCAN_PID=
cleanup() {
  local result=$? clean=1
  trap '' HUP INT TERM
  if [ -n "$STAGE" ]; then : > "$STAGE/no-more-launches"; fi
  if [ -n "$SWIFT_PID" ]; then qa_stop_child "$SWIFT_PID" || clean=0; fi
  if [ -n "$BUN_PID" ]; then qa_stop_child "$BUN_PID" || clean=0; fi
  if [ -n "$SCAN_PID" ]; then qa_stop_child "$SCAN_PID" || clean=0; fi
  qa_reap_stage apps "$STAGE" || clean=0
  if [ "$clean" -ne 1 ]; then
    printf 'QA exit could not be verified. Preserving lock %s and stage %s.\n' "$QA_LOCK" "$STAGE" >&2
    exit 1
  fi
  if [ -n "$STAGE" ]; then rm -rf -- "$STAGE"; fi
  qa_release
  exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
qa_acquire
qa_assert_idle
mkdir -p "$DIST"
STAGE="$(mktemp -d "$DIST/.selftest.XXXXXX")"
export TMPDIR="$STAGE"

WMB_BUILD_OFFLINE=1 bash "$ROOT/scripts/package.sh" "$STAGE/candidate"
ditto -x -k "$STAGE/candidate/WeChatMenuBridge-arm64.zip" "$STAGE/unpacked"
APP="$STAGE/unpacked/WeChatMenuBridge.app"
codesign --verify --deep --strict "$APP"
diff -qr "$STAGE/candidate/WeChatMenuBridge.app" "$APP"
test "$(lipo -archs "$APP/Contents/MacOS/WeChatMenuBridge")" = arm64
test "$(lipo -archs "$APP/Contents/MacOS/bridge-engine")" = arm64
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist")" = true

export WMB_TEST_APP="$APP/Contents/MacOS/WeChatMenuBridge"
export WMB_TEST_ENGINE="$APP/Contents/MacOS/bridge-engine"
export WMB_TEST_BUN="$(command -v bun)"
export WMB_TEST_FIXTURE="$ROOT/Engine/test/fixture-cli.ts"
export WMB_TEST_TEMP="$STAGE"
qa_watch_process_checks "$STAGE" &
SCAN_PID=$!
status=0
swift test --package-path "$ROOT/App" -c release &
SWIFT_PID=$!
wait "$SWIFT_PID" || status=$?
SWIFT_PID=
test "$status" -eq 0
qa_assert_idle
status=0
(cd "$ROOT/Engine" && exec bun test) &
BUN_PID=$!
wait "$BUN_PID" || status=$?
BUN_PID=
test "$status" -eq 0

# Validation never replaces a previous handoff. An optional, explicitly new
# path keeps the tested candidate for further GUI or live acceptance.
if [ -n "$OUT" ]; then mv "$STAGE/candidate" "$OUT"; fi
