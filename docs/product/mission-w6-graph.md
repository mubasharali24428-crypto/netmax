# Mission W6 — ELITE AUDIT ×2 + 10× UPGRADE PLAN (ALEX-ELITE)

Base: netmax-app @ `9df6cf1` (W5 closed: X1 timeline built, wiring pending).

## Objective
Two ELITE teams deep-audit the entire project, FIX what they find (not just
report), then jointly author the 10× upgrade potential assessment + roadmap.

## Team composition per skill doctrine
Each team: 1 Primary (principal engineer) + 4 Subs (senior engineers) = 5.
- **TEAM-A "Correctness"** — code-level: engine, bridge, Swift app, tests.
- **TEAM-B "Product & Scale"** — product-level: UX gaps, architecture debt,
  security/privacy posture, distribution readiness, growth levers.

## TEAM-A lanes (correctness audit → fix)
| Lane | Scope | Owns |
|---|---|---|
| A-P | Primary review: cross-file seams (bridge↔engine↔app), API consistency, error-path completeness; fixes via its subs | reports |
| A-S1 | Engine Python: netmax*.py correctness, edge cases, resource leaks; FIX in place | engine files |
| A-S2 | Bridge: envelope contract violations (incl. tracked F1/F2), flag policy implementation; FIX | bridge |
| A-S3 | Swift app: force-unwraps, race risks in singletons, memory retention cycles; FIX | swift files |
| A-S4 | Test adequacy: find untested critical paths, add missing batteries; extend suites | test files |

## TEAM-B lanes (product & scale audit)
| Lane | Scope | Owns |
|---|---|---|
| B-P | Primary synthesis: 10× potential assessment — market positioning, moat, platform expansion | report |
| B-S1 | UX friction walk: onboarding→first-value path, empty states, discoverability of features (timeline hidden? shortcuts undiscoverable?) | report+small fixes |
| B-S2 | Security/privacy: data-at-rest inventory, network calls audit, bundle hygiene vs OWASP MASVS-lite | report |
| B-S3 | Architecture-for-scale: multi-device prep, plugin surface for modes, cloud-sync seams | report |
| B-S4 | Growth/distribution: notarization blockers, website needs, pricing-model analysis (N10) | report |

## Deliverables
1. `docs/product/audit-w6/team-a-findings.md` — findings + fixes applied (with evidence)
2. `docs/product/audit-w6/team-b-findings.md` — product findings + small fixes
3. `docs/product/UPGRADE_10X.md` — the joint 10× plan: current state baseline,
   upgrade tiers (10× reach / 10× capability / 10× polish), sequenced roadmap,
   effort estimates, dependency graph.

## Merge law
ATLAS gates every fix (build + 177 suite must stay green or grow). Reports are
report-only. Single W6 commit per team after gate; final commit carries the
10× doc.
