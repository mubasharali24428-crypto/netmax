# NetMax — MCP Server & macOS Desktop App

Two surfaces, one engine:

- **`@netmax/mcp-server`** — a free MCP (Model Context Protocol) server exposing **14
  network-diagnostic tools** to any AI coding harness. This is what the npm package ships.
- **NetMaxDesktop** — a double-clickable macOS **menu-bar app** wrapping the same engine
  (documented lower in this file).

## MCP Server — 14 network-diagnostic tools for AI coding agents

Wire NetMax into any MCP-compatible harness as a **free** stdio server. Runtime needs
Node ≥ 18 **plus** Python 3.10+ and `curl` (the server shells out to the bundled NetMax
engine — nothing is installed system-wide).

**Install matrix**

| Harness | One-liner / config |
|---|---|
| **Any npx-compatible harness** | `npx -y @netmax/mcp-server` |
| **Claude Code** | `claude mcp add netmax -- npx -y @netmax/mcp-server` |
| **Codex CLI** | `~/.codex/config.toml` → `[mcp_servers.netmax]` with `command = "npx"`, `args = ["-y", "@netmax/mcp-server"]` |
| **Cursor** | `~/.cursor/mcp.json` → add `netmax` to `mcpServers` |
| **Gemini / Antigravity** | `~/.gemini/config/mcp_config.json` → add `netmax` to `mcpServers` |
| **LM Studio** | `~/.lmstudio/mcp.json` → add `netmax` to `mcpServers` |
| **Claude Desktop** | `claude_desktop_config.json` → add `netmax` to `mcpServers` |
| **DSH (DeepSeek)** | `cordis.patch.yml` → insert `mcp-netmax` client plugin |
| **VS Code (Continue.dev)** | `~/.continue/config.json` → add `netmax` to `mcpServers` |

Tools: `measure_speed`, `dns_ranking`, `bufferbloat`, `upload_speed`, `packet_loss`,
`jitter`, `wifi_info`, `download_file`, `eco_bloat`, `full_diagnostics`,
`diagnostic_summary`, `boost`, `parallel_diagnostics`, `session_info`. Full detail:
[`MCP-README.md`](./MCP-README.md).

Run standalone: `node netmax-mcp-server.mjs`

---

## NetMaxDesktop (macOS menu-bar app)

A double-clickable macOS **menu-bar app** wrapping today's NetMax engine:
Swift shell (`SwiftNetMax/`) → Python bridge (`bridge/engine_bridge.py`) → engine modules (`netmax*.py`, `netmetrics.py`).

