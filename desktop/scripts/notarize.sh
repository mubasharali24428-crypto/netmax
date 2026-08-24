#!/usr/bin/env bash
# notarize.sh — Developer ID rebuild + notarization pipeline (W4 TEAM-3 N1 / T3-a).
#
# What this does when a "Developer ID Application" identity EXISTS:
#   1. Rebuild the .app with hardened runtime (--options runtime --entitlements)
#      + trusted timestamp (required for notarization).
#   2. Zip it (notarytool takes files, not bundles).
#   3. xcrun notarytool submit --wait --keychain-profile "$NOTARY_PROFILE".
#   4. xcrun stapler staple the ticket onto the bundle.
#   5. Verify like a user's Gatekeeper would: spctl -a -vv -t exec.
#
# What this does on THIS machine today (measured):
#   security find-identity finds NO valid codesigning identities — there is no
#   paid Apple Developer Program account yet. In that case this script prints
#   exactly what to buy/create/import, then exits 2 with:
#     "NOTARIZATION BLOCKED: no Apple Developer identity — this is expected until the paid account exists"
#   That gate IS the deliverable for now. We never fake signing or notarization.
#
# Usage:
#   ./notarize.sh                          # auto-detect app in desktop/build/
#   NOTARY_PROFILE=NetMaxNotary ./notarize.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$REPO_ROOT/desktop/build"
APP="$BUILD_DIR/NetMaxDesktop.app"
ENTITLEMENTS="$SCRIPT_DIR/entitlements.plist"

# Keychain profile holding App Store Connect API credentials, created once via:
#   xcrun notarytool store-credentials "$PROFILE" \
#     --key-id <KEYID> --issuer <ISSUER_ID> --key AuthKey_<KEYID>.p8
NOTARY_PROFILE="${NOTARY_PROFILE:-NetMaxNotary}"

log() { printf '[notarize] %s\n' "$*"; }
die() { printf '[notarize] ERROR: %s\n' "$*" >&2; exit 1; }

blocked() { # print exact setup instructions, exit 2 — expected without a paid account
  cat >&2 <<'EOF'
[notarize] NOTARIZATION BLOCKED: no Apple Developer identity — this is expected until the paid account exists

What to do, in order (all of it requires money or patience, none of it is optional):

1. BUY the account
   - Enroll in the Apple Developer Program: https://developer.apple.com/programs/
   - Cost: USD $99/year, per person or organization. Personal vs organization
     matters: an org enrollment signs as the legal entity name.
   - Approval can take 24-48h (orgs: longer — they may call your D-U-N-S number).

2. ACCEPT THE AGREEMENT
   - Sign in at https://appstoreconnect.apple.com/ -> Agreements, Tax, and Banking.
   - Accept the latest Apple Developer Program License Agreement. Notarization
     fails with a cryptic error until this is done, even with a valid cert.

3. CREATE THE CERTIFICATE (Developer ID Application — NOT "Apple Development")
   - Easiest: Xcode -> Settings -> Accounts -> select account -> Manage Certificates...
     -> "+" -> "Developer ID Application".
   - Manual path: create a CertificateSigningRequest.certSigningRequest in
     Keychain Access (Keychain Access -> Certificate Assistant -> Request a
     Certificate From a Certificate Authority), upload it at
     https://developer.apple.com/account/resources/certificates/add,
     choose "Developer ID Application", download the .cer, double-click it.
   - The private key MUST end up in your login keychain — that is what makes
     `security find-identity` below succeed. Without the private key the cert
     is decorative.

4. VERIFY IT LANDED
   - security find-identity -v -p codesigning
   - You want one line like:
       1 valid identities found
         1) XXXXXXXXXXXX... "Developer ID Application: Your Name (TEAMID)"

5. CREATE NOTARYTOOL CREDENTIALS (one-time)
   - App Store Connect -> Users and Access -> Integrators -> Generate API key
     (Team key). Note the Key ID and download the .p8; note the Issuer ID.
   - Store them in your keychain once:
       xcrun notarytool store-credentials NetMaxNotary \
         --key-id <KEY_ID> --issuer <ISSUER_ID> --key ~/Downloads/AuthKey_<KEY_ID>.p8
   - Then re-run this script (it uses --keychain-profile NetMaxNotary).

Re-run this script after step 5 and it will rebuild with hardened runtime,
submit to Apple, staple the ticket, and spctl-verify the result.
EOF
  exit 2
}

# --- Gate: is there a Developer ID Application identity? --------------------
log "checking for 'Developer ID Application' codesigning identity..."
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' || true)"
if [[ -z "$IDENTITIES" ]]; then
  log "none found. Full identity check output:"
  security find-identity -v -p codesigning 2>/dev/null | sed 's/^/[notarize]     /' || \
    printf '[notarize]     (security find-identity produced no list)\n'
  blocked   # exits 2
fi
IDENTITY="$(printf '%s\n' "$IDENTITIES" | head -1 | sed -E 's/^[[:space:]]*[0-9]+\) ([A-F0-9]+) "?(.*)"?$/\2/')"
log "using identity: $IDENTITY"

# --- Preconditions ----------------------------------------------------------
[[ -d "$APP" ]] || die "$APP not found — run desktop/scripts/build_app.sh first"
[[ -f "$ENTITLEMENTS" ]] || die "missing entitlements file: $ENTITLEMENTS"
plutil -lint "$ENTITLEMENTS" >/dev/null || die "entitlements failed plutil -lint: $ENTITLEMENTS"
command -v xcrun >/dev/null || die "xcrun not found (install Xcode command line tools)"

# --- 1. Re-sign WITH hardened runtime ---------------------------------------
log "codesign --force --deep --options runtime --timestamp --entitlements ..."
codesign --force --deep --options runtime --timestamp \
         --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"

log "verifying hardened-runtime signature:"
codesign -vv --deep "$APP" | sed 's/^/[notarize]     /'
codesign -dv "$APP" 2>&1 | grep -E 'Runtime|Authority' | sed 's/^/[notarize]     /' || true

# --- 2. Zip for submission ---------------------------------------------------
ZIP="$BUILD_DIR/NetMaxDesktop-notarize.zip"
log "zipping $APP -> $ZIP (ditto preserves the bundle structure notarytool wants)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
ls -lh "$ZIP" | awk '{print "[notarize]     zip size: " $5}'

# --- 3. Submit & wait --------------------------------------------------------
log "xcrun notarytool submit --wait --keychain-profile \"$NOTARY_PROFILE\""
if ! xcrun notarytool submit "$ZIP" --wait --keychain-profile "$NOTARY_PROFILE"; then
  die "notarytool submit failed. Fetch the detailed log with:
     xcrun notarytool log <submission-id> --keychain-profile \"$NOTARY_PROFILE\"
     (the id is printed above). Common causes: license agreement not accepted,
     wrong keychain profile, or hardened-runtime violations listed in the log."
fi
log "Apple status: Accepted."

# --- 4. Staple ---------------------------------------------------------------
log "xcrun stapler staple $APP"
xcrun stapler staple "$APP" || die "stapler failed — run 'xcrun stapler validate $APP' for details"
xcrun stapler validate "$APP" | sed 's/^/[notarize]     /'

# --- 5. Verify like Gatekeeper would -----------------------------------------
log "spctl assessment:"
spctl -a -vv -t exec "$APP" | sed 's/^/[notarize]     /'

rm -f "$ZIP"
log "DONE — $APP is signed, notarized, and stapled."
