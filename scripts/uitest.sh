#!/bin/bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=qa-lifecycle.sh
source "$ROOT/scripts/qa-lifecycle.sh"
if [ "$#" -lt 1 ]; then
  echo 'Usage: bash scripts/uitest.sh <candidate.zip> [-only-testing:BridgeUI/BridgeUITests/testName ...]' >&2
  exit 2
fi
ZIP="$1"
shift
SELECTORS=("$@")
if [ "$#" -eq 0 ]; then
  for name in \
    testFirstLaunchOpensSettingsFromMenuBar \
    testControlWindowOpensFirstLaunchSettings \
    testControlWindowExplainsUnavailableAutomaticReply \
    testOpeningRunningBundleRestoresControlWindow \
    testFirstTimeConfigurationAndLocalPreviewSurviveReopen \
    testCloudRequiresSeparateConsentAndUsesKeychainAfterUpgrade \
    testDraftAutoSwitchPauseRestartAndPeerOptOut \
    testOneShotConfirmsRecipientTextAndTimeAndChecksReceipt \
    testGapAndUnknownSubmissionStayBlockedUntilExplicitReview; do
    SELECTORS+=("-only-testing:BridgeUI/BridgeUITests/$name")
  done
  version="$(/usr/bin/sw_vers -productVersion)"
  if [ "${version%%.*}" -ge 27 ]; then
    SELECTORS+=(
      -only-testing:BridgeUI/BridgeUITests/testAutomaticReplyStartsFromHostedMenuBarAfterConfirmation
      -only-testing:BridgeUI/BridgeUITests/testCloudAutomaticReplyRequiresSeparateMenuBarConfirmation
      -only-testing:BridgeUI/BridgeUITests/testAutomaticReplyOpensReviewWithSettingsStillOpen
      -only-testing:BridgeUI/BridgeUITests/testUnavailableAutomaticReplyExplainsWhatToFixInMenuBar
    )
  fi
fi
for option in "$@"; do
  if [[ ! "$option" =~ ^-only-testing:BridgeUI/BridgeUITests/test[A-Za-z0-9]+$ ]]; then
    printf 'Only individual BridgeUITests selectors are allowed: %s\n' "$option" >&2
    exit 2
  fi
