# NetMaxDesktop Threat Model

*Added W18 (2026-09-08) — audit P2 item 16. Living document; revisit when the
distribution model changes (esp. after notarization, F1).*

## 1. What we're defending

NetMax is a local-first network measurement tool for a single macOS user. The
assets in scope, in order of value:

1. **The user's measurement history** — timestamps, modes, grades, and
   (hashed) network identifiers in `~/Library/Application Support/NetMaxDesktop/`.
   Not secrets, but private: history reveals home/office patterns.
2. **The integrity of the machine** — the app re-executes bundled Python on a
   schedule; anything that can tamper with those files gains scheduled code
   execution as the user (audit F2, mitigated by the startup integrity check).
3. **The user's bandwidth and disk** — long runs, large upload payloads
   (capped, F9), and temp-file materialization (bounded).
4. **The user's trust** — the app's privacy claims must match its actual
   outbound traffic exactly (F16: every endpoint is now disclosed in Settings).

## 2. What we are NOT

- No server component. No accounts. No telemetry. No analytics.
- No inbound network surface: the app listens on nothing.
- Not a multi-user privilege boundary: everything runs as the logged-in user.
  There is no root, no daemon beyond a per-user LaunchAgent.

## 3. Adversaries

| # | Adversary | Capability | Primary target |
|---|---|---|---|
| A1 | Local process running as this user | Read/write user files, set env vars for children | history privacy (read), engine files (write→scheduled exec) |
| A2 | Malicious/compromised Python on PATH | Intercept engine execution | supply chain (F11/F12 — fixed: absolute /usr/bin/python3 default) |
| A3 | Network attacker (MITM of endpoints) | Observe/spoof speed-test traffic | measurement honesty (engine verifies TLS; no http:// downgrades) |
| A4 | Convincing user to run a bad copy of the app | Trojan distribution | full machine (F1: notarization is the fix; blocked on Apple account) |
| A5 | Another local user on a shared Mac | Read world-readable files in shared dirs; pre-place symlinks | history (F6: 0600 everywhere), fetch paths (F10: O_EXCL + shared-dir refusal) |

## 4. Trust boundaries

```
Swift shell (menu bar, UI)
  │  argv array, no shell strings; UUID temp envelopes; defer cleanup
  ├──────────────────────────▶ Python bridge (engine_bridge.py)
  │                            env scrubbed: PYTHONPATH=engine-dir-only,
  │                            PYTHONHOME/STARTUP dropped, NOUSERSITE=1
  │                            range validation BEFORE spawn
  ├──────────────────────────▶ Python engine (netmax.py <mode>)
  │                            curl/ping/socket probes to chosen endpoints
  │                            SSID/BSSID hashed (nm1:) at capture boundary
  └─────────── history.jsonl (0600) ◀── HistoryStore.swift (.atomic writes)
```

Boundaries crossed: (a) Swift→bridge via argv+temp file — content-validated
JSON envelopes; (b) bridge→engine via scrubbed env + bounded argv; (c)
engine→disk with 0600 permissions and atomic appends; (d) engine→network via
TLS-only curl to the endpoints disclosed in Settings.

## 5. Resolved risks (map to audit)

| Risk | Fix | Verification |
|---|---|---W16 verification: 192/192, live runs |
| F1 distribution tamper | notarize.sh pipeline ready; blocked on Apple Developer ID | spctl still rejects (expected) |
| F2 engine tamper→exec | startup EngineIntegrityCheck + CI engine-perm gate | 5 harness checks pass; CI gate added |
| F6/F7 privacy at rest | 0600 everywhere; salted SHA-256 of SSID/BSSID | on-disk scan: no raw identifiers |
| F8 env code-exec | PYTHONPATH scrub, isolated mode | bridge selftest 3/3 |
| F10 path attacks | O_EXCL part files, shared-dir refusal, basename sanitizer | 17/17 fetch tests |
| F11/F12 interpreter hijack | absolute /usr/bin/python3; no hardcoded personal paths | spawn traces |
| F13 dead settings | pythonOverride consumed | live trace via wrapper script |

## 5b. Post-F20 architecture (W18 decision)

JSONL stays the primary, always-on store. The SQLite layer (engine_store, 38
tests) is adopted as an **opt-in analytical store**: `desktop/scripts/
migrate_to_sqlite.py` imports history.jsonl into history.db (idempotent,
0600, per-(ts,mode) dedup). Nothing in the app reads the DB yet — the
migration tool is the adoption path, and the next release can surface
SQL-grade views (retention queries, trend analytics) on top of it.

## 6. Open risks (accepted or blocked)

| Risk | Status | Owner action |
|---|---|---|
| Ad-hoc signature (F1) | blocked on paid Apple Developer account | buy account → `desktop/scripts/notarize.sh` → done |
| engine_store unused by app | resolved W18: opt-in migration tool added | future: SQL views in Reports tab |
| LaunchAgent is user-editable (platform property) | accepted (per-user agents are inherently user-writable) | none — documented |

## 7. Assumptions

- macOS 13+ with system python3 at /usr/bin/python3 (verified on target machine).
- The user controls their PATH; dev overrides via NETMAX_PYTHON remain a feature.
- Speed-test endpoints (proof.ovh.net, speed.cloudflare.com, httpbin.org,
  postman-echo.com for upload) are honest — a hostile endpoint could feed
  false measurements, but cannot execute code or read local data.

## 8. Re-audit triggers

Re-run the full audit when any of these change:
- Distribution model (notarization enabled — revisit F2's necessity).
- A new outbound endpoint is added to netmax_endpoints.py.
- The engine gains file-write paths beyond results/ and temp envelopes.
- engine_store is promoted to the primary store (revisit retention/pruning).
