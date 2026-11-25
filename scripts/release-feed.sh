#!/bin/bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
VERSION=""
BUILD=""
ZIP_PATH=""
DOWNLOAD_URL=""
CHANNEL="stable"
NOTES="常规更新与问题修复"
MIN_MACOS="13.0"
KEY_PATH=""
OUT_DIR=""
WITH_BUNDLES=0
COMPAT_PATH=""
ADDON_PATH=""
ALLOW_CUSTOM_KEY=0
VERIFY_REPO_VERSION=0

usage() {
  cat >&2 <<'EOF'
Usage: bash scripts/release-feed.sh \
  --version 2.2.1 --build 23 --zip dist/WeChatMenuBridge-v2.2.1/WeChatMenuBridge-arm64.zip \
  --url https://github.com/<owner>/<repo>/releases/download/v2.2.1/WeChatMenuBridge-arm64.zip \
  --out-dir dist/feed [--channel stable|beta] [--notes "更新说明"] [--min-macos 13.0] \
  [--ed25519-key key.pem] [--with-bundles] [--compat model-compat.json] [--addon reply-prompt-addon.md] \
  [--verify-repo-version] [--allow-custom-key]
EOF
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --build) BUILD="${2:-}"; shift 2 ;;
    --zip) ZIP_PATH="${2:-}"; shift 2 ;;
    --url) DOWNLOAD_URL="${2:-}"; shift 2 ;;
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --notes) NOTES="${2:-}"; shift 2 ;;
    --min-macos) MIN_MACOS="${2:-}"; shift 2 ;;
    --ed25519-key) KEY_PATH="${2:-}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --with-bundles) WITH_BUNDLES=1; shift ;;
    --compat) COMPAT_PATH="${2:-}"; shift 2 ;;
    --addon) ADDON_PATH="${2:-}"; shift 2 ;;
    --allow-custom-key) ALLOW_CUSTOM_KEY=1; shift ;;
    --verify-repo-version) VERIFY_REPO_VERSION=1; shift ;;
    *) usage ;;
  esac
done

if [ -z "$VERSION" ] || [ -z "$BUILD" ] || [ -z "$ZIP_PATH" ] || [ -z "$DOWNLOAD_URL" ] || [ -z "$OUT_DIR" ]; then
  usage
fi
if [ ! -f "$ZIP_PATH" ]; then
  echo "Zip file not found: $ZIP_PATH" >&2
  exit 1
fi
if [ "$WITH_BUNDLES" -eq 1 ] && [ -z "$KEY_PATH" ]; then
  echo "--with-bundles requires --ed25519-key" >&2
  exit 2
fi
if [ "$VERIFY_REPO_VERSION" -eq 1 ]; then
  PLIST_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/App/Info.plist")"
  PLIST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/App/Info.plist")"
  FALLBACK_SHORT="$(sed -n 's/.*static let fallbackShort = "\([^"]*\)".*/\1/p' "$ROOT/App/Sources/WeChatMenu/Views/FeedbackView.swift" | head -n 1)"
  FALLBACK_BUILD="$(sed -n 's/.*static let fallbackBuild = "\([^"]*\)".*/\1/p' "$ROOT/App/Sources/WeChatMenu/Views/FeedbackView.swift" | head -n 1)"
  if [ "$VERSION" != "$PLIST_SHORT" ] || [ "$BUILD" != "$PLIST_BUILD" ] || \
     [ "$VERSION" != "$FALLBACK_SHORT" ] || [ "$BUILD" != "$FALLBACK_BUILD" ]; then
    echo "Version mismatch: requested $VERSION ($BUILD), Info.plist $PLIST_SHORT ($PLIST_BUILD), FeedbackView $FALLBACK_SHORT ($FALLBACK_BUILD)" >&2
    exit 1
  fi
fi
mkdir -p "$OUT_DIR"

bun -e '
import { createHash, createPrivateKey, sign } from "node:crypto";
import { readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [version, build, zipPath, url, channel, notes, minMacos, keyPath, outDir] = process.argv.slice(1);
const data = readFileSync(zipPath);
const length = statSync(zipPath).size;
const sha256 = createHash("sha256").update(data).digest("hex");
const pubDate = new Date().toUTCString();
let edSignature = "";
if (keyPath) {
  const priv = createPrivateKey(readFileSync(keyPath, "utf8"));
  edSignature = sign(null, data, priv).toString("base64");
}

const xmlEscape = (s: string) => s
  .replace(/&/g, "&amp;")
  .replace(/</g, "&lt;")
  .replace(/>/g, "&gt;")
  .replace(/"/g, "&quot;")
  .replace(/'\''/g, "&apos;");

const item = {
  title: `微信桥 ${version}`,
  description: notes,
  pubDate,
  url,
  length,
  shortVersionString: version,
  version: build,
  channel,
  minimumSystemVersion: minMacos,
  sha256,
  ...(edSignature ? { edSignature } : {}),
};

writeFileSync(join(outDir, "appcast.json"), JSON.stringify({ items: [item] }, null, 2) + "\n", { mode: 0o644 });

const sigAttr = edSignature ? ` sparkle:edSignature="${xmlEscape(edSignature)}"` : "";
const channelTag = channel && channel !== "stable" ? `\n      <sparkle:channel>${xmlEscape(channel)}</sparkle:channel>` : "";
const xml = `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>微信桥更新源</title>
    <item>
      <title>${xmlEscape(item.title)}</title>
      <description>${xmlEscape(notes)}</description>
      <pubDate>${xmlEscape(pubDate)}</pubDate>
      <sparkle:version>${xmlEscape(build)}</sparkle:version>
      <sparkle:shortVersionString>${xmlEscape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${xmlEscape(minMacos)}</sparkle:minimumSystemVersion>${channelTag}
      <enclosure url="${xmlEscape(url)}" length="${length}" type="application/octet-stream" sparkle:sha256="${sha256}"${sigAttr} />
    </item>
  </channel>
</rss>
`;
writeFileSync(join(outDir, "appcast.xml"), xml, { mode: 0o644 });
console.log(JSON.stringify({ ok: true, outDir, sha256, length, signed: !!edSignature }));
' "$VERSION" "$BUILD" "$ZIP_PATH" "$DOWNLOAD_URL" "$CHANNEL" "$NOTES" "$MIN_MACOS" "$KEY_PATH" "$OUT_DIR"

if [ "$WITH_BUNDLES" -eq 1 ]; then
  BUNDLE_ARGS=(--version "$VERSION" --ed25519-key "$KEY_PATH" --out-dir "$OUT_DIR")
  if [ -n "$COMPAT_PATH" ]; then BUNDLE_ARGS+=(--compat "$COMPAT_PATH"); fi
  if [ -n "$ADDON_PATH" ]; then BUNDLE_ARGS+=(--addon "$ADDON_PATH"); fi
  if [ "$ALLOW_CUSTOM_KEY" -eq 1 ]; then BUNDLE_ARGS+=(--allow-custom-key); fi
  bash "$ROOT/scripts/release-bundles.sh" "${BUNDLE_ARGS[@]}"
fi
