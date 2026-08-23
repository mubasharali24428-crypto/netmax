# NetMax — Product Feature Roadmap (Now / Next / Later)

**Owner:** Sub-04 (product/roadmap) · **Base:** NetMax v0.5 @ git `5cd59d5` · **Status of codebase:** all
capabilities below marked "existing" are real and covered by 157 offline tests
(verified via pytest rerun 2026-08-23; README's "68" predates the v0.4 diagnostic suites).

Existing foundation we build on:

| Module | Capability |
|---|---|
| `netmax.py` | Engine + CLI: `baseline / turbo / boost / dns / bloat / full`, `--streams`, `--seconds`; curl-based probes (urllib is TLS-fingerprint-blocked by Cloudflare — do not regress to urllib) |
| `measure.py` | Live run → `results.json` + `results.png` + `history.json` |
| `netmetrics.py` | Packet loss %, jitter (RTT deltas), WiFi RSSI/noise/channel via `system_profiler SPAirPortDataType` (`airport` binary is gone on modern macOS) |
| `netmax_upload.py` | Upload probe (curl POST; Cloudflare `__up` verified fastest) |
| `netmax_export.py` | CSV/JSON export |
| `netmax_watch.py` | Continuous monitor loop |
| `netmax_fetch.py` | Fetch accelerator |
| `netmax_eco.py` | Eco mode |
| `netmax_throttle.py` | Throttle detection helpers |
| `netmax_gui.py` | Tkinter app; every command runs as an isolated subprocess marshalled back via `root.after` |
| Known engine facts | Cloudflare rejects `__down` >~50 MB (HTTP 403); NXDOMAIN is a valid latency sample; zero-throughput windows are reported as real dropouts, never faked |

---

## 1. Gap-to-product analysis: demo → shippable app

What exists today is a strong *measurement engine* plus two developer-grade
frontends (CLI + Tkinter window launched from a repo checkout with a specific
interpreter at `/Users/user/1/bin/python`). What's missing between that and
something a non-technical person can install and trust:

- **Packaging & distribution.** No `.app` bundle, no signed/notarized DMG, no
  bundled Python runtime. Today's user must own a Python env with matplotlib +
  Tkinter. A product must be double-click-to-run.
- **Auto-update.** No version check, no update channel, no migration of
  `history.json` across versions.
- **Crash reporting & diagnostics.** A crashed measurement is isolated from the
  UI today (good), but nothing captures *why* it crashed. No log bundle, no
  opt-in crash upload.
- **Onboarding & first-run.** No first-run flow explaining the honest-limits
  positioning ("we can't beat your ISP cap") before the first measurement —
  the single biggest expectation-management risk.
- **Licensing / paywall.** No trial gating, license key check, or receipt
  validation. Also no decision yet on one-time purchase vs subscription.
- **Trust surface.** The product's differentiator is honesty (README leads with
  anti-scamware limits); packaging, onboarding, and reports must carry that
  voice or the positioning collapses.
- **Supportability.** No way for a user to hand us a reproducible artifact
  (sanitized report + logs) when a test misbehaves.

---

## 2. NOW — must-have for v1.0 launch

Each item: one-line spec, acceptance criteria, effort (S/M/L), deps, module base.

### N1. Signed, notarized macOS .app bundle + DMG
One double-clickable app that bundles its own Python runtime.
- **Accept:** fresh machine with no Python installs runs the full suite of modes
  from the .app; Gatekeeper opens it without right-click workarounds; binary size ≤ ~150 MB.
- **Effort:** M · **Deps:** none · **Base:** wraps `netmax_gui.py`; freezes the interpreter dependency.

### N2. First-run onboarding with honest-limits consent screen
Three-panel first launch: what NetMax does, what it cannot do (ISP cap), then permission to run network probes.
- **Accept:** first run always shows the limits screen before any traffic;
  a stored flag skips it afterwards; "Reset tour" exists in Settings.
- **Effort:** S · **Deps:** N1 (bundle) · **Base:** `netmax_gui.py`.

