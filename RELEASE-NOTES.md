# Release Notes

## 1.0.7

**Engine / bridge**
- Auto-stop fix (user-reported): long runs no longer end early. `_pull` used to
  return on the first clean curl finish, so any run longer than one test file
  (OVH 100 MiB ≈ 26 s at 32 Mbps; CF 50 MB even shorter) auto-stopped before the
  requested duration. Pulls now run BACK-TO-BACK chunks until the window cap
  (curl exit 28), with a fresh cache-buster per chunk, and a mid-run endpoint
  blip (429/403/TLS reset) pauses and retries instead of aborting the run.
  Verified live: a 60-second baseline now runs 59.97 s and moves 384 MB
  (previously it ended at 26 s / 105 MB).
- New `limit` mode: hold a fixed download rate for the whole window
  (`netmax.py limit --mbps 2 --seconds 1800`). The cap is divided evenly across
  streams so the aggregate holds however many are open (curl `--limit-rate`,
  plain bytes/s — no 1024-suffix ambiguity). Honest verdicts: target held /
  short of the cap (line couldn't reach it) / cap overrun (burst pacing).
- Bridge: `limit` in MODE_FLAGS with `--mbps` (float, 0.5..10000, forwarded
  untruncated); watchdog already scales (2× window + margin) so 30-min holds
  are never killed mid-run.

**Swift**
- Mode Lab: new `limit` mode card with a Speed cap entry (SpeedCapEntryView,
  direct Mbps text field + clamping, mirroring the duration entry), wired
  through presets (`mbps` optional — legacy presets decode), last-state
  restore (`netmax.state.lastMbps`), and EngineParameterRanges.mbps (1…10000,
  mirroring bridge RANGE_BOUNDS).

**Tests**
- Engine: sustained-loop contract (chunk accumulation, per-chunk remaining-time
  cap, mid-run blip resilience, zero-byte windows raise), limit verdicts, CLI
  wiring/validation; bridge: mbps range boundaries, limit forwarding, scaled
  timeout.

## 1.0.7 (delta 2 — Dashboard Speed Limit + Quick Test lengths)

**Swift (Dashboard / MenuBarView)**
- Speed Limit gets its own highlighted home: a full-width RED RECTANGULAR bar
  (user-specified) between Target Speed and the speedometer. Tapping it opens
  the limit panel: any speed 0.5–10000 Mbps (decimals + comma accepted), the
  W15 duration entry (sec/min/hr), streams 1–50 (cap splits across them),
  Start/Stop, and the engine's verdict + stability report. Runs land in
  history (mode "limit") and feed cards/timeline like every other run.
  New file `SpeedLimitCard.swift` + offline `SpeedLimitCardTests` harness
  (parse/format validation), harness count 26 → 27.
- Quick Test length picker (user-requested): 5 / 10 / 15 min segmented control
  above Run Quick Test. boost = baseline + turbo legs, so the engine gets half
  the picked length per leg and the TOTAL matches the choice; result text
  states the leg split ("Quick Test — 10 min (boost, two 300s legs)").

**Engine (netmax.py)**
- Closed-loop LIMIT GOVERNOR (`_limit_governor`) replaces the single static
  --limit-rate hold: every 5 s the achieved rate is measured and the per-stream
  pace is re-aimed at the target (clamped ±1.5× per interval). Strength rules:
  first interval = warm-up (no correction — TCP ramp), starvation intervals
  (<25% of target) don't boost into a recovering line, ±3% deadband stops
  oscillation, dead intervals hold the pace (blips up to 5 minutes are ridden
  out — 60 consecutive dead intervals abort honestly), zero-byte windows raise.
  The report now ends with a stability line ("stability: 75% of 5s intervals
  within ±10% (min …, mean …, max …)"). Live: 2 Mbps × 30 s held at −2.3%.

**Tests**
- Governor suite: warm-up→convergence, clamp on collapse/overshoot, cap split
  across streams, mid-run blip survival, dead-streak abort, zero-byte raise,
  verdicts + stability line. Suite: 453 passing (+27 overall).

## 1.0.7 (delta 3 — tight band guarantee)

- USER: "the held speed must sit tightly around the limit — 2 Mbps must never
  look like 10 or 20." Root hole: a degraded stretch ratcheted the pace up
  ×1.5 per interval, so a suddenly recovering line briefly delivered
  multiples of the target.
- Fix: hard pace ceiling — the commanded cap can never exceed
  `LIMIT_PACE_CEILING` (1.5×) the target, applied unconditionally every
  interval. Worst case is one 5 s interval at 1.5× target while the
  controller re-aims; sustained overshoot above the band is structurally
  impossible. Down-correction re-aims to the target in a single interval.
- Report now ends with the guarantee: "band guard: the pace was hard-limited
  to 3 Mbps (1.5× your 2 target) for the entire run."
- Tests: pace-ceiling ratchet wall + degraded-then-recovered re-aim suite.
  455 passing. (Live re-verify was delayed — both speed CDNs were returning
  429 after the session's heavy testing; the engine honestly refuses to
  count rate-limit bodies as data.)

## 1.0.6

**Swift**
- H8 license: fresh gates no longer auto-stamp a trial; explicit `startTrial()` (one-shot), DEBUG-only env overrides, Settings License UI (Start trial / Activate / Deactivate).
- N9 support bundle: sanitized `SupportBundle.export()` (drops history/env/SSID, redacts secrets, truncates) from Settings.
- Carbon hotkey live: `GlobalHotkey.install()` registers ⌥⌘R → posts `.netmaxRerunLast` (real `RegisterEventHotKey`, not a no-op).
- Update check: `UpdateChecker` hits GitHub releases API; Settings "Check for Updates" reports real version / errors (replaces placeholder github.com/netmax URLs).
- Auto-triage: after degradation delivery, `AutoTriage` may re-run a short probe (30-min cap, DEBUG-only fire path); Settings toggle `notifications.autoTriage`.
- ISP evidence packet: `IspEvidencePacket.format/export` builds a shareable markdown report (plan vs actual + degradation timeline) from Reports.
- Task 4 SQLite primary: `HistoryStore` mirrors JSONL into `history.db` (flat `history` table); reads prefer SQLite with one-time JSONL seed; full rewrites keep both in sync. Per-store `.db` name derived from JSONL basename so isolated test stores never share a database.
- View decomposition (extract-only): `MetricsExtraction`, `MonthlySummary`, `HistoryStoreProviding` pulled out of Dashboard/Reports.

**Tooling**
- `desktop/scripts/sync_versions.sh`: apply / `--check` / version-arg; package.json → pyproject + cask + RELEASE-NOTES (sha256 intentionally untouched until DMG rebuild).

**Tests / audit**
- New harnesses: SupportBundle, UpdateChecker, AutoTriage, HistorySQLite, IspEvidence (26 total; shell + SPM green).
- AUDIT_REPORT: H8 → FIXED; GlobalHotkey → Live (⌥⌘R).

## Unreleased — M9 product surfaces + SPM test target (v1.0.6 prep)

**Swift (M9 wire)**
- `BloatStoryView` mounted in `RunDetailSheet` for `mode == "bloat"` records.
- `WifiDashboardSection` mounted under menu-bar metric cards; popover widened to 420pt (WifiPanel 360pt floor).
- `OnboardingScheduleHost` replaces bare `OnboardingView` in `RootView` (schedule opt-in once when unset).
- `ScheduleTabContent` hosts `ScheduleEditorView` + `BackgroundRunnerControlsView`.
- `ModeLabErrorView` replaces raw `Error: …` text via `lastErrorText` on the Mode Lab error branch.
- `WhatsNewSheet` presented from `MenuBarView` (landing surface) once per version.

**Swift (M9 hide)**
- Deleted `ReportsEmptyIntegration`; `HistoryEmptyIntegration` reduced to `Notification.Name` only.
- Removed unused `TabTransition`, `netMaxPressable`, `netMaxTransition`.
- Removed unmounted `NotificationPrefsView` Form struct (kept `NotificationPreferences` class + Settings sections).
- Feature discovery no longer claims disabled global ⌥⌘R; `GlobalHotkey.install` stays commented (documented).

**Tests / tooling**
- New SPM `netmax-desktopTests` target wrapping the 20 house `runAll()` harnesses (`swift test` green).
- Shell harness `run_swift_selftests.sh` still green (20/20).
- AUDIT_REPORT M9 → FIXED (deliberate); re-audit of touched files.

## Unreleased — deferred debt (L1/L3/M3/M6 + Python)

**Swift**
- L1: `EngineClient.stopCurrent` captures the PID while the handle is live and re-checks `isRunning` before SIGKILL (narrows the PID-recycle window).
- L3: Target Speed derives Mbps-per-stream from the last history run (fallback 6.0) instead of a fixed constant.
- M3: new `EngineParameterRanges` SSOT (mirrors `engine_bridge.py` RANGE_BOUNDS); Mode Lab / Target Speed / Duration Entry / AppPreferences all read from it.
- M6: quiet hours persisted under `netmax.notify.quiet*` with Settings steppers; `NotificationCoordinator` reads the shared prefs (default still 22:00–07:30).

**Python**
- `fetch --adaptive` is wired: one pre-download latency/loss probe via `AdaptiveController` (may step down from `--streams`; probe failure falls back to the requested count).
- `_truncate` honors a custom `budget` at every nesting depth (was ignored on recursive calls).
- `netmax_fetch` maps `http.client.IncompleteRead` / `OSError` mid-read failures onto `NetMaxError` (documented contract).

**Tests / docs**
- New `tests/test_audit_deferred_debt.py`; engine copies of `netmax.py` / `netmax_fetch.py` re-synced; AUDIT_REPORT Status updated (L1/L3/M3/M6 FIXED).

## Unreleased — audit MEDIUM + IMPROVEMENTS + post-HIGH scan (F1/F2)

**MEDIUM (Swift)**
- ScheduleRunner parses `--seconds` by flag scan, not `args[1]` positional.
- Settings History Retention scroll anchor no longer collides with Startup.
- Mode Lab Stop aborts multi-leg sequences between/inside legs.
- StatusBarController uses file-order `.last` (matches StatusPublisherHook).
- HistoryStore `deleteMany` single-read rewrite; mutators post `.netmaxHistoryDidChange`.
- Quiet-hours comment corrected (not user-tunable yet); LicenseGate documents all-or-nothing tiers.

**HIGH residuals (verified fixed)**
- TargetSpeedView re-enables its button via completion callback (H3).
- WifiEventEmitter: `nullDevice` pipes + `NSLock` around `inFlight` (H4/H5).
- Daily digest wired: `NotifyDigest.consider` from alerts, `flushIfDue` on schedule tick (H6).
- Interpreter help text and resolution all say `/usr/bin/python3`; dead `resolvedInterpreter` removed (H7).

**Python MEDIUM**
- Upload: per-endpoint `TimeoutExpired` failover across all verified endpoints.
- Fetch: oversize/symlink/incomplete output validation; bridge unknown-mode envelope.
- GUI: curl availability gated to `CURL_MODES`; watch-daemon lock TOCTOU fixed.
- Watch: interruptible sleep seam (`on_interrupt`) + daemon `_release_lock` in finally.

**Post-HIGH scan fixes**
- **F1** GUI `NetMaxRunner.start_command` reuses the parked worker thread instead of spawning a replacement every run (thread leak).
- **F2** `netmax_fetch` mbps counts only network bytes fetched this run — resumed on-disk bytes no longer inflate throughput.

**Tests / CI / docs**
- New `tests/test_audit_high_regressions.py`, `tests/test_netmax_watch_daemon.py`; F1/F2 regression tests.
- README/RELEASE-NOTES/PROJECT_LOG personal-path scrub; requirements-ci ranged pins; testpaths include bridge+store.

## Unreleased — audit CRITICAL+HIGH (commit 995063a)

Fixes already committed in the audit pass; summarized here for the changelog:

**CRITICAL**
- `measure.py` quarantines a corrupt `history.json` (atomic write, never wipes it).
- `netmax_fetch` discards single-chunk resume manifests; validates meta shapes.
- `netmax_upload` unlinks the payload only when create succeeded (no orphan `finally`).
- Swift `HistoryStore`/`RunPostProcessor` pair-scoped; notifications pref-gated.

**HIGH**
- ping/curl subprocess timeouts; `FileNotFoundError` → `NetMaxError`.
- wifievents rejects `-i 0`; watch sleep is interruptible (PEP 475).
- `split_chunks` clamps streams ≤ size (no zero-span chunks).
- GUI: queue marshalling, killpg stop, `WM_DELETE_WINDOW`, streams `1..50`.
- bridge: unlink stale `--json-out`, utf-8 decode, `encoding=`/`errors=replace`.
- store: `PRAGMA user_version` migration ladder stamped to `SCHEMA_VERSION`.
- CI: pip cache, `timeout-minutes`, ranged pins; testpaths include bridge+store.
- README test-count honesty; `.DS_Store`/egg-info/results.* untracked.

## v0.7.0-draft — 2026-09-08 (W18 verifier pass)

### Modes & Tuning
- **Max parallel streams raised 32 → 50** — engine (`netmax.py`), bridge
  range validation, Settings limits, and the Mode Lab stepper all aligned;
  51 now rejected with the honest `1..50` message at every layer.

### Security & Integrity
- **Engine integrity startup check** — if the bundled engine directory is
  group/world-writable, the app posts a security warning at launch
  (pre-notarization defense-in-depth; audit F2 follow-up).
- **CI hardening** — deep seal check (`codesign -v --deep --strict`), engine
  permission gate (bundle engine files must not be group/world-writable),
  engine_store suite in CI, honest test counts.
- **Threat model published** — `docs/THREAT-MODEL.md` documents assets,
  adversaries, trust boundaries, and re-audit triggers.

### Data & Storage
- **SQLite adoption path (F20)** — `desktop/scripts/migrate_to_sqlite.py`
  imports history.jsonl into history.db (idempotent, 0600). JSONL remains
  the primary store; the DB is the opt-in analytical layer.

### Fixes
- Settings "engine test count" honesty: 157 → 192 (stale since the audit).
- App startup now runs the EngineIntegrityCheckTests harness in DEBUG builds.

## v0.6.0-draft — 2026-08-24

### What's New

**Automation**
- New Schedule tab: automatic tests on an hourly / every-few-hours / daily
  schedule, backed by a real macOS launchd runner with start/stop controls and
  live state. Scheduled runs land in history tagged as scheduled and skip when
  offline.
- Degradation notifications: local alerts when scheduled runs fall
  significantly below your recent norm across consecutive runs, with one-tap
  access to the report, configurable thresholds, and a minimum gap between
  alerts so nothing spams you.
- Background test pipeline hardened (endpoints health module, retry helper,
  retention tooling).

**Bufferbloat storytelling cards**
- The bloat grade now explains itself: activity cards tie your measured
  latency-under-load to video calls, gaming, and streaming, with one
  actionable suggestion. No invented fixes; if the remedy is outside the app,
  it says so.

**History anomaly flags**
- The anomaly engine reads your own history and annotates statistically
  notable shifts (speed, loss, jitter) directly on the trend timeline, with
  plain-language confidence wording ("unusual," not "broken") and a threshold
  floor that keeps quiet noise silent.

**Quality timeline**
- New Timeline view inside History: throughput, loss, and jitter as stacked
  lanes over 1h / 24h / 7d, with local WiFi-event markers (roams, signal
  drops, channel changes) captured via system polling. Hovering a marker
  compares the samples before and after it — when one lands within ±90s the
  wording is *suggests*, never *caused*, and unmatched events say so plainly.

**ISP report-card PDF**
- Reports can now export the single-page ISP report card as a PDF: advertised
  plan tier vs measured delivery, letter grades including bufferbloat, honest-
  limits footer, generated locally with a share-sheet handoff.

**Distribution pipeline**
- `build_dmg.sh` produces a distributable DMG (drag-to-install layout,
  Developer ID signature auto-detected when present, ad-hoc otherwise).
- `notarize.sh` implements the full hardened-runtime → notarytool → stapler →
  spctl pipeline. Until a paid Apple Developer account exists it exits 2 with
  the exact setup checklist — that gate is deliberate.

### Known Limitations

- **Ad-hoc signing only.** There is no paid Apple Developer account on the
  build machine, so every shipped bundle carries an ad-hoc signature. That
  proves the bundle is unmodified since signing — not who made it — and
  nothing is notarized yet. Recipients of shared DMGs will hit Gatekeeper
  (right-click → Open, or Privacy & Security → Open Anyway on Sequoia+).
  The permanent fix is the Tier-3 checklist in `desktop/README.md`.
- **`notarize.sh` gates by design.** It exits 2 with setup instructions until
  a Developer ID certificate and stored notarytool credentials exist. This is
  documented behavior, not an error.
- NetMax still cannot exceed your ISP cap; turbo/boost gains appear only under
  contention. Unchanged, and unchanged on purpose.

### Upgrade notes

- Measurement history moves from `history.jsonl` to a SQLite store. Migration
  from existing JSONL history is automatic and idempotent at import time —
  already-imported entries are skipped, corrupt lines are counted rather than
  fatal. Keep your old `history.jsonl` until you've confirmed your history
  looks complete after first launch.
- If you previously set `NETMAX_PYTHON`, it continues to work in Settings and
  for all scripts; nothing to change there.
- Menu-bar shortcuts are now ⌘1–⌘6 for tabs and ⌘R for a quick run.
