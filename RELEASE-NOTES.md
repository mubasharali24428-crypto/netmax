# Release Notes

## v0.7.0-draft — 2026-09-08 (W18 verifier pass)

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