### N3. Menu-bar presence (macOS status item)
NetMax lives in the menu bar with last grade/speed and a dropdown to run quick test or open the main window.
- **Accept:** menu-bar icon shows latest result within 2 s of a test finishing;
  clicking "Run quick test" executes `baseline`+`bloat` without opening a window;
  app works docked-to-menubar-only (LSUIElement mode toggle).
- **Effort:** M · **Deps:** N1 · **Base:** `netmax_gui.py` + `netmax.py` CLI subprocess pattern.

### N4. Scheduled background tests
User-configurable schedule (e.g. hourly/every-6h/daily at time) running quiet background measurements into history.
- **Accept:** schedule survives relaunch (launchd agent or in-app timer with persistence);
  scheduled runs skip when offline; results land in `history.json` tagged `source=scheduled`;
  battery-impact note documented.
- **Effort:** M · **Deps:** N1 · **Base:** `netmax_watch.py` loop + `measure.py` persistence.

### N5. ISP comparison report card
Single-page verdict: your measured down/up/loss/jitter/bufferbloat grade vs your plan's advertised tier, letter-graded.
- **Accept:** report shows plan-tier input (user-entered), measured values,
  % of advertised delivered, bufferbloat grade, and an explicit honest-limits footer;
  renders both in-app and in exported output; no claims beyond measured data.
- **Effort:** S · **Deps:** none · **Base:** `netmax.py full` + grading logic from `bloat` mode.

### N6. Degradation notifications
Local notification when a scheduled/background test shows significant degradation vs the user's recent norm.
- **Accept:** threshold configurable (default: >30% below trailing median AND sustained ≥2 consecutive runs);
  notification includes one-tap "View report"; silent when values are normal;
  no notification spam (min gap configurable).
- **Effort:** M · **Deps:** N4 (scheduled runs feed it), N8 (history stats) · **Base:** `netmax_watch.py`, `history.json`.

### N7. PDF report export & share sheet
One-click export of the report card (N5) plus charts as a shareable PDF.
- **Accept:** PDF contains headline metrics, bufferbloat grade, charts, timestamp, and honest-limits footer;
  generated locally (no network call); opens correctly in Preview; share button hands it to macOS share sheet.
- **Effort:** M · **Deps:** N5 · **Base:** matplotlib charts from `measure.py` (`results.png` pipeline) → PDF.

### N8. History trends view in-app
Roll-up of `history.json`: sparkline/trend chart of throughput over days/weeks, min/median/max.
- **Accept:** view renders from history alone (works offline); range selector (7d/30d/all);
  handles missing days; export of trend data reuses CSV path.
- **Effort:** S · **Deps:** none · **Base:** `history.json` from `measure.py`, `netmax_export.py`, matplotlib.

### N9. Crash capture + sanitized diagnostics bundle
Any unhandled engine/GUI error writes a local crash log and offers a sanitized support bundle.
- **Accept:** forced-error test produces a readable log with version/OS/mode;
  bundle contains logs + last report but redacts SSID and excludes raw payloads;
  opt-in only — nothing leaves the machine by default.
- **Effort:** S · **Deps:** none · **Base:** subprocess isolation already in `netmax_gui.py`.

### N10. Licensing + trial gate (decision required, see open question)
Feature-gated free tier (full measurement suite free; scheduling/history-trends/reports paid) with license-key validation.
- **Accept:** unlicensed app = fully functional measurer forever (trust play), paid features gated behind key;
  key validated locally with offline grace period; refund-friendly 14-day trial flag.
- **Effort:** M · **Deps:** N1 · **Base:** new licensing module; no engine changes.

**v1.0 exit bar:** N1–N9 shipped; N10 decided and either shipped or explicitly deferred with pricing page saying so.

---

## 3. NEXT — differentiators (v1.x)

These turn a speed tester into a network-quality product. Order reflects
dependency and payoff density.

