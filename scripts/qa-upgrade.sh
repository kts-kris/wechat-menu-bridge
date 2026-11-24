#!/bin/bash
# Real-bundle acceptance for the in-app updater: upgrade and crash rollback.
#
# Runs the production UpdateInstallScript (rendered from AppUpdater.swift, with
# the real /usr/bin/open) against disposable copies of a packaged bundle. Every
# copy carries a fresh local.wechatmenubridge.nativeqa.<uuid> identity and lives
# directly in a private .uitest.* stage, so NativeQA pins its settings, engine
# state and keychain to that stage even though LaunchServices starts it with the
# login environment. The installed or running bridge is never launched, signaled
# or modified; only processes whose executable lies inside the stage are reaped.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=qa-lifecycle.sh
source "$ROOT/scripts/qa-lifecycle.sh"

INPUT="${1:-}"
if [ "$#" -gt 1 ]; then
  echo 'Usage: bash scripts/qa-upgrade.sh [WeChatMenuBridge.app | WeChatMenuBridge-arm64.zip]' >&2
  exit 2
fi
if [ -z "$INPUT" ]; then
  for candidate in "$ROOT/dist/uat-v2.1.x/WeChatMenuBridge-arm64.zip" "$ROOT/dist/WeChatMenuBridge-arm64.zip" "$ROOT/dist/WeChatMenuBridge.app"; do
    if [ -e "$candidate" ]; then INPUT="$candidate"; break; fi
  done
fi
if [ -z "$INPUT" ] || [ ! -e "$INPUT" ]; then
  echo 'No packaged WeChatMenuBridge.app or WeChatMenuBridge-arm64.zip found.' >&2
  exit 2
fi
INPUT="$(cd "$(dirname "$INPUT")" && pwd -P)/$(basename "$INPUT")"

QA_LOCK=
STAGE=
ID=
HELPER_PID=
EXE=WeChatMenuBridge
FOREIGN_BEFORE=

say() { printf '[qa-upgrade] %s\n' "$*"; }
fail() { printf '[qa-upgrade] FAIL: %s\n' "$*" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }
set_version() {
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $2" -c "Set :CFBundleVersion $3" "$1/Contents/Info.plist"
}

# The production probe: a process mapping this exact executable image.
image_pids() { /usr/sbin/lsof -a -d txt -t -- "$1" 2>/dev/null || true; }

