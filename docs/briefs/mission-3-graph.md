# ALEX_TEAM Mission 3 — Fetch Accelerator + Eco Mode (v0.5)

Baseline: fecfbe1

## MISSION
1. `netmax fetch <url>` — multi-stream adaptive download accelerator
   (auto-split, N streams, latency-aware throttling, pause/resume).
2. Eco mode — data-frugal diagnostics (`--eco` on watch/bloat; tiny probes,
   longer intervals). Data cost ↓ ~99%.

## DAG
```
L1 (parallel):
  F1 fetch-core.py  (chunked downloader engine + tests)
  F2 throttle.py    (adaptive stream controller + tests)
  E2 eco.py         (tiny-probe eco variants + tests)
L2 (ATLAS): wire `fetch` + `--eco` into netmax.py CLI + GUI registry;
            README; version bump 0.5.0
L3: X1 live-verify fetch on real file · X2 coverage audit
MERGE GATE → full suite → live probe → tag v0.5
```

## FILE OWNERSHIP
| File | Owner |
|---|---|
| netmax_fetch.py | F1 |
| netmax_throttle.py | F2 |
| netmax_eco.py | E2 |
| tests/test_netmax_fetch.py | F1 |
| tests/test_netmax_throttle.py | F2 |
| tests/test_netmax_eco.py | E2 |
| docs/VERIFY-REPORT.md | X1 appends §Mission3 |
| README.md | ATLAS only |

## KEY CONTRACTS (agents code to these)
- fetch: `download(url, out_path, streams=8, on_progress=None) -> dict`
  returns {bytes, mbps, streams_used, elapsed_s}; chunk-resumable via
  `<out>.netmax-part-N` files + a `.netmax-meta.json`.
- throttle: `AdaptiveController(min_streams=2, max_streams=16)` with
  `.current()` -> int and `.feed(latency_ms, loss_pct)`; backs off when
  latency > 300 ms or loss > 2%, ramps up when quiet for 3 consecutive checks.
- eco: `eco_bloat(host="1.1.1.1", probe_kb=100) -> dict(delta_ms, grade_est)`
  using a small-range download instead of full saturation.

## MERGE CHECKLIST (ATLAS)
- [ ] footprints == owned paths
- [ ] full suite green
- [ ] live probe: fetch a real ≥10 MB file; measure speedup vs curl single
- [ ] rollback: git reset --hard fecfbe1
