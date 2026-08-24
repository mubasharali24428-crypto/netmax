# TEAM-DELTA — Adversarial QA Sweep (W4)

- **Date:** 2026-08-24 (PDT)
- **Repo:** /Users/user/netmax-app @ `5306925+` (W4, post TEAM-1/2/3 merges)
- **Scope swept:** `desktop/bridge/engine_bridge.py`, engine CLI (`netmax.py`),
  Swift app (`desktop/SwiftNetMax`), shipped bundle
  (`desktop/build/NetMaxDesktop.app`), `desktop/scripts/verify_phase1.sh`.
- **Method:** red-team probes with live runs; no code modified. A clean probe is a valid result.

**Verdict: SHIP-BLOCKER found — one HIGH bug violates the bridge's own envelope contract.
Everything else probed came back clean or LOW.**

---

## Findings

### F1 — HIGH · Bridge silently accepts unsupported flags and reports success
- **Probe:** `engine_bridge.py run wifi --count 5 --json-out …`
- **Result (real output):**
  ```
  EXIT_A6=0
  {"success": true, "mode": "wifi", "data": {"raw": "rssi_dbm: -17\nnoise_dbm: -98\nchannel: 13\n"}, "error": null}
  ```
- **Why it matters:** the caller asked for something the mode cannot do and got
  `success:true` for a *different* measurement than requested. The UI layer has
  no way to know `--count` was discarded. Silent misexecution beats a loud
  error only in the sense that nobody files a ticket about it.
- **Evidence of intent gap:** `engine_bridge.py` selftest line 246 explicitly
  asserts dropped flags (`("turbo", {…count…}) → [py, engine, "turbo"]`), so
  this behavior is deliberate at the code level but unsafe as an API surface.
- **Suggested fix direction (not applied):** reject unknown-for-mode flags with
  an envelope failure instead of dropping them.

### F2 — MED · Engine bounds are enforced by netmax.py, not the bridge
- **Probes:** `boost --seconds 0`, `--seconds 31`, `--streams 99`, `loss --count -3`
- **Results (all exit 1, clean envelopes):**
  ```
  {"success": false, "mode": "boost", "data": null,
   "error": "netmax: --seconds must be 5..30, got 0"}
  {"success": false, "mode": "boost", "data": null,
   "error": "netmax: --seconds must be 5..30, got 31"}
  {"success": false, "mode": "boost", "data": null,
   "error": "netmax: --streams must be 1..32, got 99"}
  {"success": false, "mode": "loss", "data": null,
   "error": "netmax: --count must be 1..100, got -3"}
  ```
  All four rejected by engine validation; `boost --streams 1 --seconds 5`
  succeeded (exit 0) — streams=1 is legal.
- **Assessment:** defense lives one layer down. The bridge forwards raw ints,
  so any future engine regression in range checks becomes a desktop-visible
  bug. Acceptable today (engine checks held on every abuse case); flagging as
  hardening debt, not a defect.
- Also note `TIMEOUT_S = 180`: a 30 s engine mode can't hit it, but the guard
  exists and works offline-tested only.

### F3 — HIGH · Unwritable `--json-out` escapes the envelope contract with a raw traceback
- **Probes:** success path, argparse-error path, two unwritable destinations.
- **Results (real):**
  ```
  $ python3 desktop/bridge/engine_bridge.py run boost --seconds 5 --json-out /proc/x/y/out.json
  Traceback (most recent call last):
    File "…/engine_bridge.py", line 372, in main
      return run_engine(...)
    File "…/engine_bridge.py", line 214, in run_engine
      write_envelope(...)
    File "…/engine_bridge.py", line 145, in write_envelope
      parent.mkdir(parents=True, exist_ok=True)
  OSError: [Errno 30] Read-only file system: '/proc'
  EXIT_B1=1

  $ python3 desktop/bridge/engine_bridge.py run dns --json-out /tmp/delta_ro/out.json   # chmod 555 dir
  PermissionError: [Errno 13] Permission denied: '/tmp/delta_ro/out.json'
  EXIT_B1b=1

  $ python3 desktop/bridge/engine_bridge.py run BOOST --json-out /proc/x/y/out.json     # argparse path too
  OSError: [Errno 30] Read-only file system: '/proc'
  EXIT=1
  ```