done
QA_LOCK=
STAGE=
XCODE_PID=
SCAN_PID=
PROBE_PID=
XCODE_LOG=
FIXTURES=()
FIXTURE_ENV=
KEYCHAIN=
stop_fixtures() {
  local pid rows clean=1
  for pid in "${FIXTURES[@]+${FIXTURES[@]}}"; do
    qa_stop_child "$pid" || clean=0
  done
  [ "$clean" -eq 1 ] || return 1
  FIXTURES=()
  if [ -n "$FIXTURE_ENV" ]; then unset "$FIXTURE_ENV"; FIXTURE_ENV=; fi
  rows="$(qa_fixture_processes "$STAGE")" || return 1
  if [ -n "$rows" ]; then printf 'Synthetic fixture still running:\n%s\n' "$rows" >&2; return 1; fi
}
cleanup() {
  local result=$? clean=1 pid
  trap '' HUP INT TERM
  if [ -n "$STAGE" ]; then
    # Close the launch gate before stopping the launcher or a surviving runner.
    : > "$STAGE/no-more-launches"
    if [ -n "$XCODE_PID" ]; then qa_stop_child "$XCODE_PID" || clean=0; fi
    qa_reap_stage runner "$STAGE" || clean=0
    qa_reap_stage apps "$STAGE" || clean=0
    qa_reap_stage fixture "$STAGE" || clean=0
  fi
  if [ -n "$SCAN_PID" ]; then qa_stop_child "$SCAN_PID" || clean=0; fi
  if [ -n "$PROBE_PID" ]; then qa_stop_child "$PROBE_PID" || clean=0; fi
  if [ -n "$STAGE" ]; then stop_fixtures || clean=0; fi
  if [ "$result" -ne 0 ] && [ -n "$XCODE_LOG" ] && [ -s "$XCODE_LOG" ]; then
    # xcodebuild may not finish writing xcresult if the caller interrupts it.
    # Keep a useful transcript without dumping build flags or unrelated logs.
    /usr/bin/awk '/^Test Case / { print }' "$XCODE_LOG"
    /usr/bin/grep -E 'BridgeUITests\.swift:[0-9]+: error:|Restarting after|Testing failed:|xcodebuild: error:|^\*\* .* \*\*$' "$XCODE_LOG" | /usr/bin/cut -c 1-500 | /usr/bin/tail -n 12 || true
    /usr/bin/awk '/^    t = / { print }' "$XCODE_LOG" | /usr/bin/tail -n 12
  fi
  if [ "$clean" -ne 1 ]; then
    printf 'QA exit could not be verified. Preserving lock %s and stage %s; do not start another batch.\n' "$QA_LOCK" "$STAGE" >&2
    exit 1
  fi
  if [ -n "$KEYCHAIN" ] && [ -f "$KEYCHAIN" ]; then
    /usr/bin/security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || result=1
  fi
  if [ -n "$STAGE" ]; then
    rm -rf -- "$STAGE"
    echo 'Native QA App, helper, runner and all owned fixtures confirmed exited.'
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
qa_assert_desktop
TEMP_ROOT="${WMB_UI_TEMP_ROOT:-${TMPDIR:-/tmp}/opencode}"
mkdir -p "$TEMP_ROOT"
TEMP_ROOT="$(cd "$TEMP_ROOT" && pwd -P)"
STAGE="$(mktemp -d "$TEMP_ROOT/.uitest.XXXXXX")"

# Never launch or replace the installed app. A fresh bundle identity prevents
# LaunchServices from resolving this launch to another copy of the bridge.
ditto -x -k "$ZIP" "$STAGE"
APP="$STAGE/WeChatMenuBridge.app"
codesign --verify --deep --strict "$APP"
/usr/bin/shasum -a 256 "$ZIP"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = local.wechatmenubridge
if [ "$(/usr/libexec/PlistBuddy -c 'Print :WeChatBridgeNativeQASchema' "$APP/Contents/Info.plist")" != 1 ]; then
  echo 'This ZIP does not support the isolated native QA launcher. Not launching.' >&2
  exit 1
fi
ID="local.wechatmenubridge.nativeqa.$(uuidgen | tr '[:upper:]' '[:lower:]')"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" "$APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
for name in first config controls controls-unavailable reopen cloud replies compose recovery menu-replies menu-cloud menu-settings menu-unavailable; do
  mkdir -m 700 "$STAGE/home-$name"
done

export TEST_RUNNER_WMB_UI_STAGE="$STAGE"
start_fixture() {
  local name="$1" home="$2" info
  env -i HOME="$home" PATH="/usr/bin:/bin" TMPDIR="$home" "$(command -v bun)" --no-env-file \
    "$ROOT/Engine/test/fixture-cli.ts" --until-terminated "--qa-stage=$STAGE" </dev/null >"$STAGE/$name.json" 2>"$STAGE/$name.log" &
  FIXTURES+=("$!")
  for _ in {1..50}; do
    if info="$(jq -ce 'select(.mcp and .model and .control)' "$STAGE/$name.json" 2>/dev/null)" && [ -n "$info" ]; then
      FIXTURE_ENV="TEST_RUNNER_WMB_UI_FIXTURE_$name"
      export "$FIXTURE_ENV=$info"
      return
    fi
    sleep 0.1
  done
  echo "Synthetic fixture $name did not start" >&2
  return 1
}
seed_settings() {
  local home="$1" fixture="$2" mode="${3:-local}" cloud_url="${4:-https://wechat-bridge.invalid/v1/chat/completions}" dir
  dir="$home/Library/Application Support/WeChatMenuBridge"
  mkdir -p "$dir"
  jq -c --arg mode "$mode" --arg cloud_url "$cloud_url" '{mcp, account:"mock_account", accountLabel:"模拟账号",
    contact:{id:"wxid_fixture",label:"模拟联系人"}, mode:$mode,
    modelURL:(if $mode == "cloud" then $cloud_url else .model end),
    modelName:"fixture", stylePath:"", memoryPath:"", dailyLimit:1}' <<< "$fixture" > "$dir/settings.json"
}
prepare_fixture() {
  case "$1" in
    testFirstTimeConfigurationAndLocalPreviewSurviveReopen)
      start_fixture CONFIG "$STAGE/home-config" ;;
    testCloudRequiresSeparateConsentAndUsesKeychainAfterUpgrade)
      start_fixture CLOUD "$STAGE/home-cloud"
      seed_settings "$STAGE/home-cloud" "$TEST_RUNNER_WMB_UI_FIXTURE_CLOUD" cloud ;;
    testDraftAutoSwitchPauseRestartAndPeerOptOut)
      start_fixture REPLIES "$STAGE/home-replies"
      seed_settings "$STAGE/home-replies" "$TEST_RUNNER_WMB_UI_FIXTURE_REPLIES" ;;
    testAutomaticReplyStartsFromHostedMenuBarAfterConfirmation)
      start_fixture MENUREPLIES "$STAGE/home-menu-replies"
      seed_settings "$STAGE/home-menu-replies" "$TEST_RUNNER_WMB_UI_FIXTURE_MENUREPLIES" ;;
    testCloudAutomaticReplyRequiresSeparateMenuBarConfirmation)
      start_fixture MENUCLOUD "$STAGE/home-menu-cloud"
      seed_settings "$STAGE/home-menu-cloud" "$TEST_RUNNER_WMB_UI_FIXTURE_MENUCLOUD" cloud https://wechat-bridge.invalid/v1 ;;
    testAutomaticReplyOpensReviewWithSettingsStillOpen)
      start_fixture MENUSETTINGS "$STAGE/home-menu-settings"
      seed_settings "$STAGE/home-menu-settings" "$TEST_RUNNER_WMB_UI_FIXTURE_MENUSETTINGS" cloud https://wechat-bridge.invalid/v1 ;;
    testOneShotConfirmsRecipientTextAndTimeAndChecksReceipt)
      start_fixture COMPOSE "$STAGE/home-compose"
      seed_settings "$STAGE/home-compose" "$TEST_RUNNER_WMB_UI_FIXTURE_COMPOSE" ;;
    testGapAndUnknownSubmissionStayBlockedUntilExplicitReview)
      start_fixture RECOVERY "$STAGE/home-recovery"
      seed_settings "$STAGE/home-recovery" "$TEST_RUNNER_WMB_UI_FIXTURE_RECOVERY" ;;
    testFirstLaunchOpensSettingsFromMenuBar|testControlWindowOpensFirstLaunchSettings|testControlWindowExplainsUnavailableAutomaticReply|testOpeningRunningBundleRestoresControlWindow|testUnavailableAutomaticReplyExplainsWhatToFixInMenuBar) ;;
    *) printf 'No isolated fixture mapping for %s; not launching.\n' "$1" >&2; return 1 ;;
  esac
}

