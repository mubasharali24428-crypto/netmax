# Mission: NetMax→App Analysis — THE VERIFIERS Brief

Coordinator: ATLAS session. Baseline commit: see `git log --oneline -1` (graph +
this brief committed alone; every builder deliverable remains uncommitted until
final merge, so `git status --short docs/product` is the authoritative footprint).

## Verticals (one pair each; disjoint — TRIO ×3 applies)

### PAIR A — Strategy×Roadmap seam
- Lanes: M1 (`docs/product/01-product-strategy.md`), M4 (`docs/product/04-feature-roadmap.md`)
- Seam contract: M1's recommended primary concept must be exactly what M4's
  NOW/NEXT horizons scope; every module name, CLI mode, and engine fact cited in
  either file must exist in the actual repo tree (netmax*.py, netmetrics.py,
  measure.py, tests/) and match README/PROJECT_LOG ground truth.

### PAIR B — Architecture integrity
- Lane: M5 (`docs/product/05-app-architecture.md`)
- Seam contracts: (1) M5's stack recommendation must credibly host M4's NOW
  features (menu bar, background tests, PDF export) and M1's concept;
  (2) platform claims tagged [CONFIRMED]/[UNCERTAIN] honestly; SQLite schema
  must cover fields the engine actually produces (results.json / history.json).

### PAIR C — Legal×Market seam
- Lanes: M2 (`docs/product/02-legal-barriers.md`), M3 (`docs/product/03-market-analysis.md`)
- Seam contract: M3's distribution/pricing recommendations must not contradict
  M2's App Store/ToS risk findings; both must carry uncertainty tags and zero
  invented statistics, statutes, or case citations.

## Verifier-owned write paths (ONLY these, ONLY for MAJOR/MINOR fixes)
- Pair A: `docs/product/verifier-reports/pair-a.md`
- Pair B: `docs/product/verifier-reports/pair-b.md`
- Pair C: `docs/product/verifier-reports/pair-c.md`

## Checklist (adapted to a documentation mission)
1. Footprint audit — `git status --short` vs lane ownership; any unexpected
   tracked-file modification = BLOCKER.
2. Ground-truth rerun — verifier personally runs:
   `cd /Users/user/netmax-app && /Users/user/1/bin/python -m pytest -q`
   and pastes real output. Known-good reference: 157 passed (ATLAS-measured).
   Note: README claims 201 — record the discrepancy as a MINOR finding, do not
   fail lanes for it.
3. Anti-synthesis scan — grep each deliverable for: statistics/market numbers
   without qualitative hedging, statute/case citations, module or function
   names that don't exist in the repo (cross-check with search_files),
   empty placeholder sections, TODO/FIXME stubs presented as done.
4. Contract conformance — field-by-field per the seam above.
5. Integration probe across the seam — build a consistency table (claim →
   supporting/refuting line in the sibling doc); probe ≥5 concrete cross-claims.
6. Classification — BLOCKER (fabricated content, contradiction on core
   recommendation, missing file/length <150 lines) → FIX-LOOP:<lane>.
   MAJOR/MINOR → prime fixes IN-LANE inside owned paths only, records the fix.
7. Verdict — `READY-TO-MERGE` or `FIX-LOOP:<lane>` + blockers, recorded in the
   pair report with pasted evidence for every claim.

## Hard rules (zero exceptions)
No git commands that mutate history or commit. No installs. No edits outside
your verifier report path (fixes limited to your vertical's owned lanes).
Never fabricate findings or outputs — empty-evidence reports are rejected and
re-dispatched. An unverified suspicion is labeled SUSPICION, never fact.
