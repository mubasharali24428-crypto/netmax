# NetMax Desktop (Phase 0)

A double-clickable macOS **menu-bar app** wrapping today's NetMax engine:
Swift shell (`SwiftNetMax/`) → Python bridge (`bridge/engine_bridge.py`) → engine modules (`netmax*.py`, `netmetrics.py`).

Status: **Phase 0** — signed shell + honest-limits onboarding. Ad-hoc signed only (see [Signing](#signing-ad-hoc-only-the-honest-limitation)).

## Layout

```
desktop/
  SwiftNetMax/                  # Swift Package: menu-bar shell (B1/B3)
    Sources/netmax-desktop/     # App.swift, MenuBarView.swift, EngineClient.swift, Onboarding*.swift
  bridge/
    engine_bridge.py            # subprocess bridge (contract C1)
    test_engine_bridge.py       # offline bridge tests
  scripts/
    build_app.sh                # builds + assembles .app bundle
    verify_phase0.sh            # Phase 0 merge gate (offline)
  build/                        # OUTPUT ONLY (gitignored): NetMaxDesktop.app lives here
```

## Build & run

```bash
cd desktop/scripts
./build_app.sh          # swift build -c release + assemble + ad-hoc sign
open ../../build/NetMaxDesktop.app   # menu-bar item appears (LSUIElement: no Dock icon)
```

Requirements: macOS ≥ 13.0, Xcode/Swift toolchain (`swift build`), Python 3.13 at `/Users/user/1/bin/python`
(override with `NETMAX_PYTHON`).

The app runs as a menu-bar extra (`LSUIElement true`) — no Dock icon, no main window.

## Verify (merge gate)

```bash
cd desktop/scripts
./verify_phase0.sh      # exit 0 = Phase 0 gate green
```

Gate steps (all offline):

| Step | Check |
|---|---|
| deps | B1–B3 dependency files exist (poll-waits ≤ 15 min for concurrent lanes) |
| a | `swift build -c release` green |
| b | full pytest suite → `157 passed` |
| c | `pytest desktop/bridge/test_engine_bridge.py` all pass |
| d | `engine_bridge.py selftest` exit 0 |
| e | `build_app.sh` ran → `.app/Contents/MacOS` exists |
| f | `codesign -v` valid on disk |
| g | `plutil -lint` OK and `LSUIElement == true` |

Any FAIL ⇒ nonzero exit. Run `./build_app.sh` first (steps e–g check its output).

## Signing: AD-HOC ONLY — the honest limitation

This project is signed with an **ad-hoc signature**:

```bash
codesign -s - --force --deep desktop/build/NetMaxDesktop.app
```

What that means, plainly:

- `-s -` signs **without any identity**. There are **no Apple Developer signing identities on this machine** (measured), so this is the only option available.
- The signature proves the bundle hasn't been modified since signing. It does **not** prove who made it.
- The app is **not notarized**. Gatekeeper will block it for other users ("cannot be opened because the developer cannot be verified"). Right now the practical distribution story is: build it yourself, then right-click → Open, or clear quarantine with `xattr -dr com.apple.quarantine`.
- We are **not faking or working around** any of this.

### Next-step checklist for real signing/notarization

Requires a **paid Apple Developer Program account** ($99/yr). Then:

- [ ] Enroll in Apple Developer Program; accept the latest agreement in App Store Connect.
- [ ] In Xcode: download/create a **Developer ID Application** certificate (`Xcode → Settings → Accounts → Manage Certificates`). Confirm with `security find-identity -v -p codesigning`.
- [ ] Replace the ad-hoc line in `scripts/build_app.sh` with:
      `codesign --force --deep --options runtime --timestamp --sign "Developer ID Application: <Team Name> (<TEAMID>)" desktop/build/NetMaxDesktop.app`
      (the `--options runtime` hardening + trusted timestamp are required for notarization).
- [ ] Create an App Store Connect **API key** (Team Key, `.p8`) or use an app-specific password:
      `xcrun notarytool submit NetMaxDesktop.zip --key AuthKey_XXXX.p8 --key-id XXXX --issuer XXXX --wait`
      (zip first; `--apple-id/--team-id/--password` is the fallback auth path).
- [ ] On `Accepted`: staple the ticket so it travels with the app:
      `xcrun stapler staple desktop/build/NetMaxDesktop.app`
- [ ] Verify like a user would: `spctl -a -vv -t exec desktop/build/NetMaxDesktop.app` → `accepted`.
