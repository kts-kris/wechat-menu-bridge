#!/bin/bash
set -euo pipefail
umask 077

VERSION=""
BUILD=""
ZIP_PATH=""
DOWNLOAD_URL=""
CHANNEL="stable"
NOTES="常规更新与问题修复"
MIN_MACOS="13.0"
KEY_PATH=""
OUT_DIR=""

usage() {
  cat >&2 <<'EOF'
Usage: bash scripts/release-feed.sh \
  --version 2.0.0 --build 20 --zip dist/WeChatMenuBridge-v2.0.0/WeChatMenuBridge-arm64.zip \
  --url https://github.com/<owner>/<repo>/releases/download/v2.0.0/WeChatMenuBridge-arm64.zip \
  --out-dir dist/feed [--channel stable|beta] [--notes "更新说明"] [--min-macos 13.0] [--ed25519-key key.pem]
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
