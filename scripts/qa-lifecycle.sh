#!/bin/bash
# Shared by the two acceptance batches. Never select processes by name alone.
qa_processes() {
  local uid
  uid="$(/usr/bin/id -u)" || return 1
  /bin/ps -ww -axo pid=,uid=,stat=,comm= | LC_ALL=C QA_SCAN_STAGE="${2:-}" /usr/bin/awk -v uid="$uid" -v scope="${1:-all}" '
    function normalize(path) { if (path ~ /^\/private\/(var|tmp)\//) sub(/^\/private/, "", path); return path }
    BEGIN { stage = normalize(ENVIRON["QA_SCAN_STAGE"]) }
    $2 == uid && $3 !~ /^Z/ {
      path = $0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", path)
      path = normalize(path)
      if (stage != "" && index(path, stage "/") != 1) next
      app = path ~ /\/(\.uitest\.[[:alnum:]]+\/|\.selftest\.[[:alnum:]]+\/unpacked\/)WeChatMenuBridge\.app\/Contents\/MacOS\/(WeChatMenuBridge|bridge-engine)$/
      runner = path ~ /\/\.uitest\.[[:alnum:]]+\/.*BridgeUI-Runner\.app\/Contents\/MacOS\/BridgeUI-Runner$/
      fixture = path ~ /\/\.uitest\.[[:alnum:]]+\/MenuBarFixture\.app\/Contents\/MacOS\/MenuBarFixture$/
      if ((app && (scope == "all" || scope == "apps")) || (runner && (scope == "all" || scope == "runner")) ||
          (fixture && (scope == "all" || scope == "fixture"))) print $1 " " path
    }'
}

# Native synthetic network fixtures carry their owning stage in argv. This
# separate scan also detects an orphan rather than assuming loss of parentage
# means it exited. Never use it to signal an unrelated process.
qa_fixture_processes() {
  local uid
  uid="$(/usr/bin/id -u)" || return 1
  /bin/ps -ww -axo pid=,uid=,stat=,comm=,args= | LC_ALL=C QA_FIXTURE_STAGE="${1:-}" /usr/bin/awk -v uid="$uid" '
    BEGIN { stage = ENVIRON["QA_FIXTURE_STAGE"] }
    $2 == uid && $3 !~ /^Z/ && $5 ~ /(^|\/)bun$/ && index($0, "/Engine/test/fixture-cli.ts") &&
      index($0, " --until-terminated ") && $0 ~ /--qa-stage=.*\/\.uitest\.[[:alnum:]]+/ {
      if (stage != "" && index($0, "--qa-stage=" stage) == 0) next
      print $1 " " $0
    }'
}

qa_acquire() {
  local dir lock
  dir="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)" || return 1
  lock="${dir%/}/wechat-menu-bridge.qa.lock"
  if ! /bin/mkdir -m 700 "$lock" 2>/dev/null; then
    printf 'Another bridge QA batch is active, or a prior exit was not confirmed. Not launching. Lock: %s\n' "$lock" >&2
    return 1
  fi
  QA_LOCK="$lock"
  printf '%s\n' "$$" > "$QA_LOCK/owner"
}

qa_release() {
  if [ -n "$QA_LOCK" ]; then
    /bin/rm -f -- "$QA_LOCK/owner" && /bin/rmdir -- "$QA_LOCK"
  fi
}

qa_assert_idle() {
  local rows fixtures
  rows="$(qa_processes)" || return 1
  fixtures="$(qa_fixture_processes)" || return 1
  if [ -n "$rows" ] || [ -n "$fixtures" ]; then
    printf 'A previous isolated QA instance or synthetic fixture has not exited. Not launching:\n%s\n%s\n' "$rows" "$fixtures" >&2
    return 1
  fi
}

qa_desktop_ready() {
  local uid console state
  uid="$(/usr/bin/id -u)" || return 1
  console="$(/usr/bin/stat -f %u /dev/console)" || return 1
  [ "$uid" = "$console" ] || return 1
  state="$(/usr/sbin/ioreg -n Root -d 1 -w 0)" || return 1
  /usr/bin/awk '
    /"kCGSSessionOnConsoleKey"[[:space:]]*=[[:space:]]*(Yes|1)/ { on_console = 1 }
    /"kCGSessionLoginDoneKey"[[:space:]]*=[[:space:]]*(Yes|1)/ { logged_in = 1 }
    /"CGSSessionScreenIsLocked"[[:space:]]*=[[:space:]]*(Yes|1)/ { locked = 1 }
    END { exit !(on_console && logged_in && !locked) }
  ' <<< "$state"
}

qa_assert_desktop() {
  if ! qa_desktop_ready; then
    echo 'Native UI tests need the unlocked macOS desktop for this user. Not launching.' >&2
    return 1
  fi
}

# XCTest runners may not execute the system ps binary or write to the stage.
# Publish read-only snapshots. Each native invocation owns exactly one case;
# an unexpected replacement within that case must not authorize a launch.
qa_watch_process_checks() {
  local stage="$1" desktop="${2:-}" snapshot="$1/process-snapshot" rows apps runner first_runner= serial=0 state=ok
  while [ -d "$stage" ] && [ ! -f "$stage/no-more-launches" ] && /bin/kill -0 "$$" 2>/dev/null; do
    apps=
    if rows="$(qa_processes)"; then
      runner="$(/usr/bin/awk '/\/BridgeUI-Runner$/ { print }' <<< "$rows")"
      apps="$(/usr/bin/awk '/\/(WeChatMenuBridge|bridge-engine)$/ && NF { print }' <<< "$rows")"
      if [ -n "$runner" ]; then
        if [ "$state" = ok ]; then
          if [[ "$runner" == *$'\n'* || "${runner#* }" != "${stage#/private}"/* ]]; then state=unexpected-runner
          elif [ -z "$first_runner" ]; then first_runner="$runner"
          elif [ "$runner" != "$first_runner" ]; then state=runner-replaced; fi
        fi
      fi
    elif [ "$state" = ok ]; then
      state=process-scan-failed
    fi
    if [ "$desktop" = desktop ] && [ "$state" = ok ] && (( serial % 5 == 0 )) && ! qa_assert_desktop; then state=desktop-unavailable; fi
    serial=$((serial + 1))
    printf '%s\n%s\n%s' "$serial" "$state" "$apps" > "$snapshot.next"
    /bin/mv -- "$snapshot.next" "$snapshot"
    /bin/sleep 0.16
  done
}

# Stop just the exact runner/App/helper inside the batch the caller owns.
# Snapshot again before signaling, to avoid signaling a reused PID.
qa_reap_stage() {
  local scope="$1" stage="$2" rows current row signal
  [ -n "$stage" ] || return 0
  for signal in TERM KILL; do
    rows="$(qa_processes "$scope" "$stage")" || return 1
    [ -n "$rows" ] || return 0
    while IFS= read -r row; do
      current="$(qa_processes "$scope" "$stage")" || return 1
      if /usr/bin/grep -Fxq -- "$row" <<< "$current"; then
        printf 'Reaping isolated QA process (%s): %s\n' "$signal" "$row" >&2
        /bin/kill -s "$signal" "${row%% *}" 2>/dev/null || true
      fi
    done <<< "$rows"
    for _ in {1..20}; do
      rows="$(qa_processes "$scope" "$stage")" || return 1
      [ -n "$rows" ] || return 0
      /bin/sleep 0.1
    done
  done
  printf 'Could not confirm isolated QA exit:\n%s\n' "$rows" >&2
  return 1
}

# Unlike a LaunchServices app, the build/test command and fixtures are direct
# shell children. Verify parentage on every signal, and bound the wait.
qa_stop_child() {
  local pid="$1" rows signal attempt
  for signal in TERM KILL; do
    for attempt in {1..20}; do
      rows="$(/bin/ps -axo pid=,ppid=,stat= | /usr/bin/awk -v pid="$pid" -v parent="$$" '$1 == pid && $2 == parent && $3 !~ /^Z/ { print $1 }')" || return 1
      if [ -z "$rows" ]; then wait "$pid" 2>/dev/null || true; return 0; fi
      if [ "$attempt" = 1 ]; then /bin/kill -s "$signal" "$pid" 2>/dev/null || true; fi
      /bin/sleep 0.1
    done
  done
  printf 'Could not confirm QA subprocess %s exited\n' "$pid" >&2
  return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  qa_processes "${1:-all}" "${2:-}"
fi