Status: **Phase 0** — signed shell + honest-limits onboarding. Ad-hoc signed only; distribution story below ([Distribution](#distribution)).

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
    build_dmg.sh                # packages the .app into a distributable DMG (T3-b)
    notarize.sh                 # hardened-runtime re-sign + Apple notarization pipeline (T3-a)
    entitlements.plist          # minimal hardened-runtime entitlements (JIT off, nothing exotic)
    verify_phase0.sh            # Phase 0 merge gate (offline)
    verify_phase1.sh            # Phase 1 merge gate (offline)
  build/                        # OUTPUT ONLY (gitignored): NetMaxDesktop.app + *.dmg live here
```

## Build & run

```bash
cd desktop/scripts
./build_app.sh          # swift build -c release + assemble + ad-hoc sign
open ../build/NetMaxDesktop.app   # menu-bar item appears (LSUIElement: no Dock icon)
```

Requirements: macOS ≥ 13.0, Xcode/Swift toolchain (`swift build`), Python 3.10+
(override with `NETMAX_PYTHON` — see [Python interpreter override](#python-interpreter-override-netmax_python)).

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
| b | full pytest suite → ≥150 passed, no failures/errors |
| c | `pytest desktop/bridge/test_engine_bridge.py` all pass |
| d | `engine_bridge.py selftest` exit 0 |
| e | `build_app.sh` ran → `.app/Contents/MacOS` exists |
| f | `codesign -v` valid on disk |
| g | `plutil -lint` OK and `LSUIElement == true` |

Any FAIL ⇒ nonzero exit. Run `./build_app.sh` first (steps e–g check its output).

## Python interpreter override (`NETMAX_PYTHON`)

All tooling defaults to the system `python3` but honors `NETMAX_PYTHON`:

- **Scripts** — `scripts/verify_phase0.sh` resolves
  `PY="${NETMAX_PYTHON:-python3}"`; `build_app.sh` invokes no
  Python directly.
- **App runtime** — the Swift shell (`EngineClient.swift`) also reads
  `NETMAX_PYTHON`, falling back to the system `python3`.
- **Usage:** `NETMAX_PYTHON=/path/to/python ./scripts/verify_phase0.sh`

## Distribution

The honest state of things first: **there is no paid Apple Developer account on
this machine** (measured: `security find-identity -v -p codesigning` → 0 valid
identities). Everything shipped today carries an **ad-hoc signature**
(`codesign -s -`). That signature proves the bundle hasn't been modified since
signing — it does **not** prove who made it, and nothing is notarized. We are
not faking or working around any of this. Three tiers, from "works now" to
"works for strangers":

### Tier 1 — Local use (works today, zero ceremony)

```bash
cd desktop/scripts
./build_app.sh && open ../build/NetMaxDesktop.app
```

An app built locally has no quarantine attribute, so it opens on a plain
double-click. Only if the `.app` reached you *through another channel*
(AirDrop, download) does Gatekeeper get involved — see Tier 2.

### Tier 2 — LAN / friend sharing (works today, with friction)

Build a DMG and hand it over:

```bash
cd desktop/scripts
./build_dmg.sh        # -> ../build/NetMaxDesktop-<version>.dmg
```

What the script does: stages the `.app` plus a drag-to-install symlink to
`/Applications`, optionally lays out the Finder window via AppleScript
(skipped gracefully when osascript automation isn't permitted — set
`NETMAX_DMG_NO_COSMETICS=1` to skip deliberately), compresses with
`hdiutil create -format UDZO`, then signs the DMG **with the Developer ID cert
if one exists, ad-hoc otherwise** — printing which one it used and why.

The recipient will hit Gatekeeper, because the DMG is not notarized. That is
expected, not a bug. Their options, least-invasive first:

1. **Right-click → Open** (or Control-click): the first block dialog offers no
   way through; right-clicking the app and choosing **Open** gives a second
   dialog with an **Open** button.
2. **macOS Sequoia and later:** the right-click path was removed for
   unknown devs. Use **System Settings → Privacy & Security**, scroll to the
   "NetMaxDesktop was blocked" notice → **Open Anyway** → authenticate.
3. **Nuclear-ish option** (only ever on apps you actually trust):
   copy the app out of the DMG, then clear the quarantine flag:
   ```bash
   xattr -dr com.apple.quarantine /Applications/NetMaxDesktop.app
   ```
   Quarantine is just a marker added on download; removing it skips the
   Gatekeeper prompt. Never run this on software whose origin you can't vouch for.

Tell recipients plainly: "this is an unsigned hobby build; macOS will warn you;
here is why that warning exists." Nobody should be told to disable Gatekeeper
system-wide — that trades one convenience for all future protection.

**The permanent fix is one command once the $99/yr account exists** — Tier 3
below is fully scripted: `notarize.sh` re-signs with hardened runtime, submits
to Apple, staples the ticket, and Gatekeeper-verifies; `build_dmg.sh` then
re-signs the DMG with the same Developer ID. The instructions above exist ONLY
until that account exists — after notarization they describe a state that no
longer occurs and should be deleted.

### Tier 3 — Full public distribution (needs the $99/yr account)

The complete checklist, mapped to the scripts that automate it:

1. **Enroll** in the [Apple Developer Program](https://developer.apple.com/programs/)
   ($99/year) and accept the latest license agreement in App Store Connect →
   Agreements, Tax, and Banking. Notarization fails cryptically until the
   agreement is accepted, even with a valid cert.
2. **Create a Developer ID Application certificate** (Xcode → Settings →
   Accounts → Manage Certificates → +). Confirm it landed *with its private key*:
   ```bash
   security find-identity -v -p codesigning   # must list "Developer ID Application: ..."
   ```
3. **Store notarytool credentials once** (App Store Connect API Team key):
   ```bash
   xcrun notarytool store-credentials NetMaxNotary \
       --key-id <KEY_ID> --issuer <ISSUER_ID> --key ~/Downloads/AuthKey_<KEY_ID>.p8
   ```
4. **Run the pipeline:**
   ```bash
   cd desktop/scripts
   ./notarize.sh      # hardened-runtime re-sign (--options runtime + entitlements.plist),
                      # zip, `xcrun notarytool submit --wait --keychain-profile NetMaxNotary`,
                      # `xcrun stapler staple`, spctl verify.
                      # Exits 2 with exact setup instructions until steps 1–3 are done —
                      # that gate is deliberate, not an error.
   ./build_dmg.sh     # re-run after notarizing: auto-detects the Developer ID identity,
                      # signs the DMG with it instead of ad-hoc.
   ```
5. **Verify like a user would:**
   ```bash
   spctl -a -vv -t exec ../build/NetMaxDesktop.app   # -> accepted
   codesign -v ../build/NetMaxDesktop-*.dmg          # silent = valid
   ```
6. **Upload** the DMG to the release site. Downloaded copies open with a normal
   double-click: Gatekeeper validates the stapled ticket offline (or Apple's
   servers online) and never shows the unidentified-developer wall.

Until steps 1–3 happen, `./notarize.sh` exits 2 saying exactly that. This is
the deliverable in its current state — the pipeline is real, the gate is real,
and neither pretends otherwise.

### Troubleshooting: Gatekeeper errors and fixes

| Symptom | Why it happens | Fix |
|---|---|---|
| "can't be opened because the developer cannot be verified" | Ad-hoc/un-notarized app that arrived via download/AirDrop (quarantined) | Expected pre-Tier-3. Recipient: right-click → Open; on Sequoia+: Privacy & Security → Open Anyway. Permanent fix: Tier 3. |
| "Apple could not verify 'NetMaxDesktop' is free of malware" (Sequoia wording) | Same situation, newer Gatekeeper phrasing; right-click Open no longer offered | System Settings → Privacy & Security → scroll to the block notice → Open Anyway → authenticate. |
| "app is damaged and can't be opened. Move it to the Trash" | Broken transfer (partial download) or the signature doesn't match the quarantined bundle | Re-download the DMG and re-copy. If it persists on our pre-Tier-3 builds: copy the `.app` out of the DMG, then `xattr -dr com.apple.quarantine <path>` (trusted sources only). |
| Double-clicked the DMG, dragged the app, launched — "nothing happened" | It's an `LSUIElement` menu-bar app: no Dock icon, no main window by design | Look for the NetMax item in the top-right menu bar and click it. Confirm it's running: `pgrep -fl NetMaxDesktop`. |
| `./notarize.sh` exits 2 immediately | No Developer ID identity on the machine — the documented gate | Follow the printed checklist (account → agreement → cert → `store-credentials`), then re-run. Expected until the paid account exists. |
| Notarization submit fails or hangs at "in progress" | License agreement not accepted; wrong keychain profile; Apple backlog | Check profile name matches `store-credentials`; fetch details: `xcrun notarytool log <submission-id> --keychain-profile NetMaxNotary`. |
| `spctl` still says rejected after notarizing | Ticket not stapled or staple went stale after re-signing | Re-run `./notarize.sh` end-to-end (it staples after every re-sign); diagnose with `xcrun stapler validate <app>`. |

### Script reference (distribution)

| Script | Without paid account | With paid account |
|---|---|---|
| `build_app.sh` | builds + ad-hoc signs the `.app` | same (notarize.sh re-signs later) |
| `build_dmg.sh` | full DMG, ad-hoc-signed, clearly labeled | full DMG, Developer ID-signed (auto-detected) |
| `notarize.sh` | prints setup checklist, **exit 2** (the gate) | hardened-runtime sign → notarytool submit → staple → spctl green |

