# NetMax — Project Log

**Honest bandwidth maximizer** for macOS. Squeezes the speed your plan already
pays for. It cannot exceed the ISP-provisioned cap — nothing can — but it
claims a bigger share of a *contended* WiFi pipe using standard per-flow TCP
fairness, and finds the fastest DNS resolver for your line.

## What actually works (verified live)

| Feature | Mechanism | Verified result |
|---|---|---|
| Multi-stream turbo | N parallel HTTP downloads → N fair TCP shares under contention | **28.3 → 42.0 Mbps (+48%)** during a contended window |
| Baseline probe | single-stream pull from speed.cloudflare.com | 38.05 Mbps (idle), 28.3 (contended) |
| DNS ranking | raw UDP A-queries, median of 3 | Cloudflare 1.1.1.1 fastest every run (~50–54 ms vs system default 63–68 ms) |

## Root causes found during debugging

1. **Cloudflare rejects `__down` payloads >~50 MB with HTTP 403** (1-byte body).
   Symptom looked like random connection drops; verified by bisecting payload size.
2. **NXDOMAIN ≠ failure**: fast negative DNS replies prove the resolver answered;
   treated as valid latency samples (only ≥2000 ms counts as unreachable).
3. Python urllib is TLS-fingerprint-blocked by Cloudflare bot scoring → engine
   shells out to curl (`%{size_download}`), which passes cleanly.
4. Zero-throughput windows on shared WiFi are real (airtime starvation): tiny DNS
   packets succeed while bulk flows stall. Guarded with an explicit dropout notice,
   never a fake percentage.

## Files

| File | Role |
|---|---|
| `netmax.py` | Engine + CLI: `baseline / turbo / boost / dns / full`, `--streams`, `--seconds` |
| `netmax_gui.py` | Tkinter desktop app wrapping the CLI (subprocess, non-blocking UI) |
| `measure.py` | Live measurement → `results.json` + `results.png` charts |
| `tests/test_netmax.py` | Offline pytest suite (network fully mocked) |
| `PROJECT_LOG.md` | This log |

## Agent work notes (orchestrated build)

- **Main agent (ox-alpha)**: engine design + fixes above, measurement, charts, integration, final verification.
- **Test-suite agent**: offline pytest suite per TDD/systematic-debugging skills. **Done** — 28 offline tests passing (`tests/test_netmax.py`, network fully mocked; run via `python3 -m pytest`).
- **GUI agent**: Tkinter app per TDD/systematic-debugging skills. **Done** — `netmax_gui.py` + 20 headless GUI tests passing (`tests/test_netmax_gui.py`; run via `python3 -m pytest`).
  Design summary: the GUI runs each engine command as an **isolated subprocess** (so a crashed measurement can never take down the UI), marshals results back onto the Tk main loop via **`root.after`** (no raw threading of widget updates), and keeps all colors/fonts centralized in **theme constants** for consistent styling.
- **Review agent**: independent code audit. *(result appended below)*

## Usage

```bash
cd ~/netmax
python3 netmax.py full --seconds 10     # CLI report
python3 netmax_gui.py                   # desktop GUI
python3 measure.py                      # regenerate charts
```

Interpreter note: point `NETMAX_PYTHON` at an interpreter with matplotlib/Tkinter
if your `python3` lacks them (see README Install section).

## Honest limits

- Cannot exceed the ISP cap; gains appear only when the shared pipe is contested.
- Router-side QoS caps override everything here; only the admin or a plan upgrade changes those.

## Session 2 completion (Aug 22, 2026)

The orchestrated build's subagent batch had been interrupted by API errors, cutting off
the test-suite and GUI agents mid-task. This session finished that batch:

- `tests/test_netmax.py` — 28 offline tests passing.
- `tests/test_netmax_gui.py` — 20 headless GUI tests passing alongside the completed `netmax_gui.py`.
- Both suites verified via `python3 -m pytest`.

All deliverables from the original plan are now in place; the review-agent line above
remains the one item still pending its result.

## Session handoff — 2026-09-23 audit pass

- CRITICAL+HIGH committed as `995063a`; MEDIUM + IMPROVEMENTS + F1/F2 as `5303904`.
- Fixes: Swift M1–M10/H3–H7, Python upload/fetch/watch/bridge hardening, F1 GUI worker
  reuse (`netmax_gui.py`), F2 resume-mbps (`netmax_fetch.py` counts only `counter.net`).
- Verification green: pytest **412**, ruff clean, Swift selftests 20/20, bridge selftest 4/4,
  engine-sync clean (root == `desktop/engine/`).
- Open / deferred: H8 license trial (product), M9 drop-in views (product), L1 SIGTERM-then-SIGKILL,
  L3 adaptive `perStreamEstimate`, M3 range SSOT (comment-only), M6 quiet-hours persistence.
- Remote: `github/main` at `1992edd`; local `main` ahead by 2 — not pushed.

