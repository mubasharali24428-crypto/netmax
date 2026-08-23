# 05 — NetMax Product App: Architecture & UX Plan

**Sub-05 · Principal macOS Architect/UX Lead · NetMax v0.5 → distributable macOS product**

Current state: `netmax.py` (engine + CLI), satellite modules (`netmax_fetch`, `_eco`,
`_export`, `_throttle`, `_upload`, `_watch`, `netmetrics.py`), Tkinter wrapper
(`netmax_gui.py`) that runs each command in an isolated subprocess, matplotlib charts,
JSON/CSV export, ~201 offline tests. Target: a polished, distributable macOS product
app that keeps the "honest bandwidth maximizer" positioning front and center.

---

## 1. Stack Decision Matrix

| Criterion | (a) SwiftUI + bundled Python engine | (b) Full Swift rewrite | (c) Tauri/Electron + Python sidecar | (d) py2app/briefcase |
|---|---|---|---|---|
| Dev cost vs. existing tested engine | **Low–Med**: UI is new, engine reused verbatim | **High**: re-implement curl orchestration, bloat grading, DNS ranking; re-validate 201 tests' logic | **Med–High**: two toolchains, IPC bridge, webview build config | **Lowest**: ship what exists today |
| App Store feasibility | Feasible with care (see §2); helper must live *inside* the bundle | Best case | Tauri OK-ish; Electron historically accepted but heavyweight | Poor: Tkinter/PyObjC apps pass rarely; private-framework risk low but UX fails review polish bar |
| Memory / energy footprint | Good: native UI (~40–80 MB idle [LIKELY — typical SwiftUI utility ballpark, unmeasured]), engine wakes only during runs | Best (~30 MB [LIKELY]) | Worst (Electron: 200 MB+ baseline [LIKELY]; Tauri better but still webview) | Mediocre: full Python + Tk runtime always resident |
| Maintainability (team of Python devs + light Swift) | Clean seam: stable JSON-line contract between UI and engine | One language, but engine drift risk vs. CLI fork | Three moving parts: shell, bridge, engine | Single process; no isolation boundary; Tkinter ceiling |
| Menu-bar / notifications / Settings pane | First-class SwiftUI (`MenuBarExtra`, `UserNotifications`) | First-class | Plugin libraries of varying quality | None native |

**Recommendation: (a) SwiftUI menu-bar app calling the bundled Python engine via
subprocess**, structured exactly like today's `netmax_gui.py` runner (one engine at a
time, streamed output). Rationale:

1. The engine is the moat — measurement semantics (single-stream truth, N-stream
   fairness share, Waveform A+–F grading, dropout honesty) are battle-tested and
   covered by ~201 offline tests. Rewriting them (option b) buys nothing the user can
   see and risks silent behavioral regressions.
2. A menu-bar utility's UI surface is small enough that SwiftUI cost is bounded;
   we get native dark mode, VoiceOver, notifications, and Settings for free.
3. Electron/Tauri add a second runtime to distribute and secure for zero user value.
4. py2app ships the old UX; Tkinter cannot meet WCAG AA/VoiceOver goals realistically.
5. Escape hatch preserved: because the engine speaks a line-based JSON protocol over
   stdio, option (c) or even (b) remains reachable later without touching the engine.

Engine changes required (small): emit versioned NDJSON events (`{"v":1,"type":…}`),
add a `--json` flag alongside human output, and make every long-running mode
cancellation-aware (check stdin EOF / SIGTERM between samples).

## 2. Platform Constraints (verify tags)

- **[CONFIRMED] App Sandbox & helper processes.** Sandboxed apps may execute only
  binaries contained within their own application bundle; arbitrary child processes
  (e.g., system `curl`, `/usr/bin/python3`) are off-limits under sandbox. Therefore the
  App Store variant must vendor the engine as an XPC-style helper *inside* the .app,
  compiled/embedded CPython (or frozen via zipapp on the system framework Python).
  Implication: MAS build bundles its own interpreter; direct-distribution build may do
  the same so one artifact shape serves both. `com.apple.security.network.client`
  entitlement covers outbound probes; no server entitlement needed.
- **[CONFIRMED] Location permission for SSID/BSSID.** Since macOS 10.15 Catalina,
  `CNCopyCurrentNetworkInfo` returns SSID/BSSID only when the app holds Location
  Services authorization ("While Using" suffices). The app must request location,
  explain why (attaching WiFi context to measurements), and degrade gracefully:
  measurements proceed with SSID marked `<requires-location>`. This belongs in
  first-run copy and Settings, not buried in a dialog.