### X1. Continuous QoE timeline with WiFi-event correlation
Merge watch-loop samples with WiFi events (roams, RSSI drops, channel changes) into one scrollable timeline.
- **Accept:** timeline shows throughput/loss/jitter lanes with event markers; hovering an event shows before/after deltas;
  correlation claim only shown when event timestamp matches sample within tolerance.
- **Effort:** L · **Deps:** N4, N8 · **Base:** `netmax_watch.py`, `netmetrics.py wifi`, `history.json`.
  [UNCERTAIN] Event sources post-`airport` removal may need `wdutil` (sudo) or CoreWLAN via PyObjC — needs spike.

### X2. Router awareness
Detect router make/model/firmware where disclosed (DHCP fingerprint, UPnP/IGD description) and surface known-issue notes.
- **Accept:** gateway vendor/model shown when detectable; known-issues DB consulted with clear "as reported publicly" framing;
  gracefully says "unknown router" otherwise; read-only — never logs into the router.
- **Effort:** L · **Deps:** none hard; benefits from X1 timeline · **Base:** `netmetrics.py`, new probe module.
  [UNCERTAIN] Coverage of a maintained known-issues dataset is the real cost, not detection.

### X3. Multi-device coordination (companion probe agent)
A tiny helper on a second device runs the same probe set simultaneously, so contention effects can be attributed.
- **Accept:** two-device run produces a paired report showing each device's share during contention;
  discovery over LAN with explicit pair-once consent on both ends.
- **Effort:** L · **Deps:** N1 (packaging story extends to helper) · **Base:** `netmax.py` engine reused headless.
  [UNCERTAIN] iOS/Android companion is out until cross-platform (L1) lands; scope v1.x to Mac+Mac.

### X4. Per-app network attribution (concepts)
Show *which processes* are consuming bandwidth during a test window using OS counters (read-only).
- **Accept:** top talkers list during any measurement; totals reconcile with interface counters within stated tolerance;
  requires user grant (macOS permissions), degrades to "unavailable" cleanly if denied.
- **Effort:** L · **Deps:** N1 · **Base:** new module; complements `netmax_fetch.py` accelerator guidance.
  [UNCERTAIN] Exact API surface (network extension vs sampling `nettop`) needs a spike; privacy review mandatory.

### X5. History anomaly detection
Statistical flags over long history: sudden median drop, rising loss trend, weekly-pattern shifts — plain-language explanations.
- **Accept:** anomalies annotated on trend view with confidence wording ("unusual", not "broken");
  false-positive rate acceptable at default sensitivity (tune against ≥60 days of local runs);
  explainable rule-based first, ML later.
- **Effort:** M · **Deps:** N8 · **Base:** `history.json` analytics layer.

