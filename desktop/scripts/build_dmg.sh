#!/usr/bin/env bash
# build_dmg.sh — package desktop/build/NetMaxDesktop.app into a distributable DMG
#                (W4 TEAM-3 N1 / T3-b).
#
# Works fully WITHOUT a paid Apple Developer account:
#   - stages the .app plus a drag-to-install symlink to /Applications
#   - optional Finder cosmetics via AppleScript ONLY if osascript automation is
#     permitted (guarded; failure degrades gracefully, never fails the build)
#   - signs the DMG with the Developer ID identity when one exists, otherwise
#     AD-HOC (-s -) with a clear label about what that means for Gatekeeper
#
# Notarization-ready: once a Developer ID Application cert exists, run
# scripts/notarize.sh (it re-signs the APP with hardened runtime), then re-run
# this script so the DMG carries the Developer ID signature too.
#
# Usage:
#   ./build_dmg.sh                                   # -> desktop/build/NetMaxDesktop-<version>.dmg
#   DMG_OUT=/tmp/x.dmg ./build_dmg.sh                # custom output path
#   NETMAX_DMG_KEEP_STAGE=1 ./build_dmg.sh           # keep staging dir for debugging
#   NETMAX_DMG_NO_COSMETICS=1 ./build_dmg.sh         # skip the Finder/AppleScript step
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$REPO_ROOT/desktop/build"
APP="$BUILD_DIR/NetMaxDesktop.app"
STAGING="$BUILD_DIR/dmg-staging"

log() { printf '[build_dmg] %s\n' "$*"; }
warn() { printf '[build_dmg] WARN: %s\n' "$*" >&2; }
die() { printf '[build_dmg] ERROR: %s\n' "$*" >&2; exit 1; }

# --- Preconditions -----------------------------------------------------------
[[ -d "$APP" ]] || die "$APP not found — run desktop/scripts/build_app.sh first"
[[ -x "$APP/Contents/MacOS/NetMaxDesktop" ]] || die "$APP looks incomplete (no MacOS/NetMaxDesktop binary)"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "0.1.0")"
DMG_OUT="${DMG_OUT:-$BUILD_DIR/NetMaxDesktop-$VERSION.dmg}"
VOLNAME="NetMax Desktop"

# --- Signing identity: Developer ID if present, else ad-hoc -------------------
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -1 | sed -E 's/^[[:space:]]*[0-9]+\) ([A-F0-9]+) "?(.*)"?$/\2/' || true)"
if [[ -n "$DEV_ID" ]]; then
  SIGN_ID="$DEV_ID"; SIGN_MODE="Developer ID"
else
  SIGN_ID="-"; SIGN_MODE="AD-HOC"
fi

# --- 1. Stage -----------------------------------------------------------------
log "staging $APP (+ /Applications symlink) -> $STAGING"
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/NetMaxDesktop.app"
ln -s /Applications "$STAGING/Applications"

# --- 2. Optional Finder cosmetics (guarded AppleScript) -----------------------
# Sets icon positions + window size in the staged folder BEFORE hdiutil packs
# it, so the layout is baked into the DMG's .DS_Store. This needs Automation
# permission (osascript -> Finder); on a headless runner or a machine that has
# not granted it, this FAILS — that must be a graceful skip, not a build error.
if [[ "${NETMAX_DMG_NO_COSMETICS:-0}" != "1" ]] && command -v osascript >/dev/null 2>&1; then
  log "attempting Finder layout via AppleScript (NETMAX_DMG_NO_COSMETICS=1 to skip)"
  if osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Finder"
	tell disk "$(basename "$STAGING")"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {200, 120, 720, 440}
		set position of item "NetMaxDesktop.app" of container window to {140, 170}
		set position of item "Applications" of container window to {420, 170}
		close
	end tell
end tell
APPLESCRIPT
  then
    sync; sleep 1   # let Finder flush the .DS_Store before imaging
    log "Finder layout applied"
  else
    warn "AppleScript/Finder automation not permitted here (headless or Automation permission denied)."
    warn "Skipping cosmetic layout — the DMG is still correct, just with default icon placement."
  fi
else
  log "skipping Finder cosmetics (disabled or osascript unavailable)"
fi

# --- 3. Create the DMG ---------------------------------------------------------
log "hdiutil create -format UDZO -> $DMG_OUT"
mkdir -p "$BUILD_DIR"
rm -f "$DMG_OUT"
hdiutil create -volname "$VOLNAME" \
               -srcfolder "$STAGING" \
               -ov -format UDZO \
               "$DMG_OUT" | sed 's/^/[build_dmg]     /'
[[ -s "$DMG_OUT" ]] || die "hdiutil reported success but $DMG_OUT is missing/empty"

# --- 4. Sign the DMG ------------------------------------------------------------
if [[ "$SIGN_MODE" == "Developer ID" ]]; then
  log "codesign --sign \"$SIGN_ID\" --timestamp (Developer ID)"
  codesign --force --sign "$SIGN_ID" --timestamp "$DMG_OUT"
else
  log "codesign -s - (AD-HOC — no Developer ID identity on this machine)"
  log "  meaning, honestly: the DMG opens fine on THIS Mac; other Macs get a"
  log "  Gatekeeper block ('unidentified developer') because nothing notarized it."
  log "  The real fix is scripts/notarize.sh once a paid Apple Developer account exists."
  codesign -s - --force "$DMG_OUT"
fi
codesign -v "$DMG_OUT" && log "signature verifies on disk: $DMG_OUT"

# --- 5. Report -------------------------------------------------------------------
log "artifact:"
ls -lh "$DMG_OUT" | awk '{print "[build_dmg]     " $5 "\t" $9}'
hdiutil imageinfo "$DMG_OUT" | grep -E 'Format:|Format Description' | head -2 | sed 's/^/[build_dmg]     /'

if [[ "${NETMAX_DMG_KEEP_STAGE:-0}" == "1" ]]; then
  log "keeping staging dir for inspection: $STAGING"
else
  rm -rf "$STAGING"
fi
log "DONE ($SIGN_MODE-signed)"
