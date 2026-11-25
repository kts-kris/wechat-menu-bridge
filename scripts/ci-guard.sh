#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

echo "[ci-guard] 1. Verify zero external SwiftPM dependencies"
if grep -Eq '\.package\s*\(' App/Package.swift; then
  echo "FAIL: App/Package.swift must not declare external SwiftPM dependencies (offline build invariant)." >&2
  exit 1
fi

echo "[ci-guard] 2. Verify Info.plist and FeedbackView.swift version parity"
PLIST_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Info.plist)"
PLIST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' App/Info.plist)"
FALLBACK_SHORT="$(sed -n 's/.*static let fallbackShort = "\([^"]*\)".*/\1/p' App/Sources/WeChatMenu/Views/FeedbackView.swift | head -n 1)"
FALLBACK_BUILD="$(sed -n 's/.*static let fallbackBuild = "\([^"]*\)".*/\1/p' App/Sources/WeChatMenu/Views/FeedbackView.swift | head -n 1)"
if [ "$PLIST_SHORT" != "$FALLBACK_SHORT" ] || [ "$PLIST_BUILD" != "$FALLBACK_BUILD" ]; then
  echo "FAIL: Version mismatch: Info.plist=$PLIST_SHORT ($PLIST_BUILD) vs FeedbackView=$FALLBACK_SHORT ($FALLBACK_BUILD)" >&2
  exit 1
fi

echo "[ci-guard] 3. Verify Info.plist SUPublicEDKey matches hot-bundles.ts OFFICIAL_BUNDLE_PUBLIC_KEY"
PLIST_PUB="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' App/Info.plist)"
ENGINE_PUB="$(sed -n "s/.*OFFICIAL_BUNDLE_PUBLIC_KEY = '\([^']*\)'.*/\1/p" Engine/src/storage/hot-bundles.ts | head -n 1)"
if [ -z "$PLIST_PUB" ] || [ "$PLIST_PUB" != "$ENGINE_PUB" ]; then
  echo "FAIL: Public key mismatch between Info.plist ($PLIST_PUB) and hot-bundles.ts ($ENGINE_PUB)" >&2
  exit 1
fi

echo "[ci-guard] 4. Scan tracked files for private keys or hardcoded developer home paths"
if git grep -nE 'BEGIN (OPENSSH |RSA |EC |ENCRYPTED )?PRIVATE KEY' -- ':!Engine/test/*' ':!App/Tests/*' ':!scripts/ci-guard.sh' ':!scripts/release-bundles.sh'; then
  echo "FAIL: Possible private key header found in tracked source files." >&2
  exit 1
fi
if git grep -nE '/Users/[A-Za-z0-9._-]+/' -- ':!scripts/ci-guard.sh' ':!scripts/release-bundles.sh' ':!Engine/test/*'; then
  echo "FAIL: Hardcoded local /Users/<name>/ path found in tracked files." >&2
  exit 1
fi

echo "[ci-guard] 5. Guard Engine/test/faults.test.ts against weakening"
BASE_REF="${CI_BASE_REF:-}"
if [ -n "$BASE_REF" ] && git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
  BASE_TESTS="$(git show "$BASE_REF:Engine/test/faults.test.ts" | grep -Ec '^[[:space:]]*test\(' || true)"
  HEAD_TESTS="$(grep -Ec '^[[:space:]]*test\(' Engine/test/faults.test.ts || true)"
  if [ "$HEAD_TESTS" -lt "$BASE_TESTS" ]; then
    echo "FAIL: Engine/test/faults.test.ts test count decreased ($BASE_TESTS -> $HEAD_TESTS)." >&2
    exit 1
  fi
  BASE_ASSERTS="$(git show "$BASE_REF:Engine/test/faults.test.ts" | grep -Ec 'expect\(' || true)"
  HEAD_ASSERTS="$(grep -Ec 'expect\(' Engine/test/faults.test.ts || true)"
  if [ "$HEAD_ASSERTS" -lt "$BASE_ASSERTS" ]; then
    echo "FAIL: Engine/test/faults.test.ts assertion count decreased ($BASE_ASSERTS -> $HEAD_ASSERTS)." >&2
    exit 1
  fi
  echo "[ci-guard] faults.test.ts verified: tests $BASE_TESTS -> $HEAD_TESTS, asserts $BASE_ASSERTS -> $HEAD_ASSERTS"
fi

echo "[ci-guard] PASS"