# Processes of this stage that are not LaunchServices apps (the installer
# script and its helper). Matched by the unique stage path in argv only.
stage_args_processes() {
  [ -n "$STAGE" ] || return 0
  /bin/ps -ww -axo pid=,uid=,stat=,args= | LC_ALL=C QA_UPGRADE_STAGE="$STAGE" /usr/bin/awk -v uid="$(/usr/bin/id -u)" -v self="$$" '
    function normalize(path) { if (path ~ /^\/private\/(var|tmp)\//) sub(/^\/private/, "", path); return path }
    BEGIN { stage = normalize(ENVIRON["QA_UPGRADE_STAGE"]) }
    $2 == uid && $3 !~ /^Z/ && $1 != self {
      line = $0; sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", line)
      if (index(normalize(line), stage "/") || index(line, ENVIRON["QA_UPGRADE_STAGE"] "/")) print $1 " " line
    }'
}

# Bridge processes outside every QA stage, e.g. the user's installed copy.
foreign_bridges() {
  /bin/ps -ww -axo pid=,uid=,stat=,comm= | LC_ALL=C /usr/bin/awk -v uid="$(/usr/bin/id -u)" '
    $2 == uid && $3 !~ /^Z/ && $0 ~ /\/WeChatMenuBridge\.app\/Contents\/MacOS\/(WeChatMenuBridge|bridge-engine)$/ &&
      $0 !~ /\/\.uitest\.[[:alnum:]]+\// && $0 !~ /\/\.selftest\.[[:alnum:]]+\// { print $1 }' | /usr/bin/sort -n | /usr/bin/tr '\n' ' '
}

reap_args_processes() {
  local rows signal
  for signal in TERM KILL; do
    rows="$(stage_args_processes)"
    [ -n "$rows" ] || return 0
    while IFS= read -r row; do
      printf 'Reaping stage process (%s): %s\n' "$signal" "$row" >&2
      /bin/kill -s "$signal" "${row%% *}" 2>/dev/null || true
    done <<< "$rows"
    for _ in {1..30}; do
      [ -n "$(stage_args_processes)" ] || return 0
      /bin/sleep 0.1
    done
  done
  [ -z "$(stage_args_processes)" ]
}

# Per-identity state macOS creates for a launched app. Only the exact unique
# nativeqa identity of this run is removed; nothing else is touched.
forget_identity() {
  local path lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  [ -n "$ID" ] || return 0
  [[ "$ID" =~ ^local\.wechatmenubridge\.nativeqa\.[0-9a-f-]{36}$ ]] || return 0
  if [ -n "$STAGE" ] && [ -x "$lsregister" ]; then
    for path in "$STAGE"/*.app "$STAGE"/.*.app "$STAGE"/work-*/unpacked/*.app; do
      [ -e "$path" ] && "$lsregister" -u "$path" >/dev/null 2>&1 || true
    done
  fi
  /usr/bin/defaults delete "$ID" >/dev/null 2>&1 || true
  for path in "$HOME/Library/Preferences/$ID.plist" "$HOME/Library/Saved Application State/$ID.savedState" \
              "$HOME/Library/Caches/$ID" "$HOME/Library/HTTPStorages/$ID" "$HOME/Library/HTTPStorages/$ID.binarycookies" \
              "$HOME/Library/WebKit/$ID"; do
    [ -e "$path" ] && /bin/rm -rf -- "$path"
  done
  return 0
}

cleanup() {
  local result=$? clean=1 rows
  trap '' HUP INT TERM
  if [ -n "$HELPER_PID" ]; then qa_stop_child "$HELPER_PID" || clean=0; fi
  if [ -n "$STAGE" ]; then
    reap_args_processes || clean=0
    qa_reap_stage apps "$STAGE" || clean=0
    rows="$(qa_processes all "$STAGE")$(stage_args_processes)"
    if [ -n "$rows" ]; then printf 'Stage processes still running:\n%s\n' "$rows" >&2; clean=0; fi
  fi
  if [ "$clean" -ne 1 ]; then
    printf 'Exit of isolated copies could not be verified. Preserving lock %s and stage %s.\n' "$QA_LOCK" "$STAGE" >&2
    exit 1
  fi
  if [ -n "$STAGE" ]; then
    if [ "$result" -ne 0 ]; then
      for log in "$STAGE"/work-*/install.log; do
        [ -f "$log" ] && { printf -- '--- %s ---\n' "${log#"$STAGE"/}"; /usr/bin/tail -n 20 "$log"; }
      done
    fi
    forget_identity
    /bin/rm -rf -- "$STAGE"
    [ ! -e "$STAGE" ] || result=1
    say "stage removed; isolated App, engine, installer and helper confirmed exited (zero residual processes)"
  fi
  if [ -n "$FOREIGN_BEFORE" ] && [ "$(foreign_bridges)" != "$FOREIGN_BEFORE" ]; then
    printf 'Bridge processes outside the stage changed: before [%s] after [%s]\n' "$FOREIGN_BEFORE" "$(foreign_bridges)" >&2
    result=1
  fi
  qa_release
  if [ "$result" -eq 0 ]; then say 'RESULT: PASS (upgrade + crash rollback)'; else say "RESULT: FAIL ($result)"; fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

qa_acquire
qa_assert_idle
FOREIGN_BEFORE="$(foreign_bridges)"
say "bridge processes outside any QA stage (must stay untouched): [${FOREIGN_BEFORE:-none}]"

TEMP_ROOT="${WMB_UPGRADE_TEMP_ROOT:-${TMPDIR:-/tmp}}"
mkdir -p "$TEMP_ROOT"
TEMP_ROOT="$(cd "$TEMP_ROOT" && pwd -P)"
# NativeQA only accepts a bundle whose parent directory is named .uitest.*.
STAGE="$(mktemp -d "$TEMP_ROOT/.uitest.XXXXXX")"
STAGE="$(cd "$STAGE" && pwd -P)"
mkdir -m 700 "$STAGE/home" "$STAGE/tools" "$STAGE/source"
say "input: $INPUT"
say "stage: $STAGE"

# ---------------------------------------------------------------- tools
# Export the production installer text from AppUpdater.swift itself.
SRC="$ROOT/App/Sources/WeChatMenu/Updates/AppUpdater.swift"
/usr/bin/awk '/^enum UpdateInstallScript \{/ { on = 1 } on { print } on && /^\}$/ { exit }' "$SRC" > "$STAGE/tools/UpdateInstallScript.swift"
/usr/bin/grep -q 'static func render(openCommand: String = "/usr/bin/open"' "$STAGE/tools/UpdateInstallScript.swift" ||
  fail 'could not extract UpdateInstallScript from AppUpdater.swift'
cat > "$STAGE/tools/main.swift" <<'SWIFT'
import Darwin
import Foundation

// render <probeSeconds> <out>: production script with the default (real) opener.
// spawn-wait <home> <script> <args...>: start it as UpdateRelauncher does (new
// session, inherited descriptors closed, minimal environment) and report its
// exit status, which the detached app never observes.
func die(_ text: String) -> Never { FileHandle.standardError.write(Data("\(text)\n".utf8)); exit(2) }
let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "render":
    guard args.count == 4, let probe = Int(args[2]) else { die("usage: render <probeSeconds> <out>") }
    do { try UpdateInstallScript.render(probeSeconds: probe).write(toFile: args[3], atomically: true, encoding: .utf8) }
    catch { die("write failed: \(error)") }
    guard chmod(args[3], 0o700) == 0 else { die("chmod failed") }
case "spawn-wait":
    guard args.count >= 4 else { die("usage: spawn-wait <home> <script> <args...>") }
    var attributes: posix_spawnattr_t?
    var actions: posix_spawn_file_actions_t?
    guard posix_spawnattr_init(&attributes) == 0, posix_spawn_file_actions_init(&actions) == 0 else { die("spawn init failed") }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    let argv: [UnsafeMutablePointer<CChar>?] = (["/bin/bash"] + args[3...]).map { strdup($0) } + [nil]
    let envp: [UnsafeMutablePointer<CChar>?] = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=" + args[2]].map { strdup($0) } + [nil]
    var pid: pid_t = 0
    guard posix_spawn(&pid, "/bin/bash", &actions, &attributes, argv, envp) == 0 else { die("posix_spawn failed") }
    print("installer pid \(pid) sid \(getsid(pid))")
    fflush(stdout)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 { guard errno == EINTR else { die("waitpid failed") } }
    exit((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
default:
    die("usage: render | spawn-wait")
}
SWIFT
/usr/bin/swiftc -O "$STAGE/tools/UpdateInstallScript.swift" "$STAGE/tools/main.swift" -o "$STAGE/tools/upgrade-helper"
printf 'int main(void) { return 1; }\n' > "$STAGE/tools/crash.c"
/usr/bin/xcrun clang -O2 -o "$STAGE/tools/crash" "$STAGE/tools/crash.c"
HELPER="$STAGE/tools/upgrade-helper"

# ---------------------------------------------------------------- bundles
case "$INPUT" in
  *.zip) /usr/bin/ditto -x -k "$INPUT" "$STAGE/source" ;;
  *.app) /usr/bin/ditto "$INPUT" "$STAGE/source/$EXE.app" ;;
  *) fail "unsupported input: $INPUT" ;;
esac
BASE="$STAGE/source/$EXE.app"
[ -d "$BASE" ] || fail "input does not contain $EXE.app"
/usr/bin/codesign --verify --deep --strict "$BASE"
[ "$(plist "$BASE" CFBundleIdentifier)" = local.wechatmenubridge ] || fail 'unexpected bundle identifier'
[ "$(plist "$BASE" WeChatBridgeNativeQASchema 2>/dev/null)" = 1 ] || fail 'bundle has no NativeQA isolation support; refusing to launch'
[ "$(plist "$BASE" CFBundleExecutable)" = "$EXE" ] || fail 'unexpected executable name'
ID="local.wechatmenubridge.nativeqa.$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" "$BASE/Contents/Info.plist"
say "isolated identity: $ID"

TARGET="$STAGE/$EXE.app"
/usr/bin/ditto "$BASE" "$TARGET"
set_version "$TARGET" 2.1.0 21
/usr/bin/codesign --force --sign - --timestamp=none "$TARGET"
/usr/bin/codesign --verify --deep --strict "$TARGET"

make_staged() { # <work> <short> <build> [crash]
  local work="$1" app="$1/unpacked/$EXE.app"
  mkdir -m 700 "$work" "$work/unpacked"
  /usr/bin/ditto "$BASE" "$app"
  set_version "$app" "$2" "$3"
  if [ "${4:-}" = crash ]; then /usr/bin/install -m 755 "$STAGE/tools/crash" "$app/Contents/MacOS/$EXE"; fi
  /usr/bin/codesign --force --sign - --deep "$app"
  /usr/bin/codesign --verify --deep --strict "$app"
}

leftovers() { /bin/ls -a "$STAGE" | /usr/bin/grep -E "^\.$EXE\.(update|backup)\." || true; }

wait_running() { # <seconds> -> prints pid of the app image at TARGET
  local pid
  for _ in $(seq 1 $(( $1 * 10 ))); do
    pid="$(image_pids "$TARGET/Contents/MacOS/$EXE" | /usr/bin/head -n 1)"
    if [ -n "$pid" ]; then printf '%s\n' "$pid"; return 0; fi
    /bin/sleep 0.1
  done
  return 1
}

wait_engine() { # <seconds>: engine of TARGET running with a state dir in the stage
  local args
  for _ in $(seq 1 $(( $1 * 10 ))); do
    if [ -n "$(image_pids "$TARGET/Contents/MacOS/bridge-engine")" ]; then
      args="$(stage_args_processes | /usr/bin/awk '/\/Contents\/MacOS\/bridge-engine --state-dir / { sub(/^[0-9]+ /, ""); print; exit }')"
      case "$args" in *"--state-dir $STAGE/home/"*|*"--state-dir ${STAGE#/private}/home/"*) printf '%s\n' "$args"; return 0 ;; esac
    fi
    /bin/sleep 0.1
  done
  return 1
}