## Session handoff — 2026-09-23 deferred-debt lane (L1/L3/M3/M6 + Python)

- Implemented: L1 PID-capture in `EngineClient.stopCurrent`; L3 adaptive
  `perStreamEstimate` from last history; M3 `EngineParameterRanges` SSOT;
  M6 quiet-hours prefs + Settings steppers + coordinator wiring.
- Python: `fetch --adaptive` wired through `AdaptiveController(initial_streams=…)`;
  `_truncate` budget at every depth; `IncompleteRead`/`OSError` → `NetMaxError`
  via `netmax_fetch._read_block`.
- New tests: `tests/test_audit_deferred_debt.py`. Engine `netmax.py`/`netmax_fetch.py`
  re-synced. AUDIT_REPORT + RELEASE-NOTES updated.
- Verification: pytest **425 passed, 1 skipped→0 after fix, 5 subtests**; ruff clean;
  Swift selftests 20/20; bridge selftest 4/4; engine-sync OK.
- Still open: H8 (license trial product). Not pushed.

## Session handoff — 2026-09-23 M9 + SPM test target (v1.0.6 prep)

- M9 wire: BloatStory→RunDetailSheet, WifiDashboard→MenuBar (popover 420pt),
  OnboardingScheduleHost→RootView, ScheduleTabContent (editor + BackgroundRunner),
  ModeLabErrorView error branch, WhatsNew→MenuBarView.
- M9 hide: ReportsEmpty deleted; HistoryEmpty→Notification.Name only; removed
  TabTransition/netMaxPressable/netMaxTransition; NotificationPrefsView struct
  removed (NotificationPreferences class kept); FeatureDiscovery pitch fixed;
  GlobalHotkey stays commented (documented NSEvent starve).
- SPM: `Package.swift` + `Tests/netmax-desktopTests/SwiftHarnessTests.swift`
  wraps 20 `runAll()` harnesses; `swift test` green alongside shell harness.
- Versions: desktop/package.json + server.json → **1.0.6** (pyproject stays 0.5.0).
- AUDIT M9 → FIXED (deliberate); re-audit: MenuBar 420pt for Wifi floor; comments
  cleaned (Settings/HistoryStore/StatusPublisherHook).
- Verification: pytest 425, ruff clean, Swift selftests 20/20, `swift test` 1/1
  (20 harnesses), bridge selftest 4/4, engine-sync OK.
- Still open: H8 (license trial product). Not pushed.

## Session — 2026-09-26 long-run auto-stop fix + Mode Lab speed cap (v1.0.7)

- USER-REPORTED BUG: runs set to 15/30+ min "auto stopped". Root cause (verified
  live): `_pull` returned on the first clean curl finish — the test files are
  100 MiB (OVH) / 50 MB (CF), so at 32 Mbps a "60-second" run ended at 26 s
  (105 MB). The W15 long-run UI (up to 6 h) had no engine-side sustaining.
- Fix: `_pull` now serves the window as BACK-TO-BACK chunks (fresh cache-buster
  per chunk) until the window cap (exit 28); mid-run endpoint blips pause and
  retry instead of aborting; zero-byte windows still raise. Live verify:
  60 s baseline → 59.97 s / 384 MB.
- New `limit` mode (user-requested "put a limit on network speed"): holds a
  fixed aggregate Mbps for the whole run, cap divided evenly across streams
  (curl --limit-rate, plain bytes/s). Honest verdicts held/short/overrun.
  Live verify: 2 Mbps × 1 stream = 2.0 held; 2 Mbps × 4 streams = 2.1 held.
- Mode Lab: `limit` card + SpeedCapEntryView (direct Mbps entry), presets get
  optional `mbps` (legacy presets decode), `netmax.state.lastMbps` restore,
  EngineParameterRanges.mbps mirrors bridge RANGE_BOUNDS.
- Bridge: limit + --mbps (float 0.5..10000, untruncated forwarding); timeout
  already scaled (W15 F5 fix). Tests 425 → 445 green; bridge selftest 4/4;
  ruff clean; swift build + `swift test` green (26 harnesses).
- Versions synced to 1.0.7 (package.json → pyproject/cask/RELEASE-NOTES);
  app rebuilt via build_app.sh and installed to /Applications.

## Session — 2026-09-27 Dashboard Speed Limit + Quick Test lengths (v1.0.7 delta 2)

- USER: "add time limit to Quick Test (5/10/15 min), bring the limit feature to
  the Dashboard as a RED RECTANGULAR button, and make the engine hold the cap
  consistently for long periods."
- Engine: `_limit_governor` closed-loop controller (5 s intervals, ±1.5×
  correction clamp, warm-up skip, starvation guard, ±3% deadband, dead-interval
  survival up to 5 min, stability report line). Unit bug caught by tests
  (bytes/s vs bits/s) before ever shipping.
