# License Gate — design & implementation (P2.9–P2.12)

**Status:** core landed 2026-09-11 · **Verified:** Phase 1 gate 6/6 PASS (step f = LicenseGate),
Python suite 192 passed, `swift build -c release` green.

## What exists now

| File | Role |
|---|---|
| `desktop/SwiftNetMax/Sources/netmax-desktop/LicenseGate.swift` | Tiering core: `Tier {Free, Trial, Pro}`, `Feature` list, trial math, activation, persistence |
| `desktop/SwiftNetMax/Sources/netmax-desktop/LicenseGateTests.swift` | 18 offline assertions (repo convention: plain enum, `runAll() -> Int`) |
| `desktop/scripts/verify_phase1.sh` step **f** | Executable probe: compiles all sources + runs `LicenseGateTests.runAll()`; gate fails if any check fails |

## Rules encoded

1. **FREE** keeps every current feature (on-demand tests, grade). **PRO** adds:
   watch/sentinel alerts, scheduled reports, PDF/ISP report card, exports, deep history.
2. **Trial = 14 days, full-featured**, stamped on first launch, then non-destructive lockout.
   User data is *never* deleted or held hostage (brand rule).
3. **Offline structural validation only** (LMS-style `XXXXX-XXXXX-...` 5×4 keys). No server
   round-trip; piracy is possible and **accepted** per project docs — we don't pretend otherwise.
4. **Dev/test override flags** (this is the feature flag the 192-test core runs under):
   - `NETMAX_LICENSE_DISABLED=1` → everything behaves as Pro
   - `NETMAX_LICENSE_MODE=pro|free|trial` → force a tier
5. **Zero date parsing**: trial bounds are stored as two fixed-width UTC ISO strings
   (`yyyy-MM-dd'T'HH:mm:ss'Z'`); "is trial active" is a lexicographic string compare. Testable by
   injecting bounds — no clock dependency in tests.
6. Persistence keys follow the `netmax.prefs.*` contract: `licenseKey`, `trialStartedAt`,
   `trialEndsAt`.

## Remaining work to finish P2.9–P2.12

1. **Wire the gate into call sites** (behind the flag): `ScheduleRunner` (ScheduledReports),
   `Notifications`/sentinel (WatchAlerts), `ReportsView` (PdfReportCard, Exports), history depth.
   Pattern at each site: `guard LicenseGate.shared.canUse(.X) else { show upsell }`.
2. **Settings UI**: "Enter license key" field → `LicenseGate.shared.activate(key)`, show tier,
   link to checkout. Restore/deactivate buttons.
3. **Lemon Squeezy integration**: buy URL on landing page → key issued by LMS webhook → user
   pastes key into Settings. (Optional later: online re-validation with LMS API.)
4. **Trial UX**: banner showing days remaining; expired state shows a respectful upsell, never a
   data hostage scene.

## Verification commands

```sh
NETMAX_PYTHON=.venv/bin/python desktop/scripts/verify_phase1.sh   # 6/6 PASS incl. step f
.venv/bin/python -m pytest -q                                      # 192 passed
```