stays_alive() { # <pid> <seconds>
  for _ in $(seq 1 $(( $2 * 10 ))); do /bin/kill -0 "$1" 2>/dev/null || return 1; /bin/sleep 0.1; done
}

run_installer() { # <old pid> <work> <probe> -> sets INSTALL_STATUS
  local old="$1" work="$2" probe="$3" script="$2/install.sh" status=0
  "$HELPER" render "$probe" "$script"
  /usr/bin/grep -qx "opener='/usr/bin/open'" "$script" || fail 'rendered installer does not use the real /usr/bin/open'
  /usr/bin/grep -Eq "^[[:space:]]*/bin/sleep $probe\$" "$script" || fail "probe $probe not rendered"
  "$HELPER" spawn-wait "$STAGE/home" "$script" "$old" "$TARGET" "$work/unpacked/$EXE.app" "$work" "$EXE" &
  HELPER_PID=$!
  /bin/sleep 0.5
  say "SIGTERM -> running copy pid $old ($(plist "$TARGET" CFBundleShortVersionString))"
  /bin/kill -TERM "$old"
  for _ in {1..1200}; do
    /bin/kill -0 "$HELPER_PID" 2>/dev/null || break
    /bin/sleep 0.1
  done
  if /bin/kill -0 "$HELPER_PID" 2>/dev/null; then fail 'installer did not finish within 120 s'; fi
  wait "$HELPER_PID" || status=$?
  HELPER_PID=
  INSTALL_STATUS="$status"
}

