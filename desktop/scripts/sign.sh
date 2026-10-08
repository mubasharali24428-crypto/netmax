#!/usr/bin/env bash
# sign.sh — Sign NetMaxDesktop universal app with Developer ID and hardened runtime
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$REPO_ROOT/desktop/build"
APP="$BUILD_DIR/NetMaxDesktop.app"
ENTITLEMENTS="$SCRIPT_DIR/entitlements.plist"

die() { printf 'sign.sh ERROR: %s\n' "$*" >&2; exit 1; }

[[ -d "$APP" ]] || die "$APP not found — build the app first with desktop/scripts/build_app.sh"
[[ -f "$ENTITLEMENTS" ]] || die "missing entitlements: $ENTITLEMENTS"
plutil -lint "$ENTITLEMENTS" >/dev/null || die "entitlements failed validation"

# Resolve signing identity: environment variable or first valid Developer ID in keychain
IDENTITY="${DEVELOPER_ID_APPLICATION:-${SIGN_IDENTITY:-}}"
if [[ -z "$IDENTITY" ]]; then
  DISCOVERED=$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -1 || true)
  if [[ -n "$DISCOVERED" ]]; then
    IDENTITY=$(printf '%s\n' "$DISCOVERED" | sed -E 's/^[[:space:]]*[0-9]+\) ([A-F0-9]+) "?(.*)"?$/\2/')
  fi
fi

if [[ -z "$IDENTITY" ]]; then
  die "no Developer ID Application identity found in keychain or environment (set DEVELOPER_ID_APPLICATION or SIGN_IDENTITY)"
fi

echo "Signing $APP with Developer ID (hardened runtime)..."
codesign --force --deep --options runtime --timestamp \
         --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"

echo "Verifying signature..."
codesign --verify --deep --strict "$APP" || die "codesign strict verification failed"

# Verify architecture preservation
lipo -info "$APP/Contents/MacOS/NetMaxDesktop" | grep -q 'arm64' || die "arm64 slice missing"
lipo -info "$APP/Contents/MacOS/NetMaxDesktop" | grep -q 'x86_64' || die "x86_64 slice missing"

echo "✅ App signed successfully with Developer ID"