### X6. Bufferbloat under load storytelling
Extend `bloat` grade with an explainer that ties the grade to real activities (calls, gaming) and to turbo-mode behavior.
- **Accept:** grade page explains cause + one actionable suggestion; links measured latency-under-load numbers;
  no invented fixes (never promises QoS changes it can't perform).
- **Effort:** S · **Deps:** none · **Base:** `netmax.py bloat`.

---

## 4. LATER — big bets

### L1. Cross-platform: Windows companion
Port engine to Windows (PowerShell/curl paths, different WiFi telemetry), shared core, platform adapters.
- **Effort:** L · **Deps:** engine abstraction layer extracted first · **Base:** `netmax.py` (curl core ports well; `system_profiler` WiFi does not).
- Note: keep macOS flagship; Windows ships measurement-first subset.

### L2. Cloud sync + opt-in anonymized crowd data
Optional account syncing history across machines; separate, explicit opt-in contributing anonymized metrics to aggregate views.
- **Effort:** L · **Deps:** N10 (accounts/licensing), privacy counsel · **Base:** `netmax_export.py` JSON schema as sync format.
- Hard rules: anonymization irreversible, contribution separable from sync, published data dictionary.

### L3. Community ISP benchmarking reports
Aggregate opt-in data into public per-ISP/per-region report cards ("what plans deliver vs advertise").
- **Effort:** L · **Deps:** L2 · **Base:** crowd corpus from L2; grading logic from N5.
- Anti-abuse: outlier trimming, sample-count floors, methodology page.

### L4. Integrations API: Home Assistant, Shortcuts, webhooks
Expose local REST endpoint + Shortcuts actions; push results to Home Assistant sensors/webhooks.
- **Effort:** M · **Deps:** stable result schema · **Base:** `results.json` schema; `netmax_watch.py` trigger points.

### L5. ML-assisted issue diagnosis
Classify symptom patterns (airtime starvation vs bufferbloat vs ISP congestion vs WiFi interference) from measurement fingerprints.
- **Effort:** L · **Deps:** X1/X5 labeled corpus · **Base:** rule-based X5 upgraded.
- Gate: only ship when it beats the rule-based baseline on held-out runs; always shows evidence, never bare labels. [UNCERTAIN]

---

## 5. Effort / dependency summary

| ID | Feature | Effort | Depends on | Builds on |
|---|---|---|---|---|
| N1 | Bundle + DMG | M | — | `netmax_gui.py` |
| N2 | Onboarding | S | N1 | `netmax_gui.py` |
| N3 | Menu bar | M | N1 | `netmax_gui.py`, `netmax.py` |
| N4 | Scheduled tests | M | N1 | `netmax_watch.py`, `measure.py` |
| N5 | Report card | S | — | `netmax.py full`/`bloat` |
| N6 | Degradation alerts | M | N4, N8 | `netmax_watch.py`, history |
| N7 | PDF export/share | M | N5 | `measure.py` charts |
| N8 | History trends | S | — | `history.json`, `netmax_export.py` |
| N9 | Crash bundle | S | — | GUI subprocess isolation |
| N10 | Licensing/trial | M | N1 | new module |
| X1 | QoE timeline | L | N4, N8 | watch + `netmetrics.py` |
| X2 | Router awareness | L | — | `netmetrics.py` |
| X3 | Multi-device | L | N1 | `netmax.py` headless |
| X4 | Per-app attribution | L | N1 | new; near `netmax_fetch.py` |
| X5 | Anomaly detection | M | N8 | history analytics |
| X6 | Bloat storytelling | S | — | `bloat` mode |
| L1–L5 | See above | L/M | noted | noted |

Sequencing logic: everything in NOW is packaging/persistence/reporting around a
stable engine — deliberately no engine rewrite. NEXT spends engineering on data
correlation; LATER bets require infrastructure (cloud, second platform) that
must not block v1.0 revenue.

## 6. Non-goals (explicitly NOT building)

- **Anything resembling scamware claims.** No "boost your internet 10x", no
  fake accelerators, no misleading before/after marketing. The README's honest
  limits (cannot exceed the ISP cap; gains only under contention) are product
  law, and all copy inherits them.
- **VPN/proxy features.** Routing user traffic through our servers would change
  the regulatory class (telecom/privacy obligations), the security posture, and
  the trust story. Out of scope permanently, not just for now.
- **Router firmware flashing or router configuration writes.** Read-only
  detection (X2) only; we never flash, reconfigure, or manage third-party routers.
- **Driver/kernel-level traffic shaping.** Packet interception or driver installs
  are a support/security liability far beyond a measurement app.
- **Background data collection without explicit, revocable opt-in.** Default is
  local-only, forever.
- **Speed-test-server hosting business.** We ride public endpoints (Cloudflare
  et al.); operating our own global probe fleet is not the product.

## Open questions for the parent squad

1. **Pricing model (blocks N10):** one-time purchase vs subscription; whether
   scheduling/trends/reports are the right paid line. Recommend one-time +
   optional upgrade bundle given the honesty-led positioning.
2. **Menu-bar-only mode (N3):** ship as default posture or opt-in setting?
3. **X4 attribution:** acceptable privacy trade for process-level visibility?
   Needs a written stance before any spike.