# ---------------------------------------------------------------- A: upgrade
say '== A: real upgrade 2.1.0 -> 2.1.1 =='
/usr/bin/open -n "$TARGET"
OLD_PID="$(wait_running 20)" || fail 'isolated 2.1.0 copy did not start'
ENGINE_ARGS="$(wait_engine 20)" || fail 'isolated 2.1.0 engine did not start inside the stage'
say "2.1.0 running: pid $OLD_PID; engine ${ENGINE_ARGS#"$STAGE"/}"
stays_alive "$OLD_PID" 1 || fail '2.1.0 copy exited by itself'
make_staged "$STAGE/work-A" 2.1.1 22
run_installer "$OLD_PID" "$STAGE/work-A" 4
say "installer exit code: $INSTALL_STATUS"
[ "$INSTALL_STATUS" -eq 0 ] || fail "upgrade installer exited $INSTALL_STATUS"
/bin/kill -0 "$OLD_PID" 2>/dev/null && fail 'old 2.1.0 process still alive'
[ "$(plist "$TARGET" CFBundleShortVersionString)" = 2.1.1 ] || fail 'installed version is not 2.1.1'
[ "$(plist "$TARGET" CFBundleVersion)" = 22 ] || fail 'installed build is not 22'
[ "$(plist "$TARGET" CFBundleIdentifier)" = "$ID" ] || fail 'installed identity changed'
/usr/bin/codesign --verify --deep --strict "$TARGET"
NEW_PID="$(wait_running 5)" || fail 'upgraded 2.1.1 is not running'
[ "$NEW_PID" != "$OLD_PID" ] || fail 'no new process was launched'
stays_alive "$NEW_PID" 3 || fail 'upgraded 2.1.1 did not stay running'
ENGINE_ARGS="$(wait_engine 20)" || fail 'upgraded engine did not start inside the stage'
[ -z "$(leftovers)" ] || fail "update/backup leftovers: $(leftovers)"
[ ! -e "$STAGE/work-A" ] || fail 'work directory (and staged bundle) not cleaned up'
say "PASS A: exit 0; Info.plist 2.1.1 (22); new pid $NEW_PID alive (old $OLD_PID gone); engine ${ENGINE_ARGS#"$STAGE"/}; no backup/update leftovers; work dir removed"