- Dashboard (MenuBarView = tab 0): Quick Test length picker (per-leg halving so
  boost's TOTAL matches the pick); SpeedLimitCard red bar + panel (any speed
  0.5–10000 incl. decimals, DurationEntryView, streams, Start/Stop, verdict +
  stability in the result box, history mode "limit").
- Harnesses 26 → 27 (SpeedLimitCardTests). pytest 453 green; ruff clean;
  swift build + swift test green; app rebuilt, seal OK, installed to
  /Applications and restarted (governor + UI strings verified in bundle).

## Session — 2026-09-27 tight band guarantee (v1.0.7 delta 3)

- USER: held speed must sit in a tight band around the limit (2 → ~1–4, never
  10/20; 15 → 10–20, never 30). Root hole found: degradation ratcheted the
  governor pace ×1.5/interval → a recovering line could briefly deliver
  multiples of the target.
- Fix: LIMIT_PACE_CEILING = 1.5× target, applied unconditionally per interval
  (init, warm-up, corrections all bounded). One-interval transient max 1.5×,
  sustained band ±10% aim, down-correction lands on target in one step.
  Report gained the "band guard" line.
- pytest 455 green (+2 ceiling tests); ruff clean; rebuilt + reinstalled +
  restarted the app. Live re-verify deferred: both speed CDNs 429-limited
  after the session's heavy pulls (engine honestly reports them as dead
  intervals rather than counting the bodies); background check scheduled.
- End-to-end band verification (local HTTP server + real curl + real governor,
  since public CDNs were 429-cooling): 2 Mbps × 1 stream → held 2.04, interval
  rates 1.90–2.16 (ceiling 3.0); 15 Mbps × 2 streams → held 14.92, rates
  14.88–15.27 (ceiling 22.5). Both inside ±10% post-warm-up; ceiling never
  approached.

## Session — 2026-10-03 waves 1-4 (versions, breaker, 4 endpoints, strict ceiling, MCP #15)

- Wave 1 (hygiene+security): server.json 1.0.6→1.0.7 (all 4 pins agree; CI
  version-pin step added); README counts resynced (412→482 across waves);
  SESSION-HANDOFF identifiers redacted (gitignored, never committed); MCP
  refuses off-loopback without NETMAX_TOKEN (exit 2, 3 paths verified);
  docs/.DS_Store untracked. history.jsonl 0600 already enforced both
  sides — verified, no change.
- Wave 2 (reliability): escalating endpoint breaker (60s→5min→1h, success
  resets; single-fail behavior identical); engine copy re-synced; loopback
  MCP concurrency smoke (web-mcp-smoke.mjs) + ubuntu CI job.
- Endpoints 2→4: Hetzner + CacheFly vetted live (HEAD/range-GET only);
  LeaseWeb dropped (dead path); CF demoted last (adaptive bot 403s).
  Rotation + mirror-order tests added.
- Wave 3 (strict ceiling): netmax_shape.py (dnctl+pf anchor, lo0 excluded,
  finally-cleanup, SIGTERM guard, ShapeError dodges dual-module trap);
  `limit --strict` CLI. Live: 60s + 90s holds exit 0, teardown clean x3;
  sync-flagged ceiling proof — turbo 2.2 / baseline 0.7 under a 5 Mbps
  cap (refs 10.9/10.4). Ceiling semantics, not exact fill (no queue knob
  on pipes per dnctl man page).
- Wave 4 (MCP): bridge --strict passthrough (bare bool flag, droppedFlags
  when misapplied); `strict_limit` tool #15 (seconds<=150 vs 180s exec
  timeout); 14→15 swept (banners, manifests, smoke scripts, READMEs,
  landing, marketing copy; historical records untouched).
- Gates: ruff clean; pytest 482 passed; bridge selftest 4/4; live smoke
  ALL PASS. Open: Swift menu-bar toggle for strict (product/security call);
  ceiling re-verify only if pipe behavior questioned (evidence on file).

## Session — 2026-10-04 remaining-debt sweep (except launch track)

- Upload fix (concurrent editor, `ce55f5a`): `-H "Expect:"` kills the
  100-continue interim status; bytes parsed before status; 2xx + curl-28
  accepted. Verified: 28 upload tests pass, ruff clean.
- Docs: README test count 513→906 (store+bridge 104→118); 17 MCP tools
  confirmed current. Old wave counts left as history.
- Untracked triage (left untracked, deliberate): `NetMax-1.1.1.dmg` now
  gitignored (build artifact); root stub `notarize.sh/sign.sh/optimize.sh/
  setup-*.sh` are placeholders — real pipeline is `desktop/scripts/`;
  `netmax.icns/iconset/` unreferenced by any build file; foreign
  `netmax_ai_provider.py` untouched per collision protocol.
- Launch track (HN, notarize, submissions, rotations) untouched by request.
