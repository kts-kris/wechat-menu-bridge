#!/bin/bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
VERSION=""
KEY_PATH=""
OUT_DIR=""
COMPAT_PATH=""
ADDON_PATH=""
ALLOW_CUSTOM_KEY=0

usage() {
  cat >&2 <<'EOF'
Usage: bash scripts/release-bundles.sh \
  --version 2.2.1 \
  --ed25519-key "$HOME/.config/wechat-menu-bridge/release/ed25519.pem" \
  --out-dir dist/WeChatMenuBridge-v2.2.1/release-assets \
  [--compat path/to/model-compat.json] \
  [--addon path/to/reply-prompt-addon.md] \
  [--allow-custom-key]
EOF
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --ed25519-key) KEY_PATH="${2:-}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --compat) COMPAT_PATH="${2:-}"; shift 2 ;;
    --addon) ADDON_PATH="${2:-}"; shift 2 ;;
    --allow-custom-key) ALLOW_CUSTOM_KEY=1; shift ;;
    *) usage ;;
  esac
done

if [ -z "$VERSION" ] || [ -z "$KEY_PATH" ] || [ -z "$OUT_DIR" ]; then
  usage
fi
if [ ! -f "$KEY_PATH" ]; then
  echo "Ed25519 private key not found: $KEY_PATH" >&2
  exit 1
fi
if [ -n "$COMPAT_PATH" ] && [ ! -f "$COMPAT_PATH" ]; then
  echo "model-compat.json not found: $COMPAT_PATH" >&2
  exit 1
fi
if [ -n "$ADDON_PATH" ] && [ ! -f "$ADDON_PATH" ]; then
  echo "reply-prompt-addon.md not found: $ADDON_PATH" >&2
  exit 1
fi

PLIST_PUB="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT/App/Info.plist")"

bun -e '
import { createHash, createPrivateKey, createPublicKey, sign } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { isIP } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { z } from "zod";
import { HotBundleManager, OFFICIAL_BUNDLE_PUBLIC_KEY } from "./Engine/src/storage/hot-bundles.ts";

const [root, version, keyPath, outDir, compatPath, addonPath, allowCustomKeyFlag, plistPub] = process.argv.slice(1);
const allowCustomKey = allowCustomKeyFlag === "1";
const MAX_BUNDLE_BYTES = 256 * 1024;

if (!version || version.trim().length === 0 || version.length > 64) {
  console.error("Invalid --version (must be 1..64 non-empty characters).");
  process.exit(1);
}

const modelCompatSchema = z.strictObject({
  disableReasoningEffortUrls: z.array(z.string().url()).max(128).default([]),
});