# ---------------------------------------------------------------- B: rollback
say '== B: crash rollback 2.1.1 -> 2.1.2 (exits 1 at launch) =='
make_staged "$STAGE/work-B" 2.1.2 23 crash
[ "$(plist "$STAGE/work-B/unpacked/$EXE.app" CFBundleShortVersionString)" = 2.1.2 ]
run_installer "$NEW_PID" "$STAGE/work-B" 3
say "installer exit code: $INSTALL_STATUS"
[ "$INSTALL_STATUS" -ne 0 ] || fail 'installer reported success for a crashing build'
/bin/kill -0 "$NEW_PID" 2>/dev/null && fail 'previous 2.1.1 process still alive'
[ "$(plist "$TARGET" CFBundleShortVersionString)" = 2.1.1 ] || fail "rollback left $(plist "$TARGET" CFBundleShortVersionString) installed"
[ "$(plist "$TARGET" CFBundleVersion)" = 22 ] || fail 'rollback build is not 22'
/usr/bin/cmp -s "$TARGET/Contents/MacOS/$EXE" "$STAGE/tools/crash" && fail 'crashing executable still installed'
/usr/bin/codesign --verify --deep --strict "$TARGET"
BACK_PID="$(wait_running 15)" || fail 'rolled-back 2.1.1 was not relaunched'
[ "$BACK_PID" != "$NEW_PID" ] || fail 'rolled-back pid equals the terminated one'
stays_alive "$BACK_PID" 3 || fail 'rolled-back 2.1.1 did not stay running'
ENGINE_ARGS="$(wait_engine 20)" || fail 'rolled-back engine did not start inside the stage'
[ -z "$(leftovers)" ] || fail "update/backup leftovers: $(leftovers)"
LOG="$STAGE/work-B/install.log"
[ -s "$LOG" ] || fail 'install.log not kept for diagnosis'
/usr/bin/grep -q '^rollback: new version did not stay running$' "$LOG" || fail 'install.log lacks the rollback record'
say "install.log (kept):"
/usr/bin/sed 's/^/    | /' "$LOG"
say "PASS B: exit $INSTALL_STATUS; Info.plist back to 2.1.1 (22); relaunched pid $BACK_PID alive; engine ${ENGINE_ARGS#"$STAGE"/}; install.log kept; no backup/update leftovers"

# ---------------------------------------------------------------- teardown
say 'terminating isolated copy'
/bin/kill -TERM "$BACK_PID" 2>/dev/null || true
for _ in {1..150}; do
  [ -z "$(qa_processes all "$STAGE")$(stage_args_processes)" ] && break
  /bin/sleep 0.1
done