# Synthetic keychain only; no list-keychains, default-keychain, or login-keychain changes.
KEYCHAIN="$STAGE/home-cloud/nativeqa.keychain-db"
/usr/bin/security create-keychain -p "$(uuidgen)" "$KEYCHAIN"
test -f "$KEYCHAIN"
xcode=(/usr/bin/xcodebuild -project "$ROOT/App/NativeUITests/BridgeUI.xcodeproj" -scheme BridgeUI
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO ARCHS=arm64
  -derivedDataPath "$STAGE/derived")
XCODE_LOG="$STAGE/build-for-testing.log"
"${xcode[@]}" build-for-testing >"$XCODE_LOG" 2>&1 &
XCODE_PID=$!
status=0
wait "$XCODE_PID" || status=$?
XCODE_PID=
if [ "$status" -ne 0 ]; then
  /usr/bin/grep -E 'error:|^\*\* .* \*\*$' "$XCODE_LOG" | /usr/bin/tail -n 12 || true
  exit "$status"
fi

menu_fixture() {
  local app="$STAGE/MenuBarFixture.app" marker="$STAGE/menu-focus"
  if [ ! -d "$app" ]; then
    mkdir -p "$app/Contents/MacOS"
    /usr/bin/swiftc -parse-as-library "$ROOT/App/NativeUITests/MenuBarFixture.swift" -o "$app/Contents/MacOS/MenuBarFixture"
    /usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleIdentifier -string "local.wechatmenubridge.menubar-fixture.${ID##*.}" "$app/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleExecutable -string 'MenuBarFixture' "$app/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleName -string 'QA' "$app/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundlePackageType -string 'APPL' "$app/Contents/Info.plist"
    codesign --sign - --timestamp=none "$app"
  fi
  /bin/rm -f -- "$marker"
  mkdir -p "$STAGE/home-focus"
  : > "$STAGE/menu-focus.log"
  /usr/bin/open -a "$app" --env "HOME=$STAGE/home-focus" --env "CFFIXED_USER_HOME=$STAGE/home-focus" \
    --env "WMB_UI_FOCUS_MARKER=$marker" --stderr "$STAGE/menu-focus.log" --args -ApplePersistenceIgnoreState YES
  # Fail before clicking anything if the exact fixture never takes focus.
  for _ in {1..150}; do
    if [ -f "$marker" ]; then printf 'QA foreground menu on display %s\n' "$(cat "$marker")"; return; fi
    /bin/sleep 0.1
  done
  echo 'Could not focus the isolated menu-bar workspace.' >&2
  /usr/bin/tail -n 10 "$STAGE/menu-focus.log" >&2
  return 1
}

