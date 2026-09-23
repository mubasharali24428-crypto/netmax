#!/usr/bin/env bash
# build_app.sh — assemble NetMaxDesktop.app (P0-B4)
#
# Steps:
#   1. swift build -c release (desktop/SwiftNetMax)
#   2. Assemble desktop/build/NetMaxDesktop.app/Contents/{MacOS,Resources}
#      - release binary netmax-desktop -> MacOS/NetMaxDesktop
#      - desktop/bridge/engine_bridge.py + repo-root netmax*.py netmetrics.py
#        -> Resources/engine/
#   3. Info.plist (com.netmax.desktop, LSUIElement, min macOS 13.0)
#   4. Ad-hoc codesign (-s -): NO signing identities exist on this machine;
#      notarization is impossible without a paid Apple Developer account.
#      See ../README.md — we document this honestly, we do not fake it.
#   5. Print bundle path + sizes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SWIFT_DIR="$REPO_ROOT/desktop/SwiftNetMax"
BRIDGE_DIR="$REPO_ROOT/desktop/bridge"
BUILD_DIR="$REPO_ROOT/desktop/build"
APP="$BUILD_DIR/NetMaxDesktop.app"

log() { printf '[build_app] %s\n' "$*"; }
die() { printf '[build_app] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "$SWIFT_DIR/Package.swift" ]] || die "missing $SWIFT_DIR/Package.swift (B1 has not landed?)"
[[ -d "$BRIDGE_DIR" ]] || die "missing $BRIDGE_DIR (B2 has not landed?)"

# P2.5 (Strategic Revenue Plan): 1.0 signals a product a buyer can trust.
APP_VERSION="$(python3 -c "import json;print(json.load(open('$REPO_ROOT/desktop/package.json'))['version'])")"
APP_BUILD="$(date -u '+%Y%m%d')"
log "version: $APP_VERSION (build $APP_BUILD)"

# --- 1. Build the Swift shell ---------------------------------------------
# P2.2 (Strategic Revenue Plan): UNIVERSAL build (arm64 + x86_64).
# SwiftPM's multi-arch products land in .build/apple/Products/Release/ (the
# single-arch location .build/release/ is kept as a fallback for older toolchains).
log "swift build -c release --arch arm64 --arch x86_64 (universal) in $SWIFT_DIR"
( cd "$SWIFT_DIR" && swift build -c release --arch arm64 --arch x86_64 )

BIN="$SWIFT_DIR/.build/apple/Products/Release/netmax-desktop"
if [[ ! -x "$BIN" ]]; then
  log "universal product not found at .build/apple/Products/Release/ — falling back to .build/release/"
  BIN="$SWIFT_DIR/.build/release/netmax-desktop"
fi
if [[ ! -x "$BIN" ]]; then
  log "expected binary not found: $BIN"
  log "available release products:"
  ls -1 "$SWIFT_DIR/.build/apple/Products/Release" "$SWIFT_DIR/.build/release" 2>/dev/null | sed 's/^/    /' >&2 || true
  die "release binary netmax-desktop not found (check Package.swift product/executable name)"
fi
log "binary architectures: $(lipo -info "$BIN" 2>/dev/null | sed 's/^[^:]*://')"
if lipo -info "$BIN" 2>/dev/null | grep -q 'Non-fat'; then
  log "WARN: binary is NOT universal (single arch) — Intel Macs will not run this build"
fi

# --- 2. Assemble bundle skeleton ------------------------------------------
log "assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine"
cp "$BIN" "$APP/Contents/MacOS/NetMaxDesktop"
chmod 755 "$APP/Contents/MacOS/NetMaxDesktop"

# Bridge + engine modules -> Resources/engine/
cp "$BRIDGE_DIR/engine_bridge.py" "$APP/Contents/Resources/engine/engine_bridge.py"
shopt -s nullglob
engine_modules=( "$REPO_ROOT"/netmax*.py )
shopt -u nullglob
[[ ${#engine_modules[@]} -gt 0 ]] || die "no netmax*.py modules found at repo root"
[[ -f "$REPO_ROOT/netmetrics.py" ]] || die "netmetrics.py not found at repo root"
for f in "${engine_modules[@]}" "$REPO_ROOT/netmetrics.py"; do
  cp "$f" "$APP/Contents/Resources/engine/"
done
log "copied ${#engine_modules[@]} netmax*.py module(s) + netmetrics.py + engine_bridge.py -> Resources/engine/"

# Seal hygiene (found live 2026-09-08): a child run against the bundled
# engine once left a __pycache__/*.pyc inside Resources — codesign -v then
# fails with "sealed resource added" and the DMG ships broken. Strip any
# bytecode/finder artifacts before signing, and never copy them in.
find "$APP/Contents/Resources" -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$APP/Contents/Resources" -name "*.pyc" -delete 2>/dev/null || true

# --- 3. Info.plist ---------------------------------------------------------
# W12 T1-e: NetMaxBuildDate is stamped here so Settings → About can show the
# honest build date next to "Check for Updates…".
BUILD_DATE="$(date -u '+%Y-%m-%d %H:%M UTC')"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.netmax.desktop</string>
	<key>CFBundleName</key>
	<string>NetMaxDesktop</string>
	<key>CFBundleDisplayName</key>
	<string>NetMax Desktop</string>
	<key>CFBundleExecutable</key>
	<string>NetMaxDesktop</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleShortVersionString</key>
	<string>${APP_VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${APP_BUILD}</string>
	<key>NetMaxBuildDate</key>
	<string>${BUILD_DATE}</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null || die "generated Info.plist failed plutil -lint"

# --- 4. Ad-hoc sign (deep) -------------------------------------------------
log "codesign -s - --force --deep (AD-HOC: no Apple signing identities on this machine)"
codesign -s - --force --deep "$APP"

# Seal GATE (added 2026-09-08): a bundle whose seal does not verify must
# never ship or be reported as DONE. This catches any file that appears
# between the copy step and the signature — pycache, .DS_Store, anything.
if ! codesign -v --deep "$APP" 2>&1; then
  die "SEAL BROKEN after signing — see codesign output above; rebuild needed"
fi
log "seal verification: OK"

# --- 5. Report --------------------------------------------------------------
log "codesign verification:"
codesign -dv "$APP" 2>&1 | sed 's/^/    /'
log "bundle: $APP"
du -sh "$APP" | awk '{print "[build_app]     total size: " $1}'
ls -lh "$APP/Contents/MacOS/NetMaxDesktop" | awk '{print "[build_app]     binary:      " $5 "  MacOS/NetMaxDesktop"}'
printf '[build_app]     resources:   %s file(s)\n' "$(find "$APP/Contents/Resources" -type f | wc -l | tr -d ' ')"
log "DONE"
