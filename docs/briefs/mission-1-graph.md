# ALEX_TEAM Mission 1 — NetMax Product Verification & Diversification

Baseline: ec5c80f (v0.3)

## MISSION
Verify the product end-to-end, then diversify its functionality and improve
working quality. Two waves:
- WAVE 1 — VERIFY: adversarial product verification (does it do what it claims?)
- WAVE 2 — DIVERSIFY: new capabilities, UX improvements, robustness upgrades

## DAG
```
W1: V1 live-probe ─┐
    V2 GUI-audit ──┼─► MERGE-GATE-1 (ATLAS) ─► W2 dispatch
    R1 research ───┘                              │
W2: D1 upload-test ─┐                             │
    D2 history ─────┤   (all parallel,          ◄──┘
    D3 export ──────┤    disjoint lanes)           │
    D4 gui-polish ──┤                              │
    D5 watch-mode ──┴─► MERGE-GATE-2 (ATLAS) ──────┘
```

## FILE OWNERSHIP (one owner per file)
| File | Owner |
|---|---|
| netmax.py | ATLAS only (core engine; agents export specs, never edit) |
| netmax_gui.py | D4 |
| measure.py | D2 |
| tests/test_netmax.py | V1 (add), D5 (append at end of file) |
| test_netmax_gui.py | D4 (append at end of file) |
| README.md | R1 |
| docs/FEATURE-SPECS.md | D1–D5 write spec sections; ATLAS implements |
| evolution/drafts/*.md | each agent's own draft file |

## NODE BRIEFS
- **V1** (ALPHA): Live-probe every CLI mode against real network; verify claims in README vs reality; log defects to docs/VERIFY-REPORT.md. Owns docs/VERIFY-REPORT.md.
- **V2** (ALPHA): Launch GUI, audit all 6 modes' wiring, theme compliance, error paths; report to docs/VERIFY-REPORT.md §GUI. No file edits except that doc.
- **R1** (BETA): Research 2024-25 techniques for network diagnostics tools (packet loss %, jitter, WiFi RSSI/channel on macOS via airport utility); write concrete implementation specs to docs/FEATURE-SPECS.md with sources.
- **D1** (ALPHA): Spec an upload-speed mode (curl -T / POST to httpbin or similar) in FEATURE-SPECS; include test plan.
- **D2** (BETA): Implement results-history index (results/history.json listing all runs w/ timestamps+metrics) in measure.py + tests appended to tests/test_netmax.py.
- **D3** (BETA): Spec CSV/JSON export CLI (`netmax export`) in FEATURE-SPECS.
- **D4** (ALPHA): GUI improvements: add Upload placeholder row, progress bar during runs, menu item "Export last result". Edit ONLY netmax_gui.py + test_netmax_gui.py (append).
- **D5** (BETA): Spec `netmax watch` continuous monitor mode in FEATURE-SPECS; append watch-related engine helper tests to tests/test_netmax.py END.

## MERGE CHECKLIST (ATLAS)
- [ ] All footprints == owned paths
- [ ] Full suite green on merged tree
- [ ] Live probe of ≥1 new capability
- [ ] Specs consolidated; ATLAS implements engine features solo post-gate
- [ ] Rollback: git reset --hard ec5c80f

## STATUS LEDGER
| Node | Status | Verdict |
|---|---|---|
| V1 | DISPATCHED | — |