- **Why it's HIGH:** module docstring promises *"This script never raises past
  main(); every failure lands in the envelope"* (lines 18–19). Both `write_envelope`
  call sites in `run_engine` (lines 214, 226) sit outside any try block; the
  `_fail_envelope` argparse path can crash the same way. Worst case observed:
  the engine finishes its full run successfully, then the process dies writing
  the envelope — the GUI sees a non-zero exit, no envelope file, and a Python
  traceback where structured output was promised.
- **Reproduction rate:** 3/3 across distinct paths (missing-parent chain under
  read-only root, permission-denied file, argparse error route).

### F4 — LOW · Uppercase modes produce a noisy-but-correct rejection
- **Probe:** `run BOOST --json-out /tmp/delta/b2.json`
- **Result:** exit 1, envelope written:
  `{"success": false, "mode": "BOOST", "error": "invalid arguments: argument mode: invalid choice: 'BOOST' (choose from 'baseline', 'turbo', …)"}`.
- Correct behavior, verbose error text. Cosmetic only; could suggest lowercase
  normalization in the error message.

### F5 — CLEAN · Duplicate flags
- **Probe:** `run boost --seconds 6 --seconds 6 --json-out …` → exit 0, single
  value forwarded once (argparse last-wins), valid envelope. No corruption.

### F6 — CLEAN · Concurrency
- **Probe:** two simultaneous `run loss --count 12` processes, separate out-files.
- **Result:** both exited 0 (~160–175 s wall time), both envelopes parse as
  valid JSON with identical key sets, both report real data
  (`packet loss: 0.0%`). No interleaving or partial writes observed.

### F7 — CLEAN · Swift runtime-path hygiene
- `as!` count in `Sources/`: **0**
- Force-unwrap postfix (`x!.`, `x!(`) on runtime paths: **0**
- TODO/FIXME/HACK/XXX markers: **0**
- `precondition(window >= 1)` (AnomalyEngine.swift:173): reachable only via
  internal callers passing literal defaults (window=7); no external input path
  feeds it. Not exploitable today; would become one if a settings pane ever
  exposes the window knob.

### F8 — CLEAN · DEBUG self-checks compiled out of release
- All six self-check suites verified inside `#if DEBUG` blocks:
  BloatStory (102–116 + enum at 272), AnomalyEngine (442–560),
  StatusBarController (285–367), ScheduleRunner (252–353),
  RunPostProcessor (143–262), StatusPublisherHook (109–198).
- Binary-level proof: `strings` on the shipped
  `build/NetMaxDesktop.app/Contents/MacOS/NetMaxDesktop` finds **0** hits for
  `netmax.status.selfcheck`, `netmax.runner.selfcheck`,
  `netmax.postproc.selfcheck`, `BLOAT_GRADES`.

### F9 — CLEAN · Shipped bundle matches HEAD
- `bridge/engine_bridge.py` byte-identical to repo copy.
- `netmax.py`, `netmax_throttle.py` byte-identical to repo copies.
- (Self-correction logged: an initial "DIFFERS" reading was my own path typo,
  not a product issue.)

### F10 — PASS · verify_phase1.sh gate honesty
- Full run after W4 merges: **PASS, 5/5 executable steps, 0 skipped**, exit 0:
  - [a] `swift build -c release` green
  - [b] pytest **177 passed** in 8.07 s (threshold ≥150)
  - [c] scheduler snippet SCHEDULER_PROBE_OK 10/10
  - [d] notifications snippet NOTIFY_PROBE_OK 9/9
  - [e] ReportCardPDF generated, magic-checked (26,542 bytes)

---

## Severity roll-up

| ID | Severity | Area | One-liner |
|----|----------|------|-----------|
| F1 | HIGH | bridge | Unsupported per-mode flags silently dropped, reported as success |
| F3 | HIGH | bridge | Unwritable `--json-out` → unhandled traceback, no envelope, contract broken |
| F2 | MED | bridge/engine | Range validation lives only in engine, not bridge (hardening debt) |
| F4 | LOW | bridge | Uppercase mode rejection correct but verbose |
| F5–F10 | CLEAN | various | Dup flags, concurrency, Swift hygiene, DEBUG gating, bundle sync, verify gate |

## Recommended pre-release actions
1. Fix F3 first (wrap `write_envelope` sites + `_fail_envelope` writer in
   try/OSError handling that degrades to stderr + exit 1 without traceback).
2. Decide policy for F1: either reject unknown-for-mode flags or return the
   dropped set in the envelope so the UI can render it.
3. F2 can ship as-is with a tracked follow-up.

*No fixes were applied by TEAM-DELTA (red-team mandate). Scratch files cleaned up; git tree untouched by this sweep.*
