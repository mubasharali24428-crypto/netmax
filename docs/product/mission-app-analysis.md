# Mission 1 — NetMax → Product App: Analysis Graph

Baseline: netmax v0.5 @ `5cd59d5` (forked to `/Users/user/netmax-app`).

## Goal
Decide whether and how to turn NetMax (macOS bandwidth maximizer + diagnostics CLI/GUI)
into a successful product app. Five analysis lanes run in parallel; each writes ONE
markdown deliverable under `docs/product/`. No code changes in this mission.

## ASCII DAG

```
        [M0 ATLAS: fork + graph]           (done)
                  |
   +--------+-------+--------+----------+
   |        |       |        |          |
 [M1]     [M2]    [M3]     [M4]        [M5]
 product  legal   market   features    arch/ux
 strategy  risk   scan     roadmap      design
   |        |       |        |          |
   +--------+---[M6 ATLAS: exec summary]--+
                        |
                 [commit + report]
```

All M1–M5 nodes are independent (no shared files) → full parallelism.

## File-ownership table (one owner per file; violations void the lane)

| Node | Owner | Owns (write) | Reads only |
|------|-------|--------------|------------|
| M1 | Product Strategist | `docs/product/01-product-strategy.md` | repo root README, PROJECT_LOG.md, source tree |
| M2 | Legal Analyst | `docs/product/02-legal-barriers.md` | same |
| M3 | Market Analyst | `docs/product/03-market-analysis.md` | same |
| M4 | Roadmap Engineer | `docs/product/04-feature-roadmap.md` | same |
| M5 | Architecture/UX Lead | `docs/product/05-app-architecture.md` | same |
| M6 | ATLAS (me) | `docs/product/00-executive-summary.md` | all five |

## Merge checklist
- [ ] Each lane: exactly one file written, inside owned path, ≥150 lines, markdown
- [ ] Claims about law/market flagged with confidence level; no fabricated statistics or citations
- [ ] Executive summary synthesizes verdict + top risks + phased roadmap
- [ ] Single commit by ATLAS; rollback = revert this commit

## Rollback
`git revert` of the mission commit restores fork to pristine `5cd59d5` state.