# One case per Xcode invocation. Xcode may replace a runner after a lost
# connection or timeout; a new runner is allowed only at a boundary that this
# script owns, after a fresh App/helper/runner exit check under the same lock.
passed=0 failed=0 skipped=0
seen=()
for selector in "${SELECTORS[@]}"; do
  name="${selector##*/}"
  for prior in "${seen[@]+${seen[@]}}"; do
    if [ "$name" = "$prior" ]; then echo "Repeated selector: $name" >&2; exit 2; fi
  done
  seen+=("$name")
  qa_assert_desktop
  qa_assert_idle
  printf 'Running %s (previous isolated App, helper, runner and fixtures exited)\n' "$name"
  prepare_fixture "$name"
  if [ "${WMB_UI_FOCUS_HOST:-}" = 1 ]; then
    case "$name" in
      testFirstLaunchOpensSettingsFromMenuBar|testAutomaticReplyStartsFromHostedMenuBarAfterConfirmation|testCloudAutomaticReplyRequiresSeparateMenuBarConfirmation|testAutomaticReplyOpensReviewWithSettingsStillOpen|testUnavailableAutomaticReplyExplainsWhatToFixInMenuBar)
        menu_fixture
        ;;
    esac
  fi
  /bin/rm -f -- "$STAGE/no-more-launches" "$STAGE/process-snapshot"
  qa_watch_process_checks "$STAGE" desktop &
  SCAN_PID=$!
  if [ "${WMB_UI_PROBE_HIT:-}" = 1 ] && [ "$name" = testFirstLaunchOpensSettingsFromMenuBar ]; then
    # Read-only host diagnostic; it never clicks or exposes other AX attributes.
    /usr/bin/swiftc "$ROOT/App/NativeUITests/MenuHitProbe.swift" -o "$STAGE/MenuHitProbe"
    "$STAGE/MenuHitProbe" "$STAGE" "$ID" >"$STAGE/menu-hit-probe.log" 2>&1 &
    PROBE_PID=$!
  fi
  RESULT="$STAGE/$name.xcresult"
  XCODE_LOG="$STAGE/$name.log"
  status=0
  "${xcode[@]}" -resultBundlePath "$RESULT" "$selector" test-without-building >"$XCODE_LOG" 2>&1 &
  XCODE_PID=$!
  wait "$XCODE_PID" || status=$?
  XCODE_PID=
  healthy=1
  /bin/kill -0 "$SCAN_PID" 2>/dev/null || healthy=0
  : > "$STAGE/no-more-launches"
  qa_stop_child "$SCAN_PID"
  SCAN_PID=
  if [ -n "$PROBE_PID" ]; then
    qa_stop_child "$PROBE_PID"
    PROBE_PID=
    /bin/cat "$STAGE/menu-hit-probe.log"
  fi
  scan_state="$(/usr/bin/sed -n '2p' "$STAGE/process-snapshot")"
  qa_reap_stage fixture "$STAGE"
  stop_fixtures
  if [ "$healthy" -ne 1 ] || [ "$scan_state" != ok ]; then
    printf 'QA process check did not stay healthy (%s); stopping batch.\n' "$scan_state" >&2
    if [ -d "$RESULT" ]; then
      xcrun xcresulttool get test-results summary --path "$RESULT" |
        jq -r '.testFailures[]?.failureText | split("\n")[:8] | join("\n")' || true
    fi
    exit 1
  fi
  # Xcode may finish reporting just before LaunchServices exits the runner.
  # Wait for a fresh empty process list; never rely on a cleanup kill here.
  rows=
  for _ in {1..40}; do
    rows="$(qa_processes)"
    [ -n "$rows" ] || break
    /bin/sleep 0.1
  done
  qa_assert_idle
  if [ ! -d "$RESULT" ]; then
    /usr/bin/grep -E 'error:|^\*\* .* \*\*$' "$XCODE_LOG" | /usr/bin/tail -n 12 || true
    exit 1
  fi
  summary="$STAGE/$name.json"
  xcrun xcresulttool get test-results summary --path "$RESULT" >"$summary"
  if ! jq -e '.passedTests + .failedTests + .skippedTests == 1' "$summary" >/dev/null; then
    jq '{result, passedTests, failedTests, skippedTests, testFailures: [.testFailures[]? | .failureText | split("\n")[:8] | join("\n")]}' "$summary"
    echo 'Expected exactly one native test result.' >&2
    exit 1
  fi
  xcrun xcresulttool get test-results tests --path "$RESULT" >"$STAGE/$name-tests.json"
  if ! jq -er --arg id "BridgeUITests/$name()" '.. | objects | select(.nodeType == "Test Case" and .nodeIdentifier == $id) | "\(.result) \(.nodeIdentifier)"' "$STAGE/$name-tests.json"; then
    jq -r '.. | objects | select(.nodeType == "Test Case") | "\(.result) \(.nodeIdentifier)"' "$STAGE/$name-tests.json"
    printf 'Native result does not identify the selected case: %s\n' "$name" >&2
    exit 1
  fi
  if [ "$status" -eq 0 ]; then
    jq -e '.result == "Passed" and .passedTests == 1' "$summary" >/dev/null
    passed=$((passed + 1))
  else
    jq -e '.passedTests == 0' "$summary" >/dev/null
    failed=$((failed + $(jq -r '.failedTests' "$summary")))
    skipped=$((skipped + $(jq -r '.skippedTests' "$summary")))
    jq -r '.testFailures[]?.failureText | split("\n")[:12] | join("\n")' "$summary"
    /usr/bin/awk '/^    t = / { print }' "$XCODE_LOG" | /usr/bin/tail -n 16
  fi
  XCODE_LOG=
done

for home in "$STAGE"/home-*; do
  if [ -f "$home/status-anchor.json" ]; then printf 'Own status item: '; cat "$home/status-anchor.json"; printf '\n'; fi
  if [ -f "$home/anchor-diagnostic" ]; then cat "$home/anchor-diagnostic"; printf '\n'; fi
  if [ -f "$home/status-click.txt" ]; then cat "$home/status-click.txt"; printf '\n'; fi
  if [ -f "$home/Library/Application Support/WeChatMenuBridge/bridge.sqlite" ]; then printf 'App initialized isolated state.\n'; fi
done
printf 'Native UI totals: %s passed, %s failed, %s skipped\n' "$passed" "$failed" "$skipped"
test "$passed" -eq "${#SELECTORS[@]}"
