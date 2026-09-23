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

- CRITICAL+HIGH committed as `995063a` (engine hardening, GUI marshalling, CI gates).
- MEDIUM + IMPROVEMENTS + post-HIGH scan fixes staged for the next commit:
  Swift M1–M10/H3–H7, Python upload/fetch/watch/bridge hardening, F1 GUI worker reuse
  (`netmax_gui.py`), F2 resume-mbps (`netmax_fetch.py` counts only `counter.net`).
- Verification green: pytest **412**, ruff clean, Swift selftests 20/20, bridge selftest 4/4,
  engine-sync clean (root == `desktop/engine/`).
- Open / deferred: H8 license trial (product), M9 drop-in views (product), L1 SIGTERM-then-SIGKILL,
  L3 adaptive `perStreamEstimate`, M3 range SSOT (comment-only), M6 quiet-hours persistence.
- Remote: `github/main` still at `995063a` — push after this commit if desired.