const LEAK_PATTERNS: Array<{ label: string; regex: RegExp }> = [
  { label: "PEM private key header", regex: /BEGIN\s+(?:OPENSSH\s+|RSA\s+|EC\s+|ENCRYPTED\s+)?PRIVATE\s+KEY/i },
  { label: "OpenAI-style API key (sk-...)", regex: /(?<![A-Za-z0-9])sk[-_][A-Za-z0-9_-]{8,}/i },
  { label: "GitHub token", regex: /(?<![A-Za-z0-9])(?:gh[pousr]_[A-Za-z0-9]{12,}|github_pat_[A-Za-z0-9_]{16,})/ },
  { label: "Slack/webhook token", regex: /(?<![A-Za-z0-9])xox[abprs]-[A-Za-z0-9-]{10,}/ },
  { label: "Bearer authorization header", regex: /\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/i },
  { label: "inline credential assignment", regex: /(?<![A-Za-z0-9])(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|password|passwd)\s*[:=]\s*["'\'']?[A-Za-z0-9._~+/=-]{6,}/i },
  { label: "local macOS/Linux user path", regex: /(?:^|[\s"'\''`(])\/(?:Users|home)\/[A-Za-z0-9._-]+\// },
  { label: "local Windows user path", regex: /[A-Za-z]:\\Users\\[A-Za-z0-9._-]+\\/ },
];

function checkPublicHttpsUrl(raw: string): string | null {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return `invalid URL: ${raw}`;
  }
  if (url.protocol !== "https:") return `non-HTTPS URL not allowed in public bundle: ${raw}`;
  if (url.username || url.password) return `URL must not contain userinfo credentials: ${raw}`;
  if (url.search) return `URL must not contain query parameters (risk of leaking keys/tokens): ${raw}`;
  if (url.hash) return `URL must not contain fragment: ${raw}`;

  const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (!host) return `empty hostname: ${raw}`;
  if (isIP(host) !== 0) {
    return `raw IP literal not allowed in public model-compat.json (use public domain name): ${raw}`;
  }
  if (
    host === "localhost" ||
    !host.includes(".") ||
    /\.(?:localhost|local|internal|lan|home|corp|arpa|localdomain|intranet)$/i.test(host)
  ) {
    return `local or private hostname not allowed in public model-compat.json: ${raw}`;
  }
  return null;
}

function scanTextForLeaks(name: string, content: string): string[] {
  const issues: string[] = [];
  const bytes = Buffer.byteLength(content, "utf8");
  if (bytes > MAX_BUNDLE_BYTES) {
    issues.push(`${name}: exceeds ${MAX_BUNDLE_BYTES} byte limit (${bytes} bytes)`);
  }
  for (const rule of LEAK_PATTERNS) {
    if (rule.regex.test(content)) {
      issues.push(`${name}: matched forbidden leak pattern (${rule.label})`);
    }
  }
  return issues;
}

// 1. Load and validate assets in memory before touching outDir.
const rawCompat = compatPath
  ? readFileSync(compatPath, "utf8")
  : JSON.stringify({ disableReasoningEffortUrls: [] }, null, 2) + "\n";

let parsedCompatJson: unknown;
try {
  parsedCompatJson = JSON.parse(rawCompat);
} catch (error) {
  console.error(`model-compat.json is not valid JSON: ${(error as Error).message}`);
  process.exit(1);
}
const compatCheck = modelCompatSchema.safeParse(parsedCompatJson);
if (!compatCheck.success) {
  console.error(`model-compat.json failed schema validation: ${compatCheck.error.message}`);
  process.exit(1);
}

const leakErrors: string[] = [];
for (const url of compatCheck.data.disableReasoningEffortUrls) {
  const err = checkPublicHttpsUrl(url);
  if (err) leakErrors.push(`model-compat.json: ${err}`);
}
leakErrors.push(...scanTextForLeaks("model-compat.json", rawCompat));

const assets: Record<string, Buffer> = {
  "model-compat.json": Buffer.from(rawCompat, "utf8"),
};

if (addonPath) {
  const rawAddon = readFileSync(addonPath, "utf8");
  leakErrors.push(...scanTextForLeaks("reply-prompt-addon.md", rawAddon));
  assets["reply-prompt-addon.md"] = Buffer.from(rawAddon, "utf8");
}

if (leakErrors.length > 0) {
  console.error("Leak scan / validation FAILED — refusing to sign or write any files:");
  for (const issue of leakErrors) console.error(`  - ${issue}`);
  process.exit(1);
}

// 2. Verify private key and derived public key parity.
const priv = createPrivateKey(readFileSync(keyPath, "utf8"));
if (priv.asymmetricKeyType !== "ed25519") {
  console.error(`Expected an Ed25519 private key, got: ${priv.asymmetricKeyType ?? "unknown"}`);
  process.exit(1);
}
const pubSpkiDer = createPublicKey(priv).export({ type: "spki", format: "der" }) as Buffer;
const derivedPublicKey = pubSpkiDer.subarray(-32).toString("base64");

if (!allowCustomKey) {
  if (plistPub !== OFFICIAL_BUNDLE_PUBLIC_KEY) {
    console.error(`Repository key mismatch: Info.plist SUPublicEDKey (${plistPub}) != OFFICIAL_BUNDLE_PUBLIC_KEY (${OFFICIAL_BUNDLE_PUBLIC_KEY})`);
    process.exit(1);
  }
  if (derivedPublicKey !== OFFICIAL_BUNDLE_PUBLIC_KEY) {
    console.error(`Signing key mismatch: derived public key (${derivedPublicKey}) does not match official repository key (${OFFICIAL_BUNDLE_PUBLIC_KEY}). Use --allow-custom-key only for isolated tests.`);
    process.exit(1);
  }
}

// 3. Sign canonical manifest payload (sorted file keys).
const sortedNames = Object.keys(assets).sort((a, b) => a.localeCompare(b));
const files: Record<string, string> = {};
for (const name of sortedNames) {
  files[name] = createHash("sha256").update(assets[name]!).digest("hex");
}
const canonicalPayload = JSON.stringify({ version, files });
const signature = sign(null, Buffer.from(canonicalPayload, "utf8"), priv).toString("base64");
const manifestText = JSON.stringify({ version, files, signature }, null, 2) + "\n";

// 4. End-to-end self-verification via real HotBundleManager in an isolated temp dir.
const verifyRoot = mkdtempSync(join(tmpdir(), "wmb-bundle-verify-"));
try {
  const verifyBundles = join(verifyRoot, "bundles");
  mkdirSync(verifyBundles, { mode: 0o700, recursive: true });
  for (const name of sortedNames) {
    writeFileSync(join(verifyBundles, name), assets[name]!, { mode: 0o600 });
  }
  writeFileSync(join(verifyBundles, "manifest.json"), manifestText, { mode: 0o600 });
  const manager = new HotBundleManager(verifyRoot, { pinnedPublicKeyBase64: derivedPublicKey });
  const status = manager.status();
  if (status.version !== version || status.loadedCount !== sortedNames.length || !status.items.every(i => i.verified)) {
    console.error(`HotBundleManager self-verification failed: ${JSON.stringify(status)}`);
    process.exit(1);
  }
} finally {
  rmSync(verifyRoot, { recursive: true, force: true });
}

// 5. Commit verified public release assets to outDir.
mkdirSync(outDir, { recursive: true });
for (const name of sortedNames) {
  writeFileSync(join(outDir, name), assets[name]!, { mode: 0o644 });
}
writeFileSync(join(outDir, "bundles-manifest.json"), manifestText, { mode: 0o644 });

console.log(JSON.stringify({
  ok: true,
  version,
  outDir,
  publicKey: derivedPublicKey,
  files: sortedNames,
  verified: true,
}));
' "$ROOT" "$VERSION" "$KEY_PATH" "$OUT_DIR" "$COMPAT_PATH" "$ADDON_PATH" "$ALLOW_CUSTOM_KEY" "$PLIST_PUB"
