#!/bin/bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DIST="${1:-$ROOT/dist}"
mkdir -p "$DIST"
DIST="$(cd "$DIST" && pwd -P)"
STAGE="$(mktemp -d "$DIST/.package.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT
NAME=WeChatMenuBridge
APP="$STAGE/$NAME.app"

BUN_INSTALL_FLAGS=(--frozen-lockfile --ignore-scripts)
if [ "${WMB_BUILD_OFFLINE:-}" = 1 ]; then BUN_INSTALL_FLAGS+=(--offline); fi
(cd "$ROOT/Engine" && bun install "${BUN_INSTALL_FLAGS[@]}" && bun run check && WMB_ENGINE_OUT="$STAGE/bridge-engine" bun run build)
swift build --package-path "$ROOT/App" -c release
BIN="$(swift build --package-path "$ROOT/App" -c release --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$STAGE/Bridge.iconset"
install -m 644 "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
install -m 755 "$BIN/$NAME" "$STAGE/bridge-engine" "$APP/Contents/MacOS/"
# 去掉调试信息和本机工具链路径；应用只需要系统的 Swift 运行库。修改后再签名。
SWIFT_EXE="$APP/Contents/MacOS/$NAME"
xcrun strip -S "$SWIFT_EXE"
RPATHS="$(otool -l "$SWIFT_EXE" | awk '
  $1 == "cmd" && $2 == "LC_RPATH" {
    getline; getline; sub(/^[[:space:]]*path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print
  }')"
while IFS= read -r entry; do
  case "$entry" in
    /usr/lib/swift) ;;
    /*) xcrun install_name_tool -delete_rpath "$entry" "$SWIFT_EXE" ;;
  esac
done <<< "$RPATHS"
swift "$ROOT/scripts/icon.swift" "$STAGE/Bridge.iconset"
iconutil -c icns "$STAGE/Bridge.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
plutil -lint "$APP/Contents/Info.plist"
SIGN_ID="${WMB_CODESIGN_IDENTITY:--}"
SIGN_ARGS=(--force --sign "$SIGN_ID")
if [ "$SIGN_ID" = "-" ]; then
  SIGN_ARGS+=(--timestamp=none)
fi
codesign "${SIGN_ARGS[@]}" --identifier local.wechatmenubridge.helper "$APP/Contents/MacOS/bridge-engine"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent "$APP" "$STAGE/$NAME-arm64.zip"

# Keep any previous project-local bundle in the disposable stage during the swap.
if [ -e "$DIST/$NAME.app" ]; then mv "$DIST/$NAME.app" "$STAGE/previous.app"; fi
mv "$APP" "$DIST/$NAME.app"
mv "$STAGE/$NAME-arm64.zip" "$DIST/$NAME-arm64.zip"
shasum -a 256 "$DIST/$NAME-arm64.zip"
