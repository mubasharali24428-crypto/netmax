# ALEX_TEAM Mission 2 — Implement the Six Specced Features (v0.4)

Baseline: 6393af4

## MISSION
Implement upload, loss, jitter, wifi, export, watch as real modes per
docs/FEATURE-SPECS.md. Engine file netmax.py is ATLAS-owned — agents deliver
self-contained modules + tests; ATLAS wires RUNNERS at merge.

## DAG
```
L1 (parallel): U1 upload.py ─┐
               N1 netmetrics.py (loss+jitter+wifi) ├─► MERGE-1 (ATLAS wires)
               E1 export.py  ──────────────────────┤
               W1 watch.py   ──────────────────────┘
L2 (ATLAS): wire RUNNERS + GUI MODES + README + version bump
L3 (parallel): X1 live-verify all new modes · X2 coverage audit
MERGE GATE → full suite → live probe → tag v0.4
```

## FILE OWNERSHIP
| File | Owner |
|---|---|
| netmax_upload.py | U1 |
| netmetrics.py | N1 |
| netmax_export.py | E1 |
| netmax_watch.py | W1 |
| netmax.py | ATLAS only |
| netmax_gui.py | ATLAS only |
| tests/test_netmax_upload.py | U1 |
| tests/test_netmetrics.py | N1 |
| tests/test_netmax_export.py | E1 |
| tests/test_netmax_watch.py | W1 |
| README.md | X2 |

## STATUS LEDGER
| Node | Status | Verdict |
|---|---|---|
