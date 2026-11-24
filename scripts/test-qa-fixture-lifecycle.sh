#!/bin/bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
source "$ROOT/scripts/qa-lifecycle.sh"

QA_LOCK=
STAGE=
PID=
cleanup() {
  local result=$? rows fixtures
  trap '' HUP INT TERM
  if [ -n "$PID" ]; then qa_stop_child "$PID" || result=1; fi
  if [ -n "$STAGE" ]; then
    if ! rows="$(qa_processes all "$STAGE")" || ! fixtures="$(qa_fixture_processes "$STAGE")" || [ -n "$rows" ] || [ -n "$fixtures" ]; then
      printf 'Isolated exit unconfirmed; keeping lock %s and stage %s\n' "$QA_LOCK" "$STAGE" >&2
      exit 1
    fi
    case "$STAGE" in
      */.uitest.*) /bin/rm -rf -- "$STAGE" || result=1 ;;
      *) echo 'Unexpected fixture test stage; not removing it.' >&2; result=1 ;;
    esac
  fi
  qa_release
  exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

qa_acquire
qa_assert_idle
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/.uitest.XXXXXX")"

for case_id in one two; do
  qa_assert_idle
  env -i HOME="$STAGE" PATH="/usr/bin:/bin" TMPDIR="$STAGE" "$(command -v bun)" --no-env-file \
    "$ROOT/Engine/test/fixture-cli.ts" --until-terminated "--qa-stage=$STAGE" </dev/null >/dev/null 2>&1 &
  PID=$!
  rows=
  for _ in {1..50}; do
    rows="$(qa_fixture_processes "$STAGE")"
    [ -n "$rows" ] && break
    /bin/sleep 0.1
  done
  [ -n "$rows" ] || { echo "Fixture $case_id was not detected" >&2; exit 1; }
  if qa_assert_idle >/dev/null 2>&1; then echo 'A live fixture must block the next case' >&2; exit 1; fi
  qa_stop_child "$PID"
  PID=
  [ -z "$(qa_fixture_processes "$STAGE")" ] || { echo 'Fixture survived shutdown' >&2; exit 1; }
  qa_assert_idle
done
# Copying a system-signed executable out of /bin can fail macOS signature
# validation. Build a minimal local process to exercise the exact staged paths.
/usr/bin/clang -x c -o "$STAGE/qa-sleeper" - <<'EOF'
#include <unistd.h>
int main(void) { for (;;) pause(); }
EOF
for name in \
  'WeChatMenuBridge.app/Contents/MacOS/WeChatMenuBridge' \
  'WeChatMenuBridge.app/Contents/MacOS/bridge-engine' \
  'derived/BridgeUI-Runner.app/Contents/MacOS/BridgeUI-Runner' \
  'MenuBarFixture.app/Contents/MacOS/MenuBarFixture'; do
  qa_assert_idle
  binary="$STAGE/$name"
  /bin/mkdir -p "$(dirname "$binary")"
  /bin/cp "$STAGE/qa-sleeper" "$binary"
  "$binary" </dev/null >/dev/null 2>&1 &
  PID=$!
  rows=
  for _ in {1..50}; do
    rows="$(qa_processes all "$STAGE")"
    [ -n "$rows" ] && break
    /bin/sleep 0.1
  done
  [ -n "$rows" ] || { printf 'Staged process not detected: %s\n' "$name" >&2; exit 1; }
  if qa_assert_idle >/dev/null 2>&1; then printf 'A live staged process must block the next case: %s\n' "$name" >&2; exit 1; fi
  qa_stop_child "$PID"
  PID=
  qa_assert_idle
done
echo 'Synthetic fixtures and staged App, helper, runner and menu fixture all block the next case and exited.'