- **[UNCERTAIN] Local-network privacy prompt scope on recent macOS.** Post-Sonoma
  local-network access controls apply to some local traffic; whether our outbound-only
  public-endpoint probes ever trigger it is environment-dependent. Treat as "possible
  prompt; handle denial gracefully," verify empirically per OS release.
- **[CONFIRMED] Notarization/Gatekeeper for direct distribution.** Any build shipped
  outside the MAS must be signed with a Developer ID certificate and notarized
  (`notarytool` + `stapler`); first launch otherwise trips Gatekeeper on Apple Silicon
  where unsigned/arm64-universal binaries are refused outright. Ship universal2.
- **[CONFIRMED] Background monitoring energy expectations.** Long-running polling
  daemons draw App Review scrutiny. Use `NSBackgroundActivityScheduler`-style opportunistic
  wakeups for scheduled checks, coalesce with timer slack, pause live monitoring while
  the lid is closed/on battery if user opts in, and expose an explicit "Live Monitor is
  running" affordance. Target: near-zero CPU when idle; engine processes exist only
  during a run.
- **[UNCERTAIN] Exact future MAS guideline wording on "network testing" utilities**
  (e.g., any anti-"speed-test spam" rules). Mitigation: measurements are user-initiated
  by default; scheduled runs are opt-in with a sane minimum interval.

## 3. Data Architecture

SQLite at `~/Library/Application Support/NetMax/netmax.sqlite3` (WAL mode). Sketch:

```sql
CREATE TABLE runs (
  id INTEGER PRIMARY KEY,
  started_at TEXT NOT NULL,          -- ISO-8601 UTC
  finished_at TEXT,
  mode TEXT NOT NULL,                -- baseline|turbo|boost|dns|bloat|full|watch…
  engine_version TEXT NOT NULL,
  trigger TEXT NOT NULL DEFAULT 'manual',   -- manual|scheduled|menu-bar
  params_json TEXT NOT NULL          -- streams, seconds, resolver list
);
CREATE TABLE samples (
  id INTEGER PRIMARY KEY,
  run_id INTEGER NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL,
  t_offset_ms INTEGER NOT NULL,
  kind TEXT NOT NULL,                -- down|up|rssi|ping|dns_probe
  value REAL NOT NULL,
  unit TEXT NOT NULL                 -- mbps|dbm|ms
);
CREATE TABLE verdicts (
  run_id INTEGER PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE,
  grade TEXT,                        -- bufferbloat A+..F
  gain_pct REAL,                     -- boost verdict
  dropouts INTEGER,
  summary TEXT NOT NULL              -- honest-limit-aware sentence
);
CREATE TABLE wifi_context (
  run_id INTEGER PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE,
  ssid TEXT, bssid TEXT,             -- nullable when permission denied
  rssi_dbm INTEGER, channel TEXT, band TEXT, link_rate_mbps INTEGER
);
CREATE INDEX idx_runs_started ON runs(started_at DESC);
CREATE INDEX idx_samples_run ON samples(run_id, seq);
```

- **Migration:** one-time importer reads legacy `results.json` and rolling
  `history.json` (schema-discovered defensively; unknown fields land in
  `params_json`/a `legacy_raw` column), writes rows tagged `trigger='imported'`,
  then renames originals to `.imported.bak`. Idempotent by `(started_at, mode)` key.
- **Retention:** raw `samples` pruned after 90 days (user-adjustable); `runs` +
  `verdicts` retained indefinitely as compact aggregates; nightly `PRAGMA
  incremental_vacuum`; export-before-purge offered in Settings. Everything stays
  on-device unless the user exports.

## 4. Process Model

Reuse the proven pattern from `netmax_gui.py` (`NetMaxRunner`: one subprocess at a
time, `Popen` with piped stdio, callbacks per line):

- UI process (SwiftUI) never imports engine code. It spawns
  `NetMax.app/Contents/MacOS/netmax-engine --json <mode> …` and consumes NDJSON.
- **Streaming:** progress events update the Dashboard incrementally; a run is never
  "awaited blind."
- **Cancellation:** Cancel button sends SIGTERM; engine flushes partial results as a
  `cancelled` event; hard SIGKILL after 3 s grace. UI re-enables controls immediately.
- **Timeouts:** every mode declares a max wall time (e.g., `bloat` = seconds×4 + 20 s).
  Watchdog thread kills and surfaces "measurement hung — engine restarted."
- **Crash containment:** non-zero exit or malformed JSON ⇒ capture stderr tail into an
  error report view; the UI process is structurally incapable of being frozen by a hung
  probe because all reads happen on a dedicated queue with deadline timers — same
  guarantee the Tkinter app already provides, hardened.
- Concurrency cap: 1 engine run at a time (matches fairness philosophy); watch mode
  replaces this later with a dedicated long-lived worker owning its own schedule.

## 5. UX Blueprint

**First-run experience.** Before any measurement, a three-screen onboarding states the
honest limits verbatim from the README (can't exceed your ISP cap; gains appear only
under contention; router QoS overrides; dropouts are real), then asks: location
permission (with why), notifications opt-in. No dark patterns; the product's identity
is honesty.

**Main views** (menu-bar app with a compact main window):

1. **Dashboard** — last-run verdict card (grade, Mbps, gain %), "Run Full Test"
   primary action, inline progress, WiFi context strip. Empty state invites first run.
   On metered links (hotspot/capped plans) the dashboard defaults to the eco
   variants (~100 KB diagnostics) instead of full runs.
2. **Live Monitor** — real-time sparkline (down/up/ping), start/stop, clear energy
   disclosure ("keeps sampling every N s; pauses on battery saver"). Explicitly shows
   dropouts rather than smoothing them away.
3. **History/Trends** — matplotlib-quality native charts (Swift Charts): throughput
   over time, bufferbloat grade history, per-SSID breakdown; filters by mode/date.
4. **Reports** — generate/export PDF or CSV summaries (reuses `netmax_export`
   semantics), share sheet, "copy verdict text" for support tickets.
5. **Settings** — defaults (seconds, stream count), scheduled checks (interval floor,
   energy note; schedule persists across relaunch via `SMAppService`/launchd agent),
   data retention, telemetry toggle (off by default), re-explain limits, license &
   trial state (N10: local key validation, offline grace period; free tier stays a
   fully functional measurer forever), metered-link preference.

**Notifications.** Only meaningful events: completed scheduled run with grade change,
dropout burst detected, new best/worst record. Quiet hours respected; everything
configurable; nothing marketing.

**Accessibility.** WCAG AA contrast in both appearances (verify chart palettes with
contrast tooling; don't encode grades by color alone — pair with letter/symbol).
Every control has an accessibility label and hint ("Run Full Test — measures
download, parallel streams, DNS latency, and bufferbloat"); charts expose
audio-graph/summary text; full keyboard nav with logical tab order and visible focus
ring; Dynamic Type respected in all text.

**Dark/light.** System-appearance-driven via semantic colors; charts use
appearance-reactive palettes; no hardcoded hexes; window chrome standard.

## 6. Security & Privacy Posture

- **No secrets collected:** no accounts, no credentials, nothing typed is stored.
  Probes hit public endpoints only.
- **Local-first:** all history lives in the local SQLite store; nothing syncs. Export
  is explicit user action.
- **Opt-in telemetry:** default off. If enabled: anonymous counters (mode run counts,
  crash stack hashes, OS version), no IPs beyond transient probe endpoints, no
  measurement payload values, kill-switch in Settings, documented schema published in
  the repo.
- **Least privilege:** sandbox entitlements limited to outgoing-network client (+ user
  -selected files for export saves). Location used solely for WiFi context, disclosed
  in plain language.
- **Supply chain:** vendored interpreter pinned and hash-checked in CI; notarized,
  universal2 builds; reproducible release script.

## 7. Migration Plan (keep ~201 tests green throughout)

Phase gates — each phase leaves the suite green before the next starts.

1. **Contract phase (engine only, zero UI churn):** add `--json` NDJSON emission and
   cancellation hooks to `netmax.py` + satellites (`netmax_watch`, `netmax_upload`,
   `netmax_eco`, `netmax_throttle`, `netmax_fetch`, `netmetrics`). Existing tests pass
   untouched; new tests pin event schemas (golden-file fixtures).
2. **Data phase:** add SQLite persistence module + importer beside the JSON writers
   (writers remain until Phase 4); round-trip tests prove `results.json` → SQLite
   fidelity. All old tests still green.
3. **UI phase:** new SwiftUI app consuming the contract; engine modules port **as-is**
   (they are pure Python + curl, no UI coupling). Old Tkinter app remains runnable
   during transition as fallback (`netmax_gui.py`). New XCTest suite covers UI-side
   parsing/state; engine suite runs unchanged in CI on both sides of the fence.
4. **Cut-over:** package engine as embedded helper; delete JSON-file writers after
   importer ships in a stable release; retire Tkinter entry point; final count check:
   original ~201 tests green + new contract/data/UI suites.

Port-as-is list: `measure.py`, `netmax.py` core measurement funcs, all six satellite
modules, `tests/*` engine suites. Rewrite: `netmax_gui.py` (superseded by SwiftUI).
Shared risk register: curl availability inside sandbox (vendored libcurl-static
fallback), location-permission edge cases, Apple Silicon timing sensitivity in jitter
tests (mark tolerance-based).